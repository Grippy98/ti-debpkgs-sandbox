#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <request.json> <policy.json> <destination-dir>" >&2
    exit 2
fi

request=$1
policy=$2
destination=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required to fetch a candidate" >&2
    exit 2
fi

"$script_dir/validate-request.py" "$request" "$policy"
if [ "$(jq -r '.action' "$request")" != include ]; then
    echo "Candidate retrieval is only valid for include requests" >&2
    exit 2
fi
if [ -e "$destination" ]; then
    echo "Candidate destination already exists: $destination" >&2
    exit 1
fi
mkdir -p "$destination"
curl_config=$(mktemp)
trap 'rm -f "$curl_config"' EXIT
chmod 0600 "$curl_config"
printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" >"$curl_config"

repository=$(jq -er '.producer.repository' "$policy")
workflow=$(jq -er '.producer.workflow' "$policy")
run_id=$(jq -er '.candidate.run_id' "$request")
run_attempt=$(jq -er '.candidate.run_attempt' "$request")
artifact_id=$(jq -er '.candidate.artifact_id' "$request")
artifact_name=$(jq -er '.candidate.artifact_name' "$request")
artifact_digest=$(jq -er '.candidate.artifact_digest' "$request")
bundle_name=$(jq -er '.candidate.bundle' "$request")
bundle_sha256=$(jq -er '.candidate.bundle_sha256' "$request")
producer_commit=$(jq -er '.candidate.producer_commit' "$request")
maximum_bytes=$(jq -er '.limits.candidate_bytes' "$policy")

run_json="$destination/run.json"
artifact_json="$destination/artifact.json"
gh api "repos/$repository/actions/runs/$run_id/attempts/$run_attempt" >"$run_json"

jq -e \
    --arg repository "$repository" \
    --arg workflow "$workflow" \
    --arg commit "$producer_commit" \
    --argjson run_id "$run_id" \
    --argjson run_attempt "$run_attempt" \
    --slurpfile policy "$policy" '
      . as $run |
      $run.id == $run_id and
      $run.run_attempt == $run_attempt and
      $run.status == "completed" and
      $run.conclusion == "success" and
      $run.head_repository.full_name == $repository and
      $run.head_sha == $commit and
      ($run.path | split("@")[0]) == $workflow and
      ([ $policy[0].producer.allowed_events[] ] | index($run.event)) != null and
      ([ $policy[0].producer.allowed_refs[] ] | index("refs/heads/" + $run.head_branch)) != null
    ' "$run_json" >/dev/null || {
        echo "Producer workflow run does not satisfy sandbox policy" >&2
        exit 1
    }

gh api "repos/$repository/actions/artifacts/$artifact_id" >"$artifact_json"
jq -e \
    --arg name "$artifact_name" \
    --arg digest "$artifact_digest" \
    --argjson artifact_id "$artifact_id" \
    --argjson run_id "$run_id" \
    --argjson maximum_bytes "$maximum_bytes" '
      .id == $artifact_id and
      .name == $name and
      .expired == false and
      .digest == $digest and
      .workflow_run.id == $run_id and
      (.size_in_bytes | type == "number" and . >= 1 and . <= $maximum_bytes)
    ' "$artifact_json" >/dev/null || {
        echo "Actions artifact does not satisfy publication request" >&2
        exit 1
    }

transport="$destination/artifact.zip"
GH_TOKEN='' curl --config "$curl_config" \
    --fail --location --silent --show-error \
    --max-filesize "$maximum_bytes" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "$transport" \
    "https://api.github.com/repos/$repository/actions/artifacts/$artifact_id/zip"

if [ "$(stat -c %s "$transport")" -gt "$maximum_bytes" ]; then
    echo "Downloaded Actions artifact exceeds the configured size limit" >&2
    exit 1
fi

transport_sha256=$(sha256sum "$transport" | awk '{print $1}')
if [ "sha256:$transport_sha256" != "$artifact_digest" ]; then
    echo "Downloaded Actions artifact digest does not match request" >&2
    exit 1
fi

"$script_dir/extract-transport.py" \
    "$transport" "$bundle_name" "$bundle_sha256" "$maximum_bytes" \
    "$destination/$bundle_name"
printf '%s\n' "$destination/$bundle_name"
