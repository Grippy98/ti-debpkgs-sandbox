#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <archive-state> <destination.tar.gz>" >&2
    exit 2
fi

archive_state=$1
destination=$2

if [ -e "$destination" ]; then
    echo "Snapshot destination already exists: $destination" >&2
    exit 1
fi
if [ ! -f "$archive_state/ARCHIVE-SHA256SUMS" ]; then
    echo "Archive state has not passed verify-archive.sh" >&2
    exit 1
fi

tar --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -czf "$destination" \
    -C "$archive_state" \
    ARCHIVE-SHA256SUMS audit db dists pool
