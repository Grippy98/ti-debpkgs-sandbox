#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <template> <destination> <signing-fingerprint>" >&2
    exit 2
fi

template=$1
destination=$2
fingerprint=${3^^}

if [[ ! "$fingerprint" =~ ^[0-9A-F]{40}$ ]]; then
    echo "Signing fingerprint must be exactly 40 hexadecimal characters" >&2
    exit 2
fi

mkdir -p "$(dirname "$destination")"
sed "s/@SIGNING_FINGERPRINT@/$fingerprint/g" "$template" >"$destination"
