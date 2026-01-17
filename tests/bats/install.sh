#!/usr/bin/env bash
# tests/bats/install.sh - Download BATS testing libraries

set -euo pipefail

BATS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Versions to install
BATS_CORE_VERSION="v1.13.0"
BATS_SUPPORT_VERSION="v0.3.0"
BATS_ASSERT_VERSION="v2.1.0"

download_and_extract() {
    local repo="$1"
    local version="$2"
    local target="$3"
    local url="https://github.com/bats-core/${repo}/archive/refs/tags/${version}.tar.gz"

    if [[ -d "${BATS_DIR}/${target}" ]]; then
        echo "  ${target} already installed"
        return 0
    fi

    echo "  Downloading ${repo} ${version}..."

    local tmp_file
    tmp_file="$(mktemp)"

    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$tmp_file"
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$tmp_file"
    else
        echo "Error: Neither curl nor wget available" >&2
        return 1
    fi

    # Extract to target directory
    mkdir -p "${BATS_DIR}/${target}"
    tar -xzf "$tmp_file" --strip-components=1 -C "${BATS_DIR}/${target}"
    rm -f "$tmp_file"

    echo "  ${target} installed successfully"
}

main() {
    echo "Installing BATS testing libraries..."

    download_and_extract "bats-core" "$BATS_CORE_VERSION" "bats-core"
    download_and_extract "bats-support" "$BATS_SUPPORT_VERSION" "bats-support"
    download_and_extract "bats-assert" "$BATS_ASSERT_VERSION" "bats-assert"

    echo "BATS installation complete."
}

main "$@"
