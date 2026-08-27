#!/bin/bash

set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
mkdir -p "$lab/logs"

die() {
    echo "PROVENANCE TEST FAILURE: $*" >&2
    exit 1
}

expect_failure() {
    local label=$1
    shift
    if "$@" >"$lab/logs/$label.stdout" 2>"$lab/logs/$label.stderr"; then
        die "$label unexpectedly succeeded"
    fi
}

producer_repository=Grippy98/ti-debian-repos
producer_workflow=.github/workflows/cc33conf-candidate.yml
producer_ref=refs/heads/codex/cc33conf-candidate
producer_branch=codex/cc33conf-candidate
producer_commit=1111111111111111111111111111111111111111
run_id=424242
run_attempt=3
artifact_id=777777
artifact_name=provenance-boundary-candidate
bundle_name=candidate-provenance-boundary.tar.gz
token=mock-candidate-read-token

bundle="$lab/$bundle_name"
alternate_bundle="$lab/alternate-$bundle_name"
transport="$lab/artifact.zip"
alternate_transport="$lab/alternate-artifact.zip"
printf 'opaque candidate payload A\n' >"$bundle"
printf 'opaque candidate payload B\n' >"$alternate_bundle"

python3 - "$bundle" "$transport" "$bundle_name" <<'PY'
import sys
import zipfile
from pathlib import Path

