#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    exit 2
fi

destination=$2
mkdir -p "$destination"
printf 'pristine archive state\n' >"$destination/sentinel"
printf 'archive-snapshot-mocked\n'
