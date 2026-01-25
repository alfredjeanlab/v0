#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# update-common.sh - Shared utilities for v0 update operations

# Shared constants
V0_REPO="alfredjeanlab/v0"
GITHUB_API="https://api.github.com"
GITHUB_RELEASES="https://github.com/${V0_REPO}/releases"

# Get installation method (homebrew, direct, or unknown)
get_install_method() {
  local v0_path
  v0_path=$(command -v v0 2>/dev/null)

  if [[ "${v0_path}" == *"/Cellar/"* ]] || [[ "${v0_path}" == *"/homebrew/"* ]]; then
    echo "homebrew"
  elif [[ "${v0_path}" == *"/.local/"* ]]; then
    echo "direct"
  else
    echo "unknown"
  fi
}

# Get current installed version
get_current_version() {
  local version_file="${V0_DIR}/VERSION"
  if [[ -f "${version_file}" ]]; then
    cat "${version_file}"
  else
    echo "unknown"
  fi
}

# Get current channel (stable, nightly, or pinned:<version>)
get_current_channel() {
  local channel_file="${V0_DIR}/.channel"
  if [[ -f "${channel_file}" ]]; then
    cat "${channel_file}"
  else
    echo "stable"
  fi
}

# Set current channel
set_current_channel() {
  local channel="$1"
  echo "${channel}" > "${V0_DIR}/.channel"
}

# Query available versions from GitHub
list_available_versions() {
  curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases" 2>/dev/null |
    jq -r '.[].tag_name' | head -10
}

# Get latest stable version
get_latest_stable() {
  curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases/latest" 2>/dev/null |
    jq -r '.tag_name' | sed 's/^v//'
}

# Get latest nightly release info (returns tag_name)
get_latest_nightly() {
  curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases" 2>/dev/null |
    jq -r '[.[] | select(.tag_name | startswith("nightly-"))][0].tag_name // empty'
}

# Check if a version exists in releases
version_exists() {
  local version="$1"
  local tag_name="$2"

  local status
  status=$(curl -fsSL -o /dev/null -w '%{http_code}' \
    "${GITHUB_API}/repos/${V0_REPO}/releases/tags/${tag_name}" 2>/dev/null)

  [[ "${status}" == "200" ]]
}

# Detect OS and architecture for tarball naming
get_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac

  echo "${os}-${arch}"
}

# Verify checksum of a file
verify_checksum() {
  local file="$1"
  local checksum_file="$2"

  cd "$(dirname "${file}")" || return 1
  if command -v sha256sum &>/dev/null; then
    sha256sum -c "${checksum_file}" --quiet
  elif command -v shasum &>/dev/null; then
    shasum -a 256 -c "${checksum_file}" --quiet
  else
    echo "Warning: No sha256sum or shasum available, skipping checksum verification" >&2
    return 0
  fi
}