source, destination, name = map(Path, sys.argv[1:])
info = zipfile.ZipInfo(name.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
info.compress_type = zipfile.ZIP_STORED
with zipfile.ZipFile(destination, "w") as archive:
    archive.writestr(info, source.read_bytes())
PY
python3 - "$alternate_bundle" "$alternate_transport" "$bundle_name" <<'PY'
import sys
import zipfile
from pathlib import Path

source, destination, name = map(Path, sys.argv[1:])
info = zipfile.ZipInfo(name.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
info.compress_type = zipfile.ZIP_STORED
with zipfile.ZipFile(destination, "w") as archive:
    archive.writestr(info, source.read_bytes())
PY

bundle_sha256=$(sha256sum "$bundle" | awk '{print $1}')
artifact_digest="sha256:$(sha256sum "$transport" | awk '{print $1}')"
request="$lab/request.json"
jq -n \
    --argjson run_id "$run_id" \
    --argjson run_attempt "$run_attempt" \
    --argjson artifact_id "$artifact_id" \
    --arg artifact_name "$artifact_name" \
    --arg artifact_digest "$artifact_digest" \
    --arg bundle "$bundle_name" \
    --arg bundle_sha256 "$bundle_sha256" \
    --arg commit "$producer_commit" \
    '{
        schema: "ti.debpkgs.request/v1",
        request_id: "provenance-boundary-include",
        action: "include",
        suite: "trixie",
        component: "main",
        reason: "Exercise every mocked provenance trust boundary",
        source: {
            name: "cc33conf",
            version: "1.7.0.120+git20241031+34e2cf44-1",
            upstream_repository: "https://git.ti.com/git/cc33xx-wlan/cc33xx-utils.git",
            upstream_commit: "34e2cf44e9468bb6308bf163da4cf7349f1717ec"
        },
        candidate: {
            run_id: $run_id,
            run_attempt: $run_attempt,
            artifact_id: $artifact_id,
            artifact_name: $artifact_name,
            artifact_digest: $artifact_digest,
            bundle: $bundle,
            bundle_sha256: $bundle_sha256,
            producer_commit: $commit
        }
    }' >"$request"

export PATH="$repository/tests/mocks:$PATH"
export GH_TOKEN=$token
export MOCK_EXPECT_TOKEN=$token
export MOCK_GH_LOG="$lab/gh.log"
export MOCK_CURL_LOG="$lab/curl.log"
export MOCK_TRANSPORT=$transport
export MOCK_EXPECT_REPOSITORY=$producer_repository
export MOCK_EXPECT_WORKFLOW=$producer_workflow
export MOCK_EXPECT_REF=$producer_ref
export MOCK_EXPECT_BRANCH=$producer_branch
export MOCK_EXPECT_COMMIT=$producer_commit
export MOCK_EXPECT_RUN_ID=$run_id
export MOCK_EXPECT_RUN_ATTEMPT=$run_attempt
export MOCK_EXPECT_ARTIFACT_ID=$artifact_id
export MOCK_EXPECT_ARTIFACT_NAME=$artifact_name
export MOCK_EXPECT_ARTIFACT_DIGEST=$artifact_digest
export MOCK_EXPECT_ARTIFACT_URL="https://api.github.com/repos/$producer_repository/actions/artifacts/$artifact_id/zip"
export MOCK_EXPECT_BUNDLE=$bundle
: >"$MOCK_GH_LOG"
: >"$MOCK_CURL_LOG"

fetch_candidate="$repository/scripts/fetch-candidate.sh"
policy="$repository/policy/archive.json"
valid_fetch="$lab/fetch-valid"
fetched=$($fetch_candidate "$request" "$policy" "$valid_fetch")
cmp "$bundle" "$fetched"
if grep -Fq "$token" "$MOCK_GH_LOG" "$MOCK_CURL_LOG"; then
    die "candidate token appeared in mocked command arguments"
fi

expect_fetch_failure() {
    local label=$1
    shift
    local destination="$lab/fetch-$label"
    expect_failure "fetch-$label" env "$@" \
        "$fetch_candidate" "$request" "$policy" "$destination"
    if [ -e "$destination/$bundle_name" ]; then
        die "$label left a candidate bundle after rejection"
    fi
}

expect_fetch_failure wrong-repository \
    MOCK_RUN_REPOSITORY=SomeoneElse/ti-debian-repos
expect_fetch_failure wrong-workflow \
    "MOCK_RUN_PATH=.github/workflows/other.yml@$producer_ref"
expect_fetch_failure wrong-ref \
    MOCK_RUN_BRANCH=other-branch
expect_fetch_failure wrong-commit \
    MOCK_RUN_COMMIT=2222222222222222222222222222222222222222
expect_fetch_failure wrong-run-id \
    MOCK_RUN_ID_RETURNED=$((run_id + 1))
expect_fetch_failure wrong-run-attempt \
    MOCK_RUN_ATTEMPT_RETURNED=$((run_attempt + 1))
expect_fetch_failure wrong-event \
    MOCK_RUN_EVENT=pull_request_target
expect_fetch_failure failed-run \
    MOCK_RUN_CONCLUSION=failure
expect_fetch_failure wrong-artifact-id \
    MOCK_ARTIFACT_ID_RETURNED=$((artifact_id + 1))
expect_fetch_failure wrong-artifact-run \
    MOCK_ARTIFACT_RUN_ID_RETURNED=$((run_id + 1))
expect_fetch_failure wrong-artifact-digest \
    MOCK_ARTIFACT_DIGEST_RETURNED=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_fetch_failure tampered-download \
    "MOCK_CURL_TRANSPORT=$alternate_transport"

expect_failure fetch-missing-token env -u GH_TOKEN \
    "$fetch_candidate" "$request" "$policy" "$lab/fetch-missing-token"

verify_provenance="$repository/scripts/verify-provenance.sh"
receipt="$lab/receipt.json"
: >"$MOCK_GH_LOG"
MOCK_ATTESTATION_MODE=valid \
    "$verify_provenance" "$bundle" "$request" "$policy" "$receipt"
jq -e \
    --arg invocation "https://github.com/$producer_repository/actions/runs/$run_id/attempts/$run_attempt" \
    'length == 1 and .[0].verificationResult.signature.certificate.runInvocationURI == $invocation' \
    "$receipt" >/dev/null
grep -Fq -- "--repo $producer_repository" "$MOCK_GH_LOG"
grep -Fq -- "--predicate-type https://slsa.dev/provenance/v1" "$MOCK_GH_LOG"
grep -Fq -- "--signer-workflow $producer_repository/$producer_workflow" "$MOCK_GH_LOG"
grep -Fq -- "--source-ref $producer_ref" "$MOCK_GH_LOG"
grep -Fq -- "--source-digest $producer_commit" "$MOCK_GH_LOG"
grep -Fq -- "--signer-digest $producer_commit" "$MOCK_GH_LOG"
grep -Fq -- "--deny-self-hosted-runners" "$MOCK_GH_LOG"

expect_attestation_failure() {
    local mode=$1
    local output="$lab/receipt-$mode.json"
    expect_failure "attestation-$mode" env MOCK_ATTESTATION_MODE="$mode" \
        "$verify_provenance" "$bundle" "$request" "$policy" "$output"
    if [ -s "$output" ]; then
        die "$mode produced a usable attestation receipt after rejection"
    fi
}

for mode in \
    wrong-repo wrong-workflow wrong-ref wrong-commit wrong-run \
    wrong-run-attempt self-hosted unsigned; do
    expect_attestation_failure "$mode"
done
expect_failure attestation-old-gh env MOCK_GH_VERSION=2.96.0 \
    "$verify_provenance" "$bundle" "$request" "$policy" "$lab/receipt-old-gh.json"
expect_failure attestation-missing-token env -u GH_TOKEN \
    "$verify_provenance" "$bundle" "$request" "$policy" "$lab/receipt-no-token.json"

# Exercise prepare-publication.sh from a clean, committed temporary repository.
# Its state retriever is replaced by a deterministic mock, while candidate
# retrieval and provenance verification remain the real scripts under test.
fixture_repository="$lab/committed-repository"
mkdir -p "$fixture_repository"
cp -a "$repository/scripts" "$fixture_repository/scripts"
cp -a "$repository/policy" "$fixture_repository/policy"
cp -a "$repository/archive" "$fixture_repository/archive"
mkdir -p "$fixture_repository/requests"
cp "$request" "$fixture_repository/requests/include.json"
cp "$repository/tests/mocks/fetch-state.sh" \
    "$fixture_repository/scripts/fetch-state.sh"
chmod 0755 "$fixture_repository/scripts/fetch-state.sh"
git -C "$fixture_repository" init -q -b main
git -C "$fixture_repository" config user.name 'Provenance Boundary Test'
git -C "$fixture_repository" config user.email provenance@example.invalid
git -C "$fixture_repository" add archive policy requests scripts
git -C "$fixture_repository" commit -qm 'Create committed provenance fixture'

prepare="$fixture_repository/scripts/prepare-publication.sh"
prepare_policy="$fixture_repository/policy/archive.json"
prepare_request="$fixture_repository/requests/include.json"

expect_prepare_failure() {
    local label=$1
    local stage=$2
    shift 2
    local work="$lab/prepare-$label"
    : >"$MOCK_GH_LOG"
    : >"$MOCK_CURL_LOG"
    expect_failure "prepare-$label" env \
        ARCHIVE_GH_TOKEN=mock-archive-read-token \
        CANDIDATE_GH_TOKEN=$token \
        "MOCK_EXPECT_BUNDLE=$work/candidate-transport/$bundle_name" \
        "$@" \
        "$prepare" "$prepare_request" "$prepare_policy" "$work" false

    if [ "$(cat "$work/state/sentinel")" != 'pristine archive state' ]; then
        die "$label mutated the restored archive state"
    fi
    if [ "$(find "$work/state" -type f | wc -l)" -ne 1 ]; then
        die "$label added files to the restored archive state"
    fi
    if [ -e "$work/verified-candidate" ] || [ -e "$work/plan.md" ] || \
       [ -e "$work/archive-state-path" ] || [ -e "$work/candidate-path" ]; then
        die "$label advanced publication after provenance rejection"
    fi
    case "$stage" in
        before-attestation)
            if grep -Fq 'gh attestation verify' "$MOCK_GH_LOG"; then
                die "$label reached attestation verification after an earlier identity failure"
            fi
            ;;
        at-attestation)
            grep -Fq 'gh attestation verify' "$MOCK_GH_LOG" || \
                die "$label did not reach the attestation boundary"
            ;;
        *) die "unknown prepare failure stage: $stage" ;;
    esac
}

