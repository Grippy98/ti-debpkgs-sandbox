#!/bin/bash

set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
mkdir -p "$lab/logs" "$lab/mock-bin" "$lab/assets"

die() {
    echo "STATE BOUNDARY TEST FAILURE: $*" >&2
    exit 1
}

expect_status() {
    local expected=$1
    local label=$2
    shift 2
    local actual

    set +e
    "$@" >"$lab/logs/$label.log" 2>&1
    actual=$?
    set -e
    if [ "$actual" -ne "$expected" ]; then
        cat "$lab/logs/$label.log" >&2
        die "$label returned $actual instead of $expected"
    fi
}

expect_failure_containing() {
    local label=$1
    local message=$2
    shift 2

    expect_status 1 "$label" "$@"
    if ! grep -Fq "$message" "$lab/logs/$label.log"; then
        cat "$lab/logs/$label.log" >&2
        die "$label did not report the expected failure: $message"
    fi
}

cat >"$lab/mock-bin/gh" <<'EOF'
#!/bin/bash

set -euo pipefail

: "${MOCK_RELEASES_JSON:?MOCK_RELEASES_JSON is required}"
: "${MOCK_ASSET_ROOT:?MOCK_ASSET_ROOT is required}"

if [ "${1:-}" = api ]; then
    endpoint=${*: -1}
    case "$endpoint" in
        */releases\?per_page=100)
            if [ "$#" -ne 4 ] || [ "${2:-}" != --paginate ] || \
               [ "${3:-}" != --slurp ]; then
                echo "Release listing did not use the pinned paginated API form" >&2
                exit 97
            fi
            cat "$MOCK_RELEASES_JSON"
            ;;
        */releases/assets/*)
            if [ "$#" -ne 6 ] || [ "${2:-}" != --method ] || \
               [ "${3:-}" != GET ] || [ "${4:-}" != -H ] || \
               [ "${5:-}" != 'Accept: application/octet-stream' ]; then
                echo "Release asset download did not use the pinned binary API form" >&2
                exit 97
            fi
            asset_id=${endpoint##*/}
            case "$asset_id" in
                ''|*[!0-9]*)
                    echo "Release asset endpoint lacks a numeric ID" >&2
                    exit 97
                    ;;
            esac
            cat "$MOCK_ASSET_ROOT/by-id/$asset_id"
            ;;
        *)
            echo "Unexpected mocked gh api endpoint: $endpoint" >&2
            exit 97
            ;;
    esac
    exit 0
fi

echo "Unexpected mocked gh invocation: $*" >&2
exit 99
EOF

cat >"$lab/mock-bin/curl" <<'EOF'
#!/bin/bash

set -euo pipefail

head_request=false
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --head)
            head_request=true
            shift
            ;;
        --output)
            output=${2:-}
            shift 2
            ;;
        --write-out|--max-filesize)
            shift 2
            ;;
        --fail|--location|--silent|--show-error)
            shift
            ;;
        http://*|https://*)
            url=$1
            shift
            ;;
        *)
            echo "Unexpected mocked curl argument: $1" >&2
            exit 97
            ;;
    esac
done

if [ -z "$url" ]; then
    echo "Mocked curl received no URL" >&2
    exit 97
fi
if [ "$head_request" = true ]; then
    status=${MOCK_PAGES_STATUS:-404}
    printf '%s' "$status"
    if [ "$status" = 000 ]; then
        exit 7
    fi
    exit 0
fi

if [ "${MOCK_PAGES_STATUS:-200}" != 200 ]; then
    exit 22
fi
: "${MOCK_PAGES_MANIFEST:?MOCK_PAGES_MANIFEST is required for a Pages GET}"
if [ -z "$output" ]; then
    echo "Mocked curl received no output path" >&2
    exit 97
fi
cp "$MOCK_PAGES_MANIFEST" "$output"
EOF
chmod 0755 "$lab/mock-bin/gh" "$lab/mock-bin/curl"

export PATH="$lab/mock-bin:$PATH"
export GH_TOKEN=state-boundary-token

export GNUPGHOME="$lab/gnupg"
install -d -m 0700 "$GNUPGHOME"
gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
    --quick-generate-key \
    'TI Debian Sandbox State Boundary <state-boundary@example.invalid>' \
    rsa2048 sign 1d
