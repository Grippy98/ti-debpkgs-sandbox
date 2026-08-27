#!/bin/bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <request.json> <policy.json> <work-directory> <allow-empty-state:true|false>" >&2
    exit 2
fi

request=$1
policy=$2
work=$3
allow_empty=$4
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository=$(cd "$script_dir/.." && pwd -P)

: "${ARCHIVE_GH_TOKEN:?ARCHIVE_GH_TOKEN is required}"

if [ -L "$request" ]; then
    echo "Publication request must not be a symbolic link" >&2
    exit 2
fi
request=$(realpath --canonicalize-existing -- "$request")
policy=$(realpath --canonicalize-existing -- "$policy")
case "$request" in
    "$repository"/requests/*.json) ;;
    *) echo "Request must be a committed JSON file under requests/" >&2; exit 2 ;;
esac
if [ "$policy" != "$repository/policy/archive.json" ]; then
    echo "Publication inputs do not match the reviewed repository files" >&2
    exit 2
fi
request_relative=${request#"$repository"/}
policy_relative=${policy#"$repository"/}
if ! git -C "$repository" ls-files --error-unmatch -- \
    "$request_relative" "$policy_relative" >/dev/null 2>&1; then
    echo "Publication inputs must be committed to the publisher repository" >&2
    exit 2
fi
if ! git -C "$repository" diff --quiet HEAD -- || \
   ! git -C "$repository" diff --cached --quiet HEAD --; then
    echo "Publisher repository has tracked changes after checkout" >&2
    exit 2
fi
case "$allow_empty" in
    true|false) ;;
    *) echo "allow-empty-state must be true or false" >&2; exit 2 ;;
esac
if [ -e "$work" ]; then
    echo "Publication work directory already exists: $work" >&2
    exit 1
fi
mkdir -p "$work"

set +e
state_tag=$(GH_TOKEN="$ARCHIVE_GH_TOKEN" \
    "$script_dir/fetch-state.sh" "$policy" "$work/state")
state_status=$?
set -e

case "$state_status" in
    0)
        archive_state="$work/state"
        printf '%s\n' "$state_tag" >"$work/predecessor-tag"
        ;;
    3)
        if [ "$allow_empty" != true ]; then
            echo "No signed archive state exists; explicit first-run initialization was not authorized" >&2
            exit 1
        fi
        archive_state=-
        : >"$work/predecessor-tag"
        ;;
    *)
        echo "Signed archive-state retrieval failed" >&2
        exit "$state_status"
        ;;
esac

action=$(jq -er '.action' "$request")
candidate=-
if [ "$action" = include ]; then
    : "${CANDIDATE_GH_TOKEN:?CANDIDATE_GH_TOKEN is required for include requests}"
    bundle=$(GH_TOKEN="$CANDIDATE_GH_TOKEN" \
        "$script_dir/fetch-candidate.sh" \
        "$request" "$policy" "$work/candidate-transport")

    # This is the trust boundary: verify the opaque bundle's GitHub provenance
    # before verify-candidate.py is allowed to open the tar archive.
    GH_TOKEN="$CANDIDATE_GH_TOKEN" \
        "$script_dir/verify-provenance.sh" \
        "$bundle" "$request" "$policy" "$work/attestation-verification.json"
    "$script_dir/verify-candidate.py" \
        "$bundle" "$request" "$policy" "$work/verified-candidate"
    candidate="$work/verified-candidate"
fi

"$script_dir/plan-request.sh" \
    "$request" "$policy" "$archive_state" "$candidate" "$work/plan.md"
printf '%s\n' "$archive_state" >"$work/archive-state-path"
printf '%s\n' "$candidate" >"$work/candidate-path"
