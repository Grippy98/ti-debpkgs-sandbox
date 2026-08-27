#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq -o Dpkg::Use-Pty=0 install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    debhelper \
    devscripts \
    dpkg-dev \
    fakeroot \
    git \
    gnupg \
    jq \
    python3 \
    reprepro \
    shellcheck

shellcheck scripts/*.sh tests/*.sh tests/mocks/*
python3 -m compileall -q scripts
./tests/state-boundary.sh
./tests/provenance-boundary.sh
./tests/integration.sh