expect_prepare_failure wrong-artifact-id before-attestation \
    MOCK_ARTIFACT_ID_RETURNED=$((artifact_id + 1))
expect_prepare_failure wrong-artifact-digest before-attestation \
    MOCK_ARTIFACT_DIGEST_RETURNED=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_prepare_failure wrong-repository before-attestation \
    MOCK_RUN_REPOSITORY=SomeoneElse/ti-debian-repos
expect_prepare_failure wrong-workflow before-attestation \
    "MOCK_RUN_PATH=.github/workflows/other.yml@$producer_ref"
expect_prepare_failure wrong-ref before-attestation \
    MOCK_RUN_BRANCH=other-branch
expect_prepare_failure wrong-commit before-attestation \
    MOCK_RUN_COMMIT=2222222222222222222222222222222222222222
expect_prepare_failure wrong-run-id before-attestation \
    MOCK_RUN_ID_RETURNED=$((run_id + 1))
expect_prepare_failure wrong-run-attempt before-attestation \
    MOCK_RUN_ATTEMPT_RETURNED=$((run_attempt + 1))
expect_prepare_failure wrong-artifact-run before-attestation \
    MOCK_ARTIFACT_RUN_ID_RETURNED=$((run_id + 1))
expect_prepare_failure tampered-download before-attestation \
    "MOCK_CURL_TRANSPORT=$alternate_transport"
expect_prepare_failure attestation-wrong-repository at-attestation \
    MOCK_ATTESTATION_MODE=wrong-repo
expect_prepare_failure attestation-wrong-workflow at-attestation \
    MOCK_ATTESTATION_MODE=wrong-workflow
expect_prepare_failure attestation-wrong-ref at-attestation \
    MOCK_ATTESTATION_MODE=wrong-ref
expect_prepare_failure attestation-wrong-commit at-attestation \
    MOCK_ATTESTATION_MODE=wrong-commit
expect_prepare_failure attestation-wrong-run at-attestation \
    MOCK_ATTESTATION_MODE=wrong-run
expect_prepare_failure attestation-wrong-run-attempt at-attestation \
    MOCK_ATTESTATION_MODE=wrong-run-attempt
expect_prepare_failure unsigned at-attestation \
    MOCK_ATTESTATION_MODE=unsigned
expect_prepare_failure self-hosted at-attestation \
    MOCK_ATTESTATION_MODE=self-hosted

echo 'Provenance boundary tests passed'
