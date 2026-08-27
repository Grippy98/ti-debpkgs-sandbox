#!/bin/bash

set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
export GNUPGHOME="$lab/gnupg"
install -d -m 0700 "$GNUPGHOME"
cat >"$lab/attestation-verification.json" <<'EOF'
[{"verificationResult":{"signature":{"certificate":{"runInvocationURI":"https://github.com/Grippy98/ti-debian-repos/actions/runs/1001/attempts/1"}}}}]
EOF

gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
    --quick-generate-key \
    'TI Debian Sandbox Integration Test <integration@example.invalid>' \
    rsa3072 sign 1d
fingerprint=$(gpg --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" {print $10; exit}')
test -n "$fingerprint"
gpg --batch --no-tty --export-options export-minimal \
    --output "$lab/integration-key.gpg" --export "$fingerprint"

jq \
    --arg fingerprint "$fingerprint" \
    --arg public_key "$lab/integration-key.gpg" \
    '.signing.fingerprint = $fingerprint | .signing.public_key = $public_key' \
    "$repository/policy/archive.json" >"$lab/policy.json"

make_source_tree() {
    local upstream_version=$1
    local debian_version=$2
    local tree="$lab/build/ti-sandbox-demo-$upstream_version"

    rm -rf "$tree"
    mkdir -p "$tree/debian/source" "$tree/debian"
    printf 'ti-sandbox-demo %s\n' "$debian_version" >"$tree/demo-version"
    cat >"$tree/debian/control" <<'EOF'
Source: ti-sandbox-demo
Section: utils
Priority: optional
Maintainer: Sandbox <sandbox@example.invalid>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.7.2
Rules-Requires-Root: no

Package: ti-sandbox-demo
Architecture: any
Depends: ${misc:Depends}
Description: disposable archive integration-test package
 This package exists only to validate the sandbox publisher.
EOF
    cat >"$tree/debian/changelog" <<EOF
ti-sandbox-demo ($debian_version) trixie; urgency=medium

  * Exercise the signed archive publication pipeline.

 -- Sandbox <sandbox@example.invalid>  Thu, 27 Aug 2026 12:00:00 +0000
EOF
    cat >"$tree/debian/rules" <<'EOF'
#!/usr/bin/make -f
%:
	dh $@
EOF
    chmod 0755 "$tree/debian/rules"
    printf '3.0 (quilt)\n' >"$tree/debian/source/format"
    printf 'demo-version usr/share/ti-sandbox-demo/\n' >"$tree/debian/ti-sandbox-demo.install"
    printf 'Upstream-Name: ti-sandbox-demo\nSource: https://example.invalid/\nFiles: *\nCopyright: 2026 Sandbox\nLicense: MIT\n Permission is hereby granted for sandbox testing.\n' \
        >"$tree/debian/copyright"

    mkdir -p "$lab/build"
    tar --sort=name --mtime='UTC 2026-08-27' --owner=0 --group=0 --numeric-owner \
        --exclude='./debian' \
        -czf "$lab/build/ti-sandbox-demo_${upstream_version}.orig.tar.gz" \
        -C "$tree" .
    (
        cd "$tree"
        dpkg-buildpackage -us -uc -sa
    )
}

make_candidate() {
    local version=$1
    local run_id=$2
    local output="$lab/candidate-$run_id"
    local payload="$output/payload"
    local changes
    local artifact
    local files_json
    local bundle_name="candidate-ti-sandbox-demo-trixie-$run_id.tar.gz"

    mkdir -p "$payload"
    changes=$(find "$lab/build" -maxdepth 1 -type f \
        -name "ti-sandbox-demo_${version}_arm64.changes" -print -quit)
    test -n "$changes"
    cp "$changes" "$payload/"
    while IFS= read -r artifact; do
        test -f "$lab/build/$artifact"
        cp "$lab/build/$artifact" "$payload/"
    done < <(
        awk '
            /^Checksums-Sha256:/ {inside=1; next}
            inside && /^[^[:space:]]/ {exit}
            inside {print $3}
        ' "$changes"
    )

    files_json=$(
        for artifact in "$payload"/*; do
            jq -n \
                --arg path "payload/${artifact##*/}" \
                --argjson size "$(stat -c %s "$artifact")" \
                --arg sha256 "$(sha256sum "$artifact" | awk '{print $1}')" \
                '{path: $path, size: $size, sha256: $sha256}'
        done | jq -s 'sort_by(.path)'
    )

    jq -n \
        --arg repository 'Grippy98/ti-debian-repos' \
        --arg workflow '.github/workflows/cc33conf-candidate.yml' \
        --arg ref 'refs/heads/codex/cc33conf-candidate' \
        --arg commit '1111111111111111111111111111111111111111' \
        --argjson run_id "$run_id" \
        --arg version "$version" \
        --argjson files "$files_json" \
        '{
            schema: "ti.debian.candidate/v1",
            producer: {
                repository: $repository,
                workflow: $workflow,
                ref: $ref,
                commit: $commit,
                run_id: $run_id,
                run_attempt: 1
            },
            source: {
                name: "ti-sandbox-demo",
                version: $version,
                upstream_repository: "https://example.invalid/ti-sandbox-demo.git",
                upstream_commit: "2222222222222222222222222222222222222222"
            },
            build: {
                suite: "trixie",
                binary_architectures: ["arm64"],
                changes_distribution: "trixie"
            },
            publication: {suites: ["trixie"], component: "main"},
            files: $files
        }' >"$output/manifest.json"

    (
        cd "$output"
        find manifest.json payload -type f -print0 |
            LC_ALL=C sort -z |
            xargs -0 sha256sum >SHA256SUMS
        tar --sort=name --mtime='UTC 1970-01-01' \
            --owner=0 --group=0 --numeric-owner \
            -czf "$lab/$bundle_name" manifest.json SHA256SUMS payload
    )

    jq -n \
        --arg request_id "integration-include-$run_id" \
        --argjson run_id "$run_id" \
        --argjson artifact_id "$((run_id + 1000))" \
        --arg artifact_name "integration-candidate-$run_id" \
        --arg bundle "$bundle_name" \
        --arg version "$version" \
        --arg bundle_sha256 "$(sha256sum "$lab/$bundle_name" | awk '{print $1}')" \
        '{
            schema: "ti.debpkgs.request/v1",
            request_id: $request_id,
            action: "include",
            suite: "trixie",
            component: "main",
            reason: "Integration-test candidate publication",
            source: {
                name: "ti-sandbox-demo",
                version: $version,
                upstream_repository: "https://example.invalid/ti-sandbox-demo.git",
                upstream_commit: "2222222222222222222222222222222222222222"
            },
            candidate: {
                run_id: $run_id,
                run_attempt: 1,
                artifact_id: $artifact_id,
                artifact_name: $artifact_name,
                artifact_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                bundle: $bundle,
                bundle_sha256: $bundle_sha256,
                producer_commit: "1111111111111111111111111111111111111111"
            }
        }' >"$lab/request-$run_id.json"
}