fingerprint=$(gpg --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" {print $10; exit}')
test -n "$fingerprint"
gpg --batch --no-tty --armor --export-options export-minimal \
    --output "$lab/state-boundary-key.asc" --export "$fingerprint"

jq \
    --arg fingerprint "$fingerprint" \
    --arg public_key "$lab/state-boundary-key.asc" \
    --arg publication_url 'https://pages.example.invalid/ti-debpkgs-sandbox/' \
    '.signing.fingerprint = $fingerprint |
     .signing.public_key = $public_key |
     .publication_url = $publication_url' \
    "$repository/policy/archive.json" >"$lab/policy.json"

state="$lab/archive-state"
"$repository/scripts/initialize-state.sh" \
    "$state" "$lab/policy.json" "$repository/archive"
mkdir -p "$state/audit/requests/state-boundary"
jq -n '{
    schema: "ti.debpkgs.receipt/v1",
    request_id: "state-boundary",
    action: "include",
    suite: "trixie",
    component: "main",
    source: {name: "state-boundary", version: "1.0-1"},
    binaries: [],
    provenance: null
}' >"$state/audit/requests/state-boundary/receipt.json"
receipt="$state/audit/requests/state-boundary/receipt.json"
"$repository/scripts/verify-archive.sh" "$state" "$lab/policy.json" trixie
"$repository/scripts/snapshot-state.sh" "$state" "$lab/archive-state.tar.gz"

export GITHUB_SHA=3333333333333333333333333333333333333333
export GITHUB_REF=refs/heads/main

create_metadata() {
    local run_id=$1
    local predecessor=$2
    local output=$3

    export GITHUB_RUN_ID=$run_id
    export GITHUB_RUN_ATTEMPT=1
    "$repository/scripts/create-snapshot-metadata.sh" \
        "$lab/archive-state.tar.gz" "$receipt" \
        "archive-snapshot-$run_id-1" "$predecessor" \
        "$lab/policy.json" "$output"
}

old_tag=archive-snapshot-3001-1
new_tag=archive-snapshot-3002-1
create_metadata 3001 - "$lab/metadata-old"
create_metadata 3002 "$lab/metadata-old/snapshot.json" "$lab/metadata-new"

create_asset_set() {
    local tag=$1
    local metadata=$2
    local root=$3
    local destination="$root/$tag"

    mkdir -p "$destination"
    cp "$lab/archive-state.tar.gz" "$destination/archive-state.tar.gz"
    cp "$receipt" "$destination/receipt.json"
    cp "$metadata/snapshot.json" "$metadata/snapshot.json.asc" "$destination/"
    (
        cd "$destination"
        sha256sum archive-state.tar.gz receipt.json snapshot.json snapshot.json.asc \
            >SHA256SUMS
    )
}

create_release_object() {
    local root=$1
    local tag=$2
    local draft=$3
    local output=$4
    local assets run_id index name asset_id

    run_id=${tag#archive-snapshot-}
    run_id=${run_id%-*}
    index=0
    mkdir -p "$root/by-id"
    assets=$(
        for name in \
            SHA256SUMS archive-state.tar.gz receipt.json snapshot.json snapshot.json.asc; do
            index=$((index + 1))
            asset_id=$((run_id * 100 + index))
            cp "$root/$tag/$name" "$root/by-id/$asset_id"
            jq -n \
                --argjson id "$asset_id" \
                --arg name "$name" \
                --arg digest "sha256:$(sha256sum "$root/$tag/$name" | awk '{print $1}')" \
                --argjson size "$(stat -c %s "$root/$tag/$name")" \
                '{
                    id: $id,
                    name: $name,
                    state: "uploaded",
                    digest: $digest,
                    size: $size
                }'
        done | jq -s '.'
    )
    jq -n \
        --argjson id "$run_id" \
        --arg tag "$tag" \
        --argjson draft "$draft" \
        --argjson assets "$assets" \
        '{
            id: $id,
            tag_name: $tag,
            target_commitish: "3333333333333333333333333333333333333333",
            draft: $draft,
            prerelease: false,
            assets: $assets
        }' \
        >"$output"
}

write_release_pages() {
    local output=$1
    shift
    jq -s '[.]' "$@" >"$output"
}

valid_assets="$lab/assets/valid"
create_asset_set "$old_tag" "$lab/metadata-old" "$valid_assets"
create_asset_set "$new_tag" "$lab/metadata-new" "$valid_assets"
create_release_object "$valid_assets" "$old_tag" false "$lab/release-old.json"
create_release_object "$valid_assets" "$new_tag" true "$lab/release-new-draft.json"
write_release_pages "$lab/releases-old.json" "$lab/release-old.json"
write_release_pages "$lab/releases-new-and-old.json" \
    "$lab/release-new-draft.json" "$lab/release-old.json"
