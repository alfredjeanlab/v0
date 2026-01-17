#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# install.sh - Install v0 from GitHub Releases
#
# Usage:
#   curl -fsSL https://github.com/alfredjeanlab/v0/releases/latest/download/install.sh | bash
#
# Environment variables:
#   V0_VERSION - Version to install (default: latest)
#   V0_INSTALL - Installation directory (default: ~/.local/share/v0)

set -e

V0_VERSION="${V0_VERSION:-latest}"
V0_INSTALL="${V0_INSTALL:-$HOME/.local/share/v0}"
V0_REPO="alfredjeanlab/v0"
GITHUB_API="https://api.github.com"
GITHUB_RELEASES="https://github.com/${V0_REPO}/releases"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}Warning:${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

# Check for required commands
for cmd in curl tar; do
  if ! command -v "$cmd" &> /dev/null; then
    error "$cmd is required but not installed"
  fi
done

# Resolve "latest" to actual version
if [ "$V0_VERSION" = "latest" ]; then
  info "Fetching latest version..."
  V0_VERSION=$(curl -fsSL "${GITHUB_API}/repos/${V0_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
  if [ -z "$V0_VERSION" ]; then
    error "Could not determine latest version. Check your internet connection."
  fi
fi

info "Installing v0 v${V0_VERSION}..."

# Create temp directory
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Download tarball and checksum
TARBALL="v0-${V0_VERSION}.tar.gz"
CHECKSUM="${TARBALL}.sha256"
DOWNLOAD_URL="${GITHUB_RELEASES}/download/v${V0_VERSION}"

info "Downloading ${TARBALL}..."
if ! curl -fsSL "${DOWNLOAD_URL}/${TARBALL}" -o "${TMPDIR}/${TARBALL}"; then
  error "Failed to download ${TARBALL}. Version v${V0_VERSION} may not exist."
fi

info "Downloading checksum..."
if ! curl -fsSL "${DOWNLOAD_URL}/${CHECKSUM}" -o "${TMPDIR}/${CHECKSUM}"; then
  error "Failed to download checksum file"
fi

# Verify checksum
info "Verifying checksum..."
cd "$TMPDIR"
if command -v sha256sum &> /dev/null; then
  sha256sum -c "${CHECKSUM}" --quiet || error "Checksum verification failed!"
elif command -v shasum &> /dev/null; then
  shasum -a 256 -c "${CHECKSUM}" --quiet || error "Checksum verification failed!"
else
  warn "No sha256sum or shasum available, skipping checksum verification"
fi

# Remove existing installation
if [ -d "$V0_INSTALL" ]; then
  info "Removing existing installation at $V0_INSTALL"
  rm -rf "$V0_INSTALL"
fi

# Extract tarball
info "Extracting to ${V0_INSTALL}..."
mkdir -p "$V0_INSTALL"
tar -xzf "${TARBALL}" -C "$V0_INSTALL"

# Create bin directory and symlink
mkdir -p ~/.local/bin
ln -sf "$V0_INSTALL/bin/v0" ~/.local/bin/v0

echo ""
info "v0 v${V0_VERSION} installed successfully!"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo ""
  warn "~/.local/bin is not in your PATH"
  echo "Add this to your shell profile:"
  echo ""
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "To get started in a project:"
echo "  cd /path/to/your/project"
echo "  v0 init"
