#!/bin/bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <archive-state> <request.json> <policy.json> <verified-candidate-dir> <provenance-receipt-or-dash>" >&2
    exit 2
fi

archive_state=$1
request=$2
policy=$3
candidate_dir=$4
provenance_receipt=$5
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$script_dir/validate-request.py" "$request" "$policy"

request_id=$(jq -er '.request_id' "$request")
action=$(jq -er '.action' "$request")
suite=$(jq -er '.suite' "$request")
component=$(jq -er '.component' "$request")
audit_dir="$archive_state/audit/requests/$request_id"
receipt_source_name=
receipt_source_version=
receipt_binaries='[]'
receipt_provenance='null'

if [ -e "$audit_dir" ]; then
    echo "Request has already been applied: $request_id" >&2
    exit 1
fi
if [ ! -f "$archive_state/conf/distributions" ]; then
    echo "Archive state is not initialized: $archive_state" >&2
    exit 1
fi

read_control_field() {
    local file=$1
    local field=$2
    awk -F ': *' -v field="$field" '
        $1 == field {
            count++
            value = substr($0, index($0, ":") + 1)
            sub(/^[[:space:]]+/, "", value)
        }
        END {
            if (count != 1) exit 1
            print value
        }
    ' "$file"
}

list_source_rows() {
    local source_name=$1
    # reprepro expands its own ${field} placeholders.
    # shellcheck disable=SC2016
    reprepro -b "$archive_state" -T dsc \
        --list-format='${package}|${version}\n' \
        list "$suite" "$source_name"
}