printf '[[]]\n' >"$lab/releases-empty.json"

fetch_state="$repository/scripts/fetch-state.sh"
restore_release="$repository/scripts/restore-release-snapshot.sh"

# prepare-publication.sh accepts only clean, tracked policy and request inputs.
# Build a committed fixture repository so the bootstrap authorization test
# reaches the state boundary instead of stopping at that earlier trust gate.
bootstrap_repository="$lab/committed-publisher"
mkdir -p "$bootstrap_repository/requests/examples"
cp -a "$repository/scripts" "$repository/policy" "$repository/archive" \
    "$bootstrap_repository/"
cp "$repository/requests/examples/remove-source.json" \
    "$bootstrap_repository/requests/examples/"
git -C "$bootstrap_repository" init -q -b main
git -C "$bootstrap_repository" config user.name 'State Boundary Test'
git -C "$bootstrap_repository" config user.email state-boundary@example.invalid
git -C "$bootstrap_repository" add archive policy requests scripts
git -C "$bootstrap_repository" commit -qm 'Create committed state fixture'

# An empty Releases collection is a bootstrap signal only when Pages is also
# empty. The caller must still authorize initialization explicitly.
expect_status 3 fetch-empty \
    env MOCK_RELEASES_JSON="$lab/releases-empty.json" \
        MOCK_ASSET_ROOT="$valid_assets" MOCK_PAGES_STATUS=404 \
        "$fetch_state" "$lab/policy.json" "$lab/fetched-empty"
grep -Fq 'No archive snapshot release exists yet' "$lab/logs/fetch-empty.log" ||
    die 'fetch-state did not report its explicit empty-state status'

expect_failure_containing bootstrap-not-authorized \
    'explicit first-run initialization was not authorized' \
    env ARCHIVE_GH_TOKEN=state-boundary-token \
        MOCK_RELEASES_JSON="$lab/releases-empty.json" \
        MOCK_ASSET_ROOT="$valid_assets" MOCK_PAGES_STATUS=404 \
        "$bootstrap_repository/scripts/prepare-publication.sh" \
        "$bootstrap_repository/requests/examples/remove-source.json" \
        "$bootstrap_repository/policy/archive.json" \
        "$lab/bootstrap-denied" false

expect_failure_containing pages-without-release \
    'No snapshot release was found, but the Pages archive is not empty' \
    env MOCK_RELEASES_JSON="$lab/releases-empty.json" \
        MOCK_ASSET_ROOT="$valid_assets" MOCK_PAGES_STATUS=200 \
        "$fetch_state" "$lab/policy.json" "$lab/fetched-pages-without-release"

# A draft represents an interrupted publication. It blocks selection of an
# older published state until the draft is recovered or otherwise reconciled.
expect_failure_containing unfinished-draft \
    'An unfinished snapshot draft exists; recover it before publishing again' \
    env MOCK_RELEASES_JSON="$lab/releases-new-and-old.json" \
        MOCK_ASSET_ROOT="$valid_assets" MOCK_PAGES_STATUS=200 \
        MOCK_PAGES_MANIFEST="$lab/metadata-old/snapshot.json" \
        "$fetch_state" "$lab/policy.json" "$lab/fetched-past-draft"

# A normal published head is accepted only when its signed metadata is the
# exact object deployed by Pages.
expect_status 0 fetch-published \
    env MOCK_RELEASES_JSON="$lab/releases-old.json" \
        MOCK_ASSET_ROOT="$valid_assets" MOCK_PAGES_STATUS=200 \
        MOCK_PAGES_MANIFEST="$lab/metadata-old/snapshot.json" \
        "$fetch_state" "$lab/policy.json" "$lab/fetched-published"
test -f "$lab/fetched-published/.snapshot.json"
cmp "$lab/metadata-old/snapshot.json" "$lab/fetched-published/.snapshot.json"

expect_failure_containing pages-head-mismatch \
    'Latest signed snapshot release does not match the deployed Pages head' \
    env MOCK_RELEASES_JSON="$lab/releases-old.json" \
        MOCK_ASSET_ROOT="$valid_assets" MOCK_PAGES_STATUS=200 \
        MOCK_PAGES_MANIFEST="$lab/metadata-new/snapshot.json" \
        "$fetch_state" "$lab/policy.json" "$lab/fetched-pages-mismatch"

# Recovery accepts only the exact newest snapshot, including a draft. It must
# not be usable as an arbitrary rollback mechanism.
expect_failure_containing rollback-old-release \
    "Recovery is restricted to the newest snapshot: $new_tag" \
    env MOCK_RELEASES_JSON="$lab/releases-new-and-old.json" \
        MOCK_ASSET_ROOT="$valid_assets" \
        "$restore_release" "$lab/policy.json" "$old_tag" "$lab/recover-old"

