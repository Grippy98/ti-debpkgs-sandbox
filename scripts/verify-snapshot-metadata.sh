#!/bin/bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <archive-state.tar.gz> <snapshot.json> <snapshot.json.asc> <expected-tag> <policy.json>" >&2
    exit 2
fi

snapshot=$1
manifest=$2
signature=$3
expected_tag=$4
policy=$5
public_key=$(jq -er '.signing.public_key' "$policy")
expected_fingerprint=$(jq -er '.signing.fingerprint' "$policy")
repository=$(jq -er '.archive_repository' "$policy")
workflow=$(jq -er '.publisher.workflow' "$policy")
publisher_ref=$(jq -er '.publisher.ref' "$policy")
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

mapfile -t primary_fingerprints < <(
    gpg --batch --no-tty --show-keys --with-colons "$public_key" |
        awk -F: '
            $1 == "pub" {want_fingerprint=1; next}
            want_fingerprint && $1 == "fpr" {print $10; want_fingerprint=0}
        '
)
if [ "${#primary_fingerprints[@]}" -ne 1 ] || \
   [ "${primary_fingerprints[0]}" != "$expected_fingerprint" ]; then
    echo "Snapshot verification key does not exactly match policy" >&2
    exit 1
fi
gpg --batch --no-tty --dearmor --output "$temporary/archive-keyring.gpg" "$public_key"
gpgv --keyring "$temporary/archive-keyring.gpg" "$signature" "$manifest"

jq -e \
    --arg repository "$repository" \
    --arg tag "$expected_tag" \
    --arg workflow "$workflow" \
    --arg ref "$publisher_ref" \
    --arg fingerprint "$expected_fingerprint" '
    keys == [
        "created_at", "predecessor", "publisher", "receipt", "repository",
        "request_id", "schema", "signing_fingerprint", "state", "tag"
    ] and
    .schema == "ti.debpkgs.snapshot/v1" and
    .repository == $repository and
    .tag == $tag and
    .signing_fingerprint == $fingerprint and
    (.request_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{2,79}$")) and
    (.created_at | type == "string") and
    (.publisher | keys == ["commit", "ref", "run_attempt", "run_id", "workflow"]) and
    .publisher.workflow == $workflow and
    .publisher.ref == $ref and
    (.publisher.commit | test("^[0-9a-f]{40}$")) and
    (.publisher.run_id | type == "number" and . >= 1 and floor == .) and
    (.publisher.run_attempt | type == "number" and . >= 1 and floor == .) and
    .tag == ("archive-snapshot-" + (.publisher.run_id | tostring) + "-" + (.publisher.run_attempt | tostring)) and
    (.state | keys == ["name", "sha256", "size"]) and
    .state.name == "archive-state.tar.gz" and
    (.state.sha256 | test("^[0-9a-f]{64}$")) and
    (.state.size | type == "number" and . >= 1 and floor == .) and
    (.receipt | keys == ["name", "sha256", "size"]) and
    .receipt.name == "receipt.json" and
    (.receipt.sha256 | test("^[0-9a-f]{64}$")) and
    (.receipt.size | type == "number" and . >= 1 and floor == .) and
    (
        .predecessor == null or
        (
            (.predecessor | keys == ["manifest_sha256", "state_sha256", "tag"]) and
            (.predecessor.tag | test("^archive-snapshot-[1-9][0-9]*-[1-9][0-9]*$")) and
            (.predecessor.manifest_sha256 | test("^[0-9a-f]{64}$")) and
            (.predecessor.state_sha256 | test("^[0-9a-f]{64}$"))
        )
    )
' "$manifest" >/dev/null

expected_size=$(jq -er '.state.size' "$manifest")
expected_digest=$(jq -er '.state.sha256' "$manifest")
if [ "$(stat -c %s "$snapshot")" -ne "$expected_size" ] || \
   [ "$(sha256sum "$snapshot" | awk '{print $1}')" != "$expected_digest" ]; then
    echo "Archive snapshot does not match its signed metadata" >&2
    exit 1
fi
