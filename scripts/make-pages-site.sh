#!/bin/bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <archive-state> <policy.json> <destination> <snapshot.json> <snapshot.json.asc>" >&2
    exit 2
fi

archive_state=$1
policy=$2
destination=$3
snapshot_manifest=$4
snapshot_signature=$5
public_key=$(jq -er '.signing.public_key' "$policy")
publication_url=$(jq -er '.publication_url' "$policy")

if [ -e "$destination" ]; then
    echo "Pages destination already exists: $destination" >&2
    exit 1
fi

mkdir -p "$destination"
cp -a "$archive_state/dists" "$archive_state/pool" "$destination/"
cp "$public_key" "$destination/sandbox-archive.asc"
cp "$snapshot_manifest" "$destination/snapshot.json"
cp "$snapshot_signature" "$destination/snapshot.json.asc"
touch "$destination/.nojekyll"

{
    echo 'Types: deb deb-src'
    echo "URIs: $publication_url"
    echo 'Suites: trixie'
    echo 'Components: main'
    echo 'Architectures: arm64'
    echo 'Signed-By:'
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            printf ' %s\n' "$line"
        else
            echo ' .'
        fi
    done <"$public_key"
} >"$destination/ti-debpkgs-sandbox.sources"

cat >"$destination/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>TI Debian Packages Sandbox</title></head>
<body>
<h1>TI Debian Packages Sandbox</h1>
<p>This is a disposable, test-only signed APT repository.</p>
<p><a href="ti-debpkgs-sandbox.sources">Download the deb822 source definition</a></p>
<p><a href="snapshot.json">View the signed archive-state head</a></p>
</body>
</html>
EOF