expect_status 2 recovery-inexact-tag \
    env MOCK_RELEASES_JSON="$lab/releases-new-and-old.json" \
        MOCK_ASSET_ROOT="$valid_assets" \
        "$restore_release" "$lab/policy.json" \
        archive-snapshot-latest "$lab/recover-inexact"
grep -Fq 'Recovery requires one exact archive snapshot tag' \
    "$lab/logs/recovery-inexact-tag.log" ||
    die 'recovery accepted or ambiguously rejected an inexact snapshot tag'

expect_status 0 recovery-newest-draft \
    env MOCK_RELEASES_JSON="$lab/releases-new-and-old.json" \
        MOCK_ASSET_ROOT="$valid_assets" \
        "$restore_release" "$lab/policy.json" "$new_tag" "$lab/recover-new"
test -f "$lab/recover-new/pages/dists/trixie/InRelease"
cmp "$lab/metadata-new/snapshot.json" "$lab/recover-new/pages/snapshot.json"
jq -e '.draft == true and .tag_name == "archive-snapshot-3002-1"' \
    "$lab/recover-new/release.json" >/dev/null

# Release metadata is an exact allow-list. Missing or extra assets are rejected
# before any archive data is trusted.
jq '.[0][0].assets |= map(select(.name != "receipt.json"))' \
    "$lab/releases-new-and-old.json" >"$lab/releases-missing-asset.json"
expect_failure_containing recovery-missing-asset \
    'Snapshot release does not contain the exact recovery asset set' \
    env MOCK_RELEASES_JSON="$lab/releases-missing-asset.json" \
        MOCK_ASSET_ROOT="$valid_assets" \
        "$restore_release" "$lab/policy.json" "$new_tag" "$lab/recover-missing"

jq '.[0][0].assets += [{
        "id": 999999,
        "name": "unexpected.bin",
        "state": "uploaded",
        "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        "size": 1
    }]' "$lab/releases-new-and-old.json" >"$lab/releases-extra-asset.json"
expect_failure_containing recovery-extra-asset \
    'Snapshot release does not contain the exact recovery asset set' \
    env MOCK_RELEASES_JSON="$lab/releases-extra-asset.json" \
        MOCK_ASSET_ROOT="$valid_assets" \
        "$restore_release" "$lab/policy.json" "$new_tag" "$lab/recover-extra"

# Correct filenames do not suffice: GitHub's recorded asset digest, the
# checksum manifest, and the detached snapshot signature are all enforced.
jq '.[0][0].assets |= map(
        if .name == "archive-state.tar.gz" then
            .digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        else . end
    )' "$lab/releases-new-and-old.json" >"$lab/releases-bad-digest.json"
expect_failure_containing recovery-bad-digest \
    'Recovered asset digest does not match release metadata' \
    env MOCK_RELEASES_JSON="$lab/releases-bad-digest.json" \
        MOCK_ASSET_ROOT="$valid_assets" \
        "$restore_release" "$lab/policy.json" "$new_tag" "$lab/recover-digest"

bad_signature_assets="$lab/assets/bad-signature"
create_asset_set "$new_tag" "$lab/metadata-new" "$bad_signature_assets"
printf 'not an OpenPGP signature\n' \
    >"$bad_signature_assets/$new_tag/snapshot.json.asc"
(
    cd "$bad_signature_assets/$new_tag"
    sha256sum archive-state.tar.gz receipt.json snapshot.json snapshot.json.asc \
        >SHA256SUMS
)
create_release_object \
    "$bad_signature_assets" "$new_tag" true "$lab/release-bad-signature.json"
write_release_pages "$lab/releases-bad-signature.json" \
    "$lab/release-bad-signature.json"
expect_status 2 recovery-bad-signature \
    env MOCK_RELEASES_JSON="$lab/releases-bad-signature.json" \
        MOCK_ASSET_ROOT="$bad_signature_assets" \
        "$restore_release" "$lab/policy.json" "$new_tag" "$lab/recover-signature"
if ! grep -Eq 'gpgv:|invalid packet|no valid OpenPGP data' \
    "$lab/logs/recovery-bad-signature.log"; then
    cat "$lab/logs/recovery-bad-signature.log" >&2
    die 'invalid snapshot signature was not rejected cryptographically'
fi

echo 'Archive state and recovery boundary tests passed'
