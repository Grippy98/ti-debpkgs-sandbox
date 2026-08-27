#!/bin/bash

set -euo pipefail

# gh <= 2.96.0 is vulnerable to GHSA-mm27-mwq9-fr5g. Keep this version and
# both package digests pinned so provenance policy cannot silently depend on a
# stale runner image or a mutable package repository.
version=2.98.0
architecture=$(dpkg --print-architecture)

case "$architecture" in
    arm64)
        digest=bbc4ac7964c2a091fd555cd1758d10a7cfcfdc472e405f0b0fb958f05d535cb6
        ;;
    amd64)
        digest=f65a3fa2fa0eb2e97c445ee3f5e087a40aae03b64847f45a8f13805e504535d6
        ;;
    *)
        echo "Unsupported architecture for pinned GitHub CLI: $architecture" >&2
        exit 1
        ;;
esac

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
package="$temporary/gh_${version}_linux_${architecture}.deb"
url="https://github.com/cli/cli/releases/download/v${version}/${package##*/}"

curl --fail --location --silent --show-error --output "$package" "$url"
printf '%s  %s\n' "$digest" "$package" | sha256sum --check --status
dpkg --install "$package" >/dev/null

installed=$(gh --version | awk 'NR == 1 {print $3}')
if [ "$installed" != "$version" ]; then
    echo "Pinned GitHub CLI installation failed: expected $version, got $installed" >&2
    exit 1
fi
