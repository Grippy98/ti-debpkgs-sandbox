#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <policy.json> <snapshot-tag> <destination>" >&2
    exit 2
fi

policy=$1
tag=$2
destination=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository=$(jq -er '.archive_repository' "$policy")
snapshot_limit=$(jq -er '.limits.snapshot_bytes' "$policy")
metadata_limit=$(jq -er '.limits.snapshot_metadata_bytes' "$policy")

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required to recover an archive snapshot" >&2
    exit 2
fi
if [[ ! "$tag" =~ ^archive-snapshot-[1-9][0-9]*-[1-9][0-9]*$ ]]; then
    echo "Recovery requires one exact archive snapshot tag" >&2
    exit 2
fi
if [ -e "$destination" ]; then
    echo "Recovery destination already exists: $destination" >&2
    exit 1
fi

releases=$(gh api --paginate --slurp "repos/$repository/releases?per_page=100")
latest_tag=$(jq -er '
    first(
        .[][]
        | select(.prerelease == false)
        | select(.tag_name | startswith("archive-snapshot-"))
        | .tag_name
    )
' <<<"$releases")
if [ "$tag" != "$latest_tag" ]; then
    echo "Recovery is restricted to the newest snapshot: $latest_tag" >&2
    exit 1
fi
release=$(jq -cer --arg tag "$tag" '
    [
        .[][]
        | select(.prerelease == false and .tag_name == $tag)
    ]
    | if length == 1 then .[0] else error("snapshot release is missing or duplicated") end
' <<<"$releases")
if ! jq -e \
    '.id | select(type == "number" and . >= 1 and floor == .)' \
    <<<"$release" >/dev/null; then
    echo "Snapshot release has an invalid numeric ID" >&2
    exit 1
fi
if ! jq -e '.draft | type == "boolean"' <<<"$release" >/dev/null; then
    echo "Snapshot release has invalid draft metadata" >&2
    exit 1
fi
if ! jq -e '
    [.assets[].name] | sort == [
        "SHA256SUMS",
        "archive-state.tar.gz",
        "receipt.json",
        "snapshot.json",
        "snapshot.json.asc"
    ]
' <<<"$release" >/dev/null; then
    echo "Snapshot release does not contain the exact recovery asset set" >&2
    exit 1
fi

mkdir -p "$destination/assets"
printf '%s\n' "$release" >"$destination/release.json"

download_asset() {
    local name=$1
    local limit=$2
    local asset asset_id expected_digest expected_size actual_digest
    asset=$(jq -cer --arg name "$name" '
        [.assets[] | select(.name == $name)]
        | if length == 1 and .[0].state == "uploaded" then .[0]
          else error("snapshot asset is missing, duplicated, or incomplete") end
    ' <<<"$release")
    asset_id=$(jq -er \
        '.id | select(type == "number" and . >= 1 and floor == .)' <<<"$asset")
    expected_digest=$(jq -er \
        '.digest | select(test("^sha256:[0-9a-f]{64}$"))' <<<"$asset")
    expected_size=$(jq -er --argjson limit "$limit" \
        '.size | select(type == "number" and . >= 1 and . <= $limit)' <<<"$asset")
    gh api --method GET -H 'Accept: application/octet-stream' \
        "repos/$repository/releases/assets/$asset_id" \
        >"$destination/assets/$name"
    if [ "$(stat -c %s "$destination/assets/$name")" -ne "$expected_size" ]; then
        echo "Recovered asset size does not match release metadata: $name" >&2
        exit 1
    fi
    actual_digest="sha256:$(sha256sum "$destination/assets/$name" | awk '{print $1}')"
    if [ "$actual_digest" != "$expected_digest" ]; then
        echo "Recovered asset digest does not match release metadata: $name" >&2
        exit 1
    fi
}

download_asset archive-state.tar.gz "$snapshot_limit"
download_asset receipt.json "$metadata_limit"
download_asset snapshot.json "$metadata_limit"
download_asset snapshot.json.asc "$metadata_limit"
download_asset SHA256SUMS "$metadata_limit"

(
    cd "$destination/assets"
    if [ "$(wc -l <SHA256SUMS)" -ne 4 ] || \
       [ "$(awk '{print $2}' SHA256SUMS | LC_ALL=C sort | tr '\n' ' ')" != \
         'archive-state.tar.gz receipt.json snapshot.json snapshot.json.asc ' ]; then
        echo "Release checksum manifest has an unexpected file set" >&2
        exit 1
    fi
    sha256sum --check --strict SHA256SUMS
)

"$script_dir/verify-snapshot-metadata.sh" \
    "$destination/assets/archive-state.tar.gz" \
    "$destination/assets/snapshot.json" \
    "$destination/assets/snapshot.json.asc" \
    "$tag" "$policy"
if [ "$(jq -er '.publisher.commit' "$destination/assets/snapshot.json")" != \
     "$(jq -er '.target_commitish | select(test("^[0-9a-f]{40}$"))' <<<"$release")" ]; then
    echo "Recovery release target does not match its signed publisher commit" >&2
    exit 1
fi
receipt_size=$(jq -er '.receipt.size' "$destination/assets/snapshot.json")
receipt_digest=$(jq -er '.receipt.sha256' "$destination/assets/snapshot.json")
if [ "$(stat -c %s "$destination/assets/receipt.json")" -ne "$receipt_size" ] || \
   [ "$(sha256sum "$destination/assets/receipt.json" | awk '{print $1}')" != "$receipt_digest" ]; then
    echo "Recovery receipt does not match signed snapshot metadata" >&2
    exit 1
fi

"$script_dir/restore-state.py" \
    "$destination/assets/archive-state.tar.gz" "$policy" "$destination/state"
mkdir -p "$destination/state/conf"
cp "$script_dir/../archive/conf/options" "$destination/state/conf/options"
"$script_dir/render-config.sh" \
    "$script_dir/../archive/conf/distributions.in" \
    "$destination/state/conf/distributions" \
    "$(jq -er '.signing.fingerprint' "$policy")"
"$script_dir/verify-archive.sh" "$destination/state" "$policy" trixie
"$script_dir/make-pages-site.sh" \
    "$destination/state" "$policy" "$destination/pages" \
    "$destination/assets/snapshot.json" "$destination/assets/snapshot.json.asc"
printf '%s\n' "$tag"
