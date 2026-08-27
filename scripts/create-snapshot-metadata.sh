#!/bin/bash

set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "Usage: $0 <archive-state.tar.gz> <receipt.json> <tag> <predecessor.json-or-dash> <policy.json> <output-dir>" >&2
    exit 2
fi

snapshot=$1
receipt=$2
tag=$3
predecessor_file=$4
policy=$5
output_dir=$6
repository=$(jq -er '.archive_repository' "$policy")
workflow=$(jq -er '.publisher.workflow' "$policy")
expected_ref=$(jq -er '.publisher.ref' "$policy")
fingerprint=$(jq -er '.signing.fingerprint' "$policy")

: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

if [ "$GITHUB_REF" != "$expected_ref" ] || \
   [ "$tag" != "archive-snapshot-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" ]; then
    echo "Snapshot identity does not match the protected publisher invocation" >&2
    exit 1
fi
if [ -e "$output_dir" ]; then
    echo "Snapshot metadata destination already exists: $output_dir" >&2
    exit 1
fi
mkdir -p "$output_dir"

mapfile -t secret_fingerprints < <(
    gpg --batch --with-colons --list-secret-keys |
        awk -F: '
            $1 == "sec" {want_fingerprint=1; next}
            want_fingerprint && $1 == "fpr" {print $10; want_fingerprint=0}
        '
)
if [ "${#secret_fingerprints[@]}" -ne 1 ] || \
   [ "${secret_fingerprints[0]}" != "$fingerprint" ]; then
    echo "Publisher keyring must contain exactly the configured secret key" >&2
    exit 1
fi

predecessor=null
if [ "$predecessor_file" != - ]; then
    predecessor=$(jq -cn \
        --arg tag "$(jq -er '.tag' "$predecessor_file")" \
        --arg manifest_sha256 "$(sha256sum "$predecessor_file" | awk '{print $1}')" \
        --arg state_sha256 "$(jq -er '.state.sha256' "$predecessor_file")" \
        '{tag: $tag, manifest_sha256: $manifest_sha256, state_sha256: $state_sha256}')
fi

manifest="$output_dir/snapshot.json"
jq -n \
    --arg repository "$repository" \
    --arg tag "$tag" \
    --arg workflow "$workflow" \
    --arg ref "$GITHUB_REF" \
    --arg commit "$GITHUB_SHA" \
    --argjson run_id "$GITHUB_RUN_ID" \
    --argjson run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg request_id "$(jq -er '.request_id' "$receipt")" \
    --arg state_sha256 "$(sha256sum "$snapshot" | awk '{print $1}')" \
    --argjson state_size "$(stat -c %s "$snapshot")" \
    --arg receipt_sha256 "$(sha256sum "$receipt" | awk '{print $1}')" \
    --argjson receipt_size "$(stat -c %s "$receipt")" \
    --arg fingerprint "$fingerprint" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson predecessor "$predecessor" '
    {
        schema: "ti.debpkgs.snapshot/v1",
        repository: $repository,
        tag: $tag,
        publisher: {
            workflow: $workflow,
            ref: $ref,
            commit: $commit,
            run_id: $run_id,
            run_attempt: $run_attempt
        },
        request_id: $request_id,
        predecessor: $predecessor,
        state: {
            name: "archive-state.tar.gz",
            sha256: $state_sha256,
            size: $state_size
        },
        receipt: {
            name: "receipt.json",
            sha256: $receipt_sha256,
            size: $receipt_size
        },
        signing_fingerprint: $fingerprint,
        created_at: $created_at
    }
' >"$manifest"

gpg --batch --no-tty --local-user "$fingerprint" --armor --detach-sign \
    --output "$output_dir/snapshot.json.asc" "$manifest"
