#!/bin/bash

set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <request.json> <policy.json> <archive-state-or-dash> <candidate-dir-or-dash> <summary.md>" >&2
    exit 2
fi

request=$1
policy=$2
archive_state=$3
candidate_dir=$4
summary=$5
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$script_dir/validate-request.py" "$request" "$policy"
request_id=$(jq -er '.request_id' "$request")
action=$(jq -er '.action' "$request")
suite=$(jq -er '.suite' "$request")
component=$(jq -er '.component' "$request")
reason=$(jq -er '.reason' "$request")

if [ "$archive_state" != - ]; then
    if [ ! -f "$archive_state/conf/distributions" ]; then
        echo "Restored archive state is incomplete" >&2
        exit 1
    fi
    if [ -e "$archive_state/audit/requests/$request_id" ]; then
        echo "Request has already been published: $request_id" >&2
        exit 1
    fi
fi

escape_markdown() {
    local value=$1
    jq -nr --arg value "$value" '$value | @html | gsub("\\|"; "&#124;")'
}

{
    echo '# Sandbox publication plan'
    echo
    echo '| Field | Value |'
    echo '| --- | --- |'
    printf '| Request | <code>%s</code> |\n' "$(escape_markdown "$request_id")"
    printf '| Action | <code>%s</code> |\n' "$action"
    printf '| Target | <code>%s/%s</code> |\n' "$suite" "$component"
    printf '| Reason | %s |\n' "$(escape_markdown "$reason")"
} >"$summary"

if [ "$action" = include ]; then
    manifest="$candidate_dir/manifest.json"
    if [ "$candidate_dir" = - ] || [ ! -f "$manifest" ]; then
        echo "Include planning requires a verified candidate" >&2
        exit 1
    fi
    source_name=$(jq -er '.source.name' "$manifest")
    source_version=$(jq -er '.source.version' "$manifest")
    dpkg --validate-version "$source_version"

    published_versions=()
    if [ "$archive_state" != - ]; then
        published_output=$(
            # reprepro expands its own ${version} placeholder.
            # shellcheck disable=SC2016
            reprepro -b "$archive_state" -T dsc --list-format='${version}\n' \
                list "$suite" "$source_name"
        )
        if [ -n "$published_output" ]; then
            mapfile -t published_versions <<<"$published_output"
        fi
    fi
    for published in "${published_versions[@]}"; do
        [ -n "$published" ] || continue
        if ! dpkg --compare-versions "$source_version" gt "$published"; then
            echo "Candidate $source_version does not supersede published $published" >&2
            exit 1
        fi
    done

    {
        printf '| Source | <code>%s</code> |\n' "$(escape_markdown "$source_name")"
        printf '| Candidate version | <code>%s</code> |\n' "$(escape_markdown "$source_version")"
        if [ "${#published_versions[@]}" -eq 0 ]; then
            echo '| Current source versions | _none_ |'
        else
            versions=$(IFS=', '; echo "${published_versions[*]}")
            printf '| Current source versions | <code>%s</code> |\n' "$(escape_markdown "$versions")"
        fi
        printf '| Producer commit | <code>%s</code> |\n' "$(jq -er '.producer.commit' "$manifest")"
        printf '| Producer run | <code>%s</code> attempt <code>%s</code> |\n' \
            "$(jq -er '.producer.run_id' "$manifest")" \
            "$(jq -er '.producer.run_attempt' "$manifest")"
        printf '| Candidate SHA-256 | <code>%s</code> |\n' \
            "$(jq -er '.candidate.bundle_sha256' "$request")"
    } >>"$summary"
else
    source_name=$(jq -er '.source.name' "$request")
    source_version=$(jq -er '.source.version' "$request")
    dpkg --validate-version "$source_version"
    if [ "$archive_state" = - ]; then
        echo "Cannot remove a package from an empty archive" >&2
        exit 1
    fi
    count=$(
        # reprepro expands its own ${package} and ${version} placeholders.
        # shellcheck disable=SC2016
        reprepro -b "$archive_state" -T dsc \
            --list-format='${package}|${version}\n' \
            list "$suite" "$source_name" |
            awk -F '|' -v source="$source_name" -v version="$source_version" \
                '$1 == source && $2 == version {count++} END {print count + 0}'
    )
    if [ "$count" -ne 1 ]; then
        echo "Removal requires exactly one published source version; found $count" >&2
        exit 1
    fi
    {
        printf '| Source | <code>%s</code> |\n' "$(escape_markdown "$source_name")"
        printf '| Exact version to remove | <code>%s</code> |\n' "$(escape_markdown "$source_version")"
    } >>"$summary"
fi
