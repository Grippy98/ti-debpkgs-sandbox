#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <policy.json> <destination>" >&2
    exit 2
fi

policy=$1
destination=$2
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository=$(jq -er '.archive_repository' "$policy")
publication_url=$(jq -er '.publication_url' "$policy")
snapshot_limit=$(jq -er '.limits.snapshot_bytes' "$policy")
metadata_limit=$(jq -er '.limits.snapshot_metadata_bytes' "$policy")

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required to restore archive state" >&2
    exit 2
fi
if [ -e "$destination" ]; then
    echo "Archive-state destination already exists: $destination" >&2
    exit 1
fi

releases=$(gh api --paginate --slurp "repos/$repository/releases?per_page=100")
if jq -e '
    any(
        .[][];
        .draft == true and
        .prerelease == false and
        (.tag_name | startswith("archive-snapshot-"))
    )
' <<<"$releases" >/dev/null; then
    echo "An unfinished snapshot draft exists; recover it before publishing again" >&2
    exit 1
fi
release=$(jq -c '
    first(
        .[][]
        | select(.draft == false and .prerelease == false)
        | select(.tag_name | startswith("archive-snapshot-"))
    ) // null
' <<<"$releases")
if [ "$release" = null ]; then
    pages_status=$(curl --head --location --silent --show-error \
        --output /dev/null --write-out '%{http_code}' \
        "${publication_url%/}/snapshot.json") || {
        echo "Could not determine whether a deployed archive head exists" >&2
        exit 1
    }
    if [ "$pages_status" != 404 ]; then
        echo "No snapshot release was found, but the Pages archive is not empty (HTTP $pages_status)" >&2
        exit 1
    fi
    echo "No archive snapshot release exists yet" >&2
    exit 3
fi

tag=$(jq -er '.tag_name' <<<"$release")
if ! jq -e \
    '.id | select(type == "number" and . >= 1 and floor == .)' \
    <<<"$release" >/dev/null; then
    echo "Snapshot release has an invalid numeric ID" >&2
    exit 1
fi
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

download_asset() {
    local name=$1
    local limit=$2
    local asset asset_id expected_digest actual_digest size
    asset=$(jq -cer --arg name "$name" '
        [.assets[] | select(.name == $name)]
        | if length == 1 and .[0].state == "uploaded" then .[0]
          else error("snapshot release asset is missing, duplicated, or incomplete") end
    ' <<<"$release")
    asset_id=$(jq -er \
        '.id | select(type == "number" and . >= 1 and floor == .)' <<<"$asset")
    expected_digest=$(jq -er \
        '.digest | select(test("^sha256:[0-9a-f]{64}$"))' <<<"$asset")
    size=$(jq -er --argjson limit "$limit" \
        '.size | select(type == "number" and . >= 1 and . <= $limit)' <<<"$asset")
    gh api --method GET -H 'Accept: application/octet-stream' \
        "repos/$repository/releases/assets/$asset_id" >"$temporary/$name"
    if [ "$(stat -c %s "$temporary/$name")" -ne "$size" ]; then
        echo "Downloaded release asset size does not match: $name" >&2
        exit 1
    fi
    actual_digest="sha256:$(sha256sum "$temporary/$name" | awk '{print $1}')"
    if [ "$actual_digest" != "$expected_digest" ]; then
        echo "Downloaded release asset digest does not match: $name" >&2
        exit 1
    fi
}

download_asset archive-state.tar.gz "$snapshot_limit"
download_asset snapshot.json "$metadata_limit"
download_asset snapshot.json.asc "$metadata_limit"

snapshot="$temporary/archive-state.tar.gz"
manifest="$temporary/snapshot.json"
signature="$temporary/snapshot.json.asc"
"$script_dir/verify-snapshot-metadata.sh" \
    "$snapshot" "$manifest" "$signature" "$tag" "$policy"
if [ "$(jq -er '.publisher.commit' "$manifest")" != \
     "$(jq -er '.target_commitish | select(test("^[0-9a-f]{40}$"))' <<<"$release")" ]; then
    echo "Snapshot release target does not match its signed publisher commit" >&2
    exit 1
fi

pages_manifest="$temporary/pages-snapshot.json"
if ! curl --fail --location --silent --show-error \
    --max-filesize "$metadata_limit" \
    --output "$pages_manifest" "${publication_url%/}/snapshot.json"; then
    echo "A snapshot release exists but the deployed Pages head is unavailable" >&2
    exit 1
fi
if [ "$(stat -c %s "$pages_manifest")" -gt "$metadata_limit" ]; then
    echo "Deployed Pages head exceeds the configured metadata limit" >&2
    exit 1
fi
if ! cmp "$manifest" "$pages_manifest"; then
    echo "Latest signed snapshot release does not match the deployed Pages head" >&2
    exit 1
fi

"$script_dir/restore-state.py" "$snapshot" "$policy" "$destination"
mkdir -p "$destination/conf"
cp "$script_dir/../archive/conf/options" "$destination/conf/options"
"$script_dir/render-config.sh" \
    "$script_dir/../archive/conf/distributions.in" \
    "$destination/conf/distributions" \
    "$(jq -er '.signing.fingerprint' "$policy")"
cp "$manifest" "$destination/.snapshot.json"
cp "$signature" "$destination/.snapshot.json.asc"
printf '%s\n' "$tag"
