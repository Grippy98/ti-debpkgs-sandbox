#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <repository-uri> <public-key> <receipt.json>" >&2
    exit 2
fi

repository_uri=$1
public_key=$2
receipt=$3
suite=$(jq -er '.suite' "$receipt")
component=$(jq -er '.component' "$receipt")
action=$(jq -er '.action' "$receipt")
source_name=$(jq -er '.source.name' "$receipt")
source_version=$(jq -er '.source.version' "$receipt")
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

mkdir -p \
    "$temporary/etc/apt/keyrings" \
    "$temporary/var/lib/apt/lists/partial" \
    "$temporary/var/cache/apt/archives/partial" \
    "$temporary/downloads"
gpg --batch --no-tty --dearmor \
    --output "$temporary/etc/apt/keyrings/archive.gpg" "$public_key"
keyring="$temporary/etc/apt/keyrings/archive.gpg"
{
    printf 'deb [arch=arm64 signed-by=%s] %s %s %s\n' \
        "$keyring" "$repository_uri" "$suite" "$component"
    printf 'deb-src [signed-by=%s] %s %s %s\n' \
        "$keyring" "$repository_uri" "$suite" "$component"
} >"$temporary/sources.list"

apt_options=(
    -o "Dir::Etc::sourcelist=$temporary/sources.list"
    -o 'Dir::Etc::sourceparts=-'
    -o 'Dir::Etc::trusted=-'
    -o 'Dir::Etc::trustedparts=-'
    -o "Dir::State::lists=$temporary/var/lib/apt/lists"
    -o "Dir::Cache::archives=$temporary/var/cache/apt/archives"
    -o 'APT::Architecture=arm64'
    -o 'APT::Architectures::=arm64'
)
apt-get "${apt_options[@]}" update

source_count=$(
    (apt-cache "${apt_options[@]}" showsrc "$source_name" 2>/dev/null || true) |
        awk -F ': *' -v expected="$source_version" '
            /^Version:/ && $2 == expected {count++}
            END {print count + 0}
        '
)
if [ "$action" = include ]; then
    if [ "$source_count" -ne 1 ]; then
        echo "Published source version is not visible through APT" >&2
        exit 1
    fi
    while IFS=$'\t' read -r package version architecture; do
        [ -n "$package" ] || continue
        (
            cd "$temporary/downloads"
            apt-get "${apt_options[@]}" download "$package=$version"
        )
        downloaded=$(find "$temporary/downloads" -maxdepth 1 -type f \
            -name "${package}_*.deb" -print -quit)
        if [ -z "$downloaded" ] || \
           [ "$(dpkg-deb --field "$downloaded" Package)" != "$package" ] || \
           [ "$(dpkg-deb --field "$downloaded" Version)" != "$version" ] || \
           [ "$(dpkg-deb --field "$downloaded" Architecture)" != "$architecture" ]; then
            echo "Downloaded binary does not match publication receipt: $package" >&2
            exit 1
        fi
        rm -f "$downloaded"
    done < <(jq -er '.binaries[] | [.package, .version, .architecture] | @tsv' "$receipt")
else
    if [ "$source_count" -ne 0 ]; then
        echo "Removed source version remains visible through APT" >&2
        exit 1
    fi
fi