include_candidate() {
    local manifest="$candidate_dir/manifest.json"
    local payload="$candidate_dir/payload"
    local source_name source_version
    local dsc changes buildinfo
    local dsc_source dsc_version
    local deb package version architecture source_field binary_source
    local existing_version existing_versions invocation
    local -a debs dsc_files changes_files buildinfo_files

    if [ ! -f "$manifest" ] || [ ! -d "$payload" ]; then
        echo "Verified candidate directory is incomplete" >&2
        exit 1
    fi
    if [ "$provenance_receipt" = - ] || [ ! -f "$provenance_receipt" ]; then
        echo "Include publication requires a successful attestation receipt" >&2
        exit 1
    fi
    invocation="https://github.com/$(jq -er '.producer.repository' "$policy")/actions/runs/$(jq -er '.candidate.run_id' "$request")/attempts/$(jq -er '.candidate.run_attempt' "$request")"
    if ! jq -e --arg invocation "$invocation" '
        type == "array" and length >= 1 and
        any(.[]; .verificationResult.signature.certificate.runInvocationURI == $invocation)
    ' "$provenance_receipt" >/dev/null; then
        echo "Attestation receipt does not match the requested workflow run attempt" >&2
        exit 1
    fi

    source_name=$(jq -er '.source.name' "$manifest")
    source_version=$(jq -er '.source.version' "$manifest")
    dpkg --validate-version "$source_version"
    receipt_source_name=$source_name
    receipt_source_version=$source_version
    receipt_provenance=$(jq -cn \
        --slurpfile manifest "$manifest" \
        --slurpfile request "$request" '
        {
            producer: $manifest[0].producer,
            bundle_sha256: $request[0].candidate.bundle_sha256,
            artifact_id: $request[0].candidate.artifact_id,
            artifact_digest: $request[0].candidate.artifact_digest
        }
    ')
    receipt_provenance=$(jq -c \
        --arg verification_sha256 "$(sha256sum "$provenance_receipt" | awk '{print $1}')" \
        '. + {verification_sha256: $verification_sha256}' \
        <<<"$receipt_provenance")
    mapfile -t debs < <(find "$payload" -maxdepth 1 -type f -name '*.deb' -print | LC_ALL=C sort)
    mapfile -t dsc_files < <(find "$payload" -maxdepth 1 -type f -name '*.dsc' -print)
    mapfile -t changes_files < <(find "$payload" -maxdepth 1 -type f -name '*.changes' -print)
    mapfile -t buildinfo_files < <(find "$payload" -maxdepth 1 -type f -name '*.buildinfo' -print)
    if [ "${#debs[@]}" -lt 1 ] || [ "${#dsc_files[@]}" -ne 1 ] || \
       [ "${#changes_files[@]}" -ne 1 ] || [ "${#buildinfo_files[@]}" -ne 1 ]; then
        echo "Candidate does not contain the required Debian artifacts" >&2
        exit 1
    fi
    dsc=${dsc_files[0]}
    changes=${changes_files[0]}
    buildinfo=${buildinfo_files[0]}

    dsc_source=$(read_control_field "$dsc" Source)
    dsc_version=$(read_control_field "$dsc" Version)
    if [ "$dsc_source" != "$source_name" ] || [ "$dsc_version" != "$source_version" ]; then
        echo "Source package metadata does not match candidate manifest" >&2
        exit 1
    fi

    existing_versions=$(
        # shellcheck disable=SC2016
        reprepro -b "$archive_state" -T dsc --list-format='${version}\n' \
            list "$suite" "$source_name"
    )
    while IFS= read -r existing_version; do
        [ -n "$existing_version" ] || continue
        if ! dpkg --compare-versions "$source_version" gt "$existing_version"; then
            echo "Source version $source_version does not supersede published $existing_version" >&2
            exit 1
        fi
    done <<<"$existing_versions"

    for deb in "${debs[@]}"; do
        package=$(dpkg-deb --field "$deb" Package)
        version=$(dpkg-deb --field "$deb" Version)
        architecture=$(dpkg-deb --field "$deb" Architecture)
        source_field=$(dpkg-deb --field "$deb" Source 2>/dev/null || true)
        binary_source=${source_field%% *}
        if [ -z "$binary_source" ]; then
            binary_source=$package
        fi
        if [ "$version" != "$source_version" ] || [ "$binary_source" != "$source_name" ]; then
            echo "Binary metadata does not match source manifest: ${deb##*/}" >&2
            exit 1
        fi
        if ! jq -e --arg architecture "$architecture" \
            '.build.binary_architectures | index($architecture) != null' \
            "$manifest" >/dev/null; then
            echo "Binary architecture is not declared by manifest: ${deb##*/}" >&2
            exit 1
        fi
        receipt_binaries=$(jq -cn \
            --argjson current "$receipt_binaries" \
            --arg package "$package" \
            --arg version "$version" \
            --arg architecture "$architecture" \
            '$current + [{package: $package, version: $version, architecture: $architecture}]')

        existing_versions=$(
            # shellcheck disable=SC2016
            reprepro -b "$archive_state" -T deb -A "$architecture" \
                --list-format='${version}\n' list "$suite" "$package"
        )
        while IFS= read -r existing_version; do
            [ -n "$existing_version" ] || continue
            if ! dpkg --compare-versions "$version" gt "$existing_version"; then
                echo "$package version $version does not supersede published $existing_version" >&2
                exit 1
            fi
        done <<<"$existing_versions"
    done

    # The current cc33conf changelog says UNRELEASED. Import the verified source
    # and binaries explicitly into the manifest's allow-listed target instead
    # of weakening reprepro with --ignore=wrongdistribution.
    reprepro -b "$archive_state" --export=never -C "$component" \
        includedsc "$suite" "$dsc"
    for deb in "${debs[@]}"; do
        reprepro -b "$archive_state" --export=never -C "$component" \
            includedeb "$suite" "$deb"
    done

    mkdir -p "$audit_dir"
    cp "$request" "$audit_dir/request.json"
    cp "$manifest" "$audit_dir/manifest.json"
    cp "$changes" "$audit_dir/"
    cp "$buildinfo" "$audit_dir/"
    cp "$provenance_receipt" "$audit_dir/attestation-verification.json"
}

remove_source() {
    local source_name source_version before after
    source_name=$(jq -er '.source.name' "$request")
    source_version=$(jq -er '.source.version' "$request")
    dpkg --validate-version "$source_version"
    if [ "$provenance_receipt" != - ]; then
        echo "Removal requests must not supply a candidate provenance receipt" >&2
        exit 1
    fi
    if ! jq -e --arg suite "$suite" --arg component "$component" '
        .suites[$suite].components == [$component]
    ' "$policy" >/dev/null; then
        echo "Exact source removal requires a single-component suite policy" >&2
        exit 1
    fi
    receipt_source_name=$source_name
    receipt_source_version=$source_version

    before=$(list_source_rows "$source_name" | awk -F '|' \
        -v source="$source_name" -v version="$source_version" \
        '$1 == source && $2 == version {count++} END {print count + 0}')
    if [ "$before" -eq 0 ]; then
        echo "Source version is not currently published: $source_name $source_version" >&2
        exit 1
    fi

    reprepro -b "$archive_state" --export=never \
        removesrc "$suite" "$source_name" "$source_version"

    after=$(list_source_rows "$source_name" | awk -F '|' \
        -v source="$source_name" -v version="$source_version" \
        '$1 == source && $2 == version {count++} END {print count + 0}')
    if [ "$after" -ne 0 ]; then
        echo "Exact source removal left published records behind" >&2
        exit 1
    fi

    mkdir -p "$audit_dir"
    cp "$request" "$audit_dir/request.json"
}

case "$action" in
    include) include_candidate ;;
    remove-source) remove_source ;;
    *) echo "Unsupported action after validation: $action" >&2; exit 2 ;;
esac

reprepro -b "$archive_state" export "$suite"
mkdir -p "$archive_state/pool"

jq -n \
    --arg request_id "$request_id" \
    --arg action "$action" \
    --arg suite "$suite" \
    --arg component "$component" \
    --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source_name "$receipt_source_name" \
    --arg source_version "$receipt_source_version" \
    --argjson binaries "$receipt_binaries" \
    --argjson provenance "$receipt_provenance" \
    '{
        schema: "ti.debpkgs.receipt/v1",
        request_id: $request_id,
        action: $action,
        suite: $suite,
        component: $component,
        published_at: $published_at,
        source: {name: $source_name, version: $source_version},
        binaries: $binaries,
        provenance: $provenance
    }' >"$audit_dir/receipt.json"