mkdir -p "$lab/build"
make_source_tree 1.0 1.0-1
make_candidate 1.0-1 1001
"$repository/scripts/validate-request.py" "$lab/request-1001.json" "$lab/policy.json"
"$repository/scripts/verify-candidate.py" \
    "$lab/candidate-ti-sandbox-demo-trixie-1001.tar.gz" \
    "$lab/request-1001.json" "$lab/policy.json" "$lab/verified-1001"
"$repository/scripts/plan-request.sh" \
    "$lab/request-1001.json" "$lab/policy.json" - "$lab/verified-1001" \
    "$lab/plan-1001.md"
grep -Fq '| Current source versions | _none_ |' "$lab/plan-1001.md"
"$repository/scripts/initialize-state.sh" \
    "$lab/state" "$lab/policy.json" "$repository/archive"
"$repository/scripts/apply-request.sh" \
    "$lab/state" "$lab/request-1001.json" "$lab/policy.json" "$lab/verified-1001" \
    "$lab/attestation-verification.json"
"$repository/scripts/verify-archive.sh" "$lab/state" "$lab/policy.json" trixie
"$repository/scripts/smoke-test.sh" \
    "file:$lab/state" "$lab/integration-key.gpg" \
    "$lab/state/audit/requests/integration-include-1001/receipt.json"

make_source_tree 2.0 2.0-1
make_candidate 2.0-1 1002
cat >"$lab/attestation-verification-1002.json" <<'EOF'
[{"verificationResult":{"signature":{"certificate":{"runInvocationURI":"https://github.com/Grippy98/ti-debian-repos/actions/runs/1002/attempts/1"}}}}]
EOF
"$repository/scripts/verify-candidate.py" \
    "$lab/candidate-ti-sandbox-demo-trixie-1002.tar.gz" \
    "$lab/request-1002.json" "$lab/policy.json" "$lab/verified-1002"
"$repository/scripts/plan-request.sh" \
    "$lab/request-1002.json" "$lab/policy.json" "$lab/state" "$lab/verified-1002" \
    "$lab/plan-1002.md"
state_update="$lab/state-update"
cp -a "$lab/state" "$state_update"
"$repository/scripts/apply-request.sh" \
    "$state_update" "$lab/request-1002.json" "$lab/policy.json" "$lab/verified-1002" \
    "$lab/attestation-verification-1002.json"
"$repository/scripts/verify-archive.sh" "$state_update" "$lab/policy.json" trixie
"$repository/scripts/smoke-test.sh" \
    "file:$state_update" "$lab/integration-key.gpg" \
    "$state_update/audit/requests/integration-include-1002/receipt.json"

