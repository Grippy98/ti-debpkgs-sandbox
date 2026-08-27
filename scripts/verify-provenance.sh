#!/bin/bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <bundle> <request.json> <policy.json> <receipt.json>" >&2
    exit 2
fi

bundle=$1
request=$2
policy=$3
receipt=$4

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required to verify build provenance" >&2
    exit 2
fi
gh_version=$(gh --version | awk 'NR == 1 {print $3}')
if ! dpkg --compare-versions "$gh_version" ge 2.97.0; then
    echo "GitHub CLI 2.97.0 or newer is required for safe signer matching" >&2
    exit 1
fi

repository=$(jq -er '.producer.repository' "$policy")
workflow=$(jq -er '.producer.workflow' "$policy")
expected_commit=$(jq -er '.candidate.producer_commit' "$request")
run_id=$(jq -er '.candidate.run_id' "$request")
run_attempt=$(jq -er '.candidate.run_attempt' "$request")
expected_ref=$(jq -er --arg workflow "$workflow" '
    .producer.allowed_refs
    | if length == 1 then .[0] else error("policy must select one sandbox ref") end
' "$policy")

arguments=(
    "$bundle"
    --repo "$repository"
    --predicate-type https://slsa.dev/provenance/v1
    --signer-workflow "$repository/$workflow"
    --source-ref "$expected_ref"
    --source-digest "$expected_commit"
    --signer-digest "$expected_commit"
)

if jq -e '.producer.require_github_hosted_runner == true' "$policy" >/dev/null; then
    arguments+=(--deny-self-hosted-runners)
fi

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
raw_receipt="$temporary/verification.json"
gh attestation verify "${arguments[@]}" --format json >"$raw_receipt"
invocation="https://github.com/$repository/actions/runs/$run_id/attempts/$run_attempt"
jq -e --arg invocation "$invocation" '
    [
        .[]
        | select(
            .verificationResult.signature.certificate.runInvocationURI == $invocation
        )
    ]
    | if length >= 1 then . else error("no attestation matched the requested run attempt") end
' "$raw_receipt" >"$receipt"
