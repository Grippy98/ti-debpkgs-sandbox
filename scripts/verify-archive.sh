#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <archive-state> <policy.json> <suite>" >&2
    exit 2
fi

archive_state=$1
policy=$2
suite=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
public_key=$(jq -er '.signing.public_key' "$policy")
expected_fingerprint=$(jq -er '.signing.fingerprint' "$policy")
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
    echo "Committed public key fingerprint does not match archive policy" >&2
    exit 1
fi
gpg --batch --no-tty --dearmor --output "$temporary/archive-keyring.gpg" "$public_key"

# Authenticate exported metadata before invoking reprepro against restored state.
gpgv --keyring "$temporary/archive-keyring.gpg" \
    "$archive_state/dists/$suite/InRelease"
gpgv --keyring "$temporary/archive-keyring.gpg" \
    "$archive_state/dists/$suite/Release.gpg" \
    "$archive_state/dists/$suite/Release"

mkdir -p "$temporary/expected-conf"
cp "$script_dir/../archive/conf/options" "$temporary/expected-conf/options"
"$script_dir/render-config.sh" \
    "$script_dir/../archive/conf/distributions.in" \
    "$temporary/expected-conf/distributions" "$expected_fingerprint"
if ! diff -ru "$temporary/expected-conf" "$archive_state/conf"; then
    echo "Archive configuration differs from the reviewed template" >&2
    exit 1
fi

reprepro -b "$archive_state" check "$suite"
reprepro -b "$archive_state" checkpool
mkdir -p "$archive_state/pool"

(
    cd "$archive_state"
    find audit db dists pool -type f -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum >ARCHIVE-SHA256SUMS
    sha256sum --check ARCHIVE-SHA256SUMS
)