jq -n '{
    schema: "ti.debpkgs.request/v1",
    request_id: "integration-remove-1003",
    action: "remove-source",
    suite: "trixie",
    component: "main",
    reason: "Integration-test exact source removal",
    source: {name: "ti-sandbox-demo", version: "2.0-1"}
}' >"$lab/request-remove.json"
"$repository/scripts/plan-request.sh" \
    "$lab/request-remove.json" "$lab/policy.json" "$state_update" - \
    "$lab/plan-remove.md"
state_remove="$lab/state-remove"
cp -a "$state_update" "$state_remove"
"$repository/scripts/apply-request.sh" \
    "$state_remove" "$lab/request-remove.json" "$lab/policy.json" "$lab/unused" -
"$repository/scripts/verify-archive.sh" "$state_remove" "$lab/policy.json" trixie
if reprepro -b "$state_remove" list trixie ti-sandbox-demo | grep -q .; then
    echo 'Removed package remains in archive index' >&2
    exit 1
fi
if find "$state_remove/pool" -type f -name 'ti-sandbox-demo*' -print -quit | grep -q .; then
    echo 'Removed package files remain in the public pool' >&2
    exit 1
fi
"$repository/scripts/smoke-test.sh" \
    "file:$state_remove" "$lab/integration-key.gpg" \
    "$state_remove/audit/requests/integration-remove-1003/receipt.json"

jq '.request_id = "integration-remove-missing" | .source.version = "9.9-1"' \
    "$lab/request-remove.json" >"$lab/request-remove-missing.json"
state_failed="$lab/state-failed"
cp -a "$state_remove" "$state_failed"
find "$state_failed" -type f -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum >"$lab/state-before-failed-request"
if "$repository/scripts/apply-request.sh" \
    "$state_failed" "$lab/request-remove-missing.json" "$lab/policy.json" "$lab/unused" -; then
    echo 'Removing a nonexistent source version unexpectedly succeeded' >&2
    exit 1
fi
find "$state_failed" -type f -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum >"$lab/state-after-failed-request"
cmp "$lab/state-before-failed-request" "$lab/state-after-failed-request"

"$repository/scripts/snapshot-state.sh" "$state_update" "$lab/archive-state.tar.gz"
tar -tzf "$lab/archive-state.tar.gz" | grep -Fx 'dists/trixie/InRelease'
if tar -tzf "$lab/archive-state.tar.gz" | grep -q '^conf/'; then
    echo 'Snapshot unexpectedly contains executable archive configuration' >&2
    exit 1
fi
export GITHUB_SHA=3333333333333333333333333333333333333333
export GITHUB_REF=refs/heads/main
export GITHUB_RUN_ID=2001
export GITHUB_RUN_ATTEMPT=1
"$repository/scripts/create-snapshot-metadata.sh" \
    "$lab/archive-state.tar.gz" \
    "$state_update/audit/requests/integration-include-1002/receipt.json" \
    archive-snapshot-2001-1 - "$lab/policy.json" "$lab/snapshot-metadata"
"$repository/scripts/verify-snapshot-metadata.sh" \
    "$lab/archive-state.tar.gz" \
    "$lab/snapshot-metadata/snapshot.json" \
    "$lab/snapshot-metadata/snapshot.json.asc" \
    archive-snapshot-2001-1 "$lab/policy.json"
pages="$lab/pages"
"$repository/scripts/make-pages-site.sh" \
    "$state_update" "$lab/policy.json" "$pages" \
    "$lab/snapshot-metadata/snapshot.json" \
    "$lab/snapshot-metadata/snapshot.json.asc"
test -f "$pages/dists/trixie/InRelease"
test -f "$pages/ti-debpkgs-sandbox.sources"
cmp "$lab/snapshot-metadata/snapshot.json" "$pages/snapshot.json"
cp "$lab/archive-state.tar.gz" "$lab/tampered-state.tar.gz"
printf 'tamper' >>"$lab/tampered-state.tar.gz"
if "$repository/scripts/verify-snapshot-metadata.sh" \
    "$lab/tampered-state.tar.gz" \
    "$lab/snapshot-metadata/snapshot.json" \
    "$lab/snapshot-metadata/snapshot.json.asc" \
    archive-snapshot-2001-1 "$lab/policy.json"; then
    echo 'Tampered snapshot unexpectedly passed signed-metadata verification' >&2
    exit 1
fi
"$repository/scripts/restore-state.py" \
    "$lab/archive-state.tar.gz" "$lab/policy.json" "$lab/restored-state"
mkdir -p "$lab/restored-state/conf"
cp "$repository/archive/conf/options" "$lab/restored-state/conf/options"
"$repository/scripts/render-config.sh" \
    "$repository/archive/conf/distributions.in" \
    "$lab/restored-state/conf/distributions" "$fingerprint"
"$repository/scripts/verify-archive.sh" "$lab/restored-state" "$lab/policy.json" trixie

echo 'Sandbox publisher integration test passed'
