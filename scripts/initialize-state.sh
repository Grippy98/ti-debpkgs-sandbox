#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <archive-state> <policy.json> <archive-template-dir>" >&2
    exit 2
fi

archive_state=$1
policy=$2
template_dir=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
expected_fingerprint=$(jq -er '.signing.fingerprint' "$policy")

if [ -e "$archive_state" ]; then
    echo "Archive state destination already exists: $archive_state" >&2
    exit 1
fi
if [ -z "${GNUPGHOME:-}" ] || [ ! -d "$GNUPGHOME" ]; then
    echo "GNUPGHOME must name the isolated publisher keyring" >&2
    exit 1
fi

actual_fingerprint=$(gpg --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" {print $10; exit}')
if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
    echo "Publisher secret key does not match sandbox signing policy" >&2
    exit 1
fi

mkdir -p "$archive_state/conf" "$archive_state/audit/requests"
cp "$template_dir/conf/options" "$archive_state/conf/options"
"$script_dir/render-config.sh" \
    "$template_dir/conf/distributions.in" \
    "$archive_state/conf/distributions" \
    "$actual_fingerprint"
reprepro -b "$archive_state" export trixie
