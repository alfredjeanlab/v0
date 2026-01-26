# Package: cli
# SPDX-License-Identifier: MIT
#
# CLI integration - entry point that sources all packages.
# Main v0-common.sh and supporting utilities for bin/ commands.

PKG_NAME="cli"
PKG_DEPS=(core state mergeq merge worker hooks status)
PKG_EXPORTS=(lib/v0-common.sh)
PKG_TEST_ONLY=false
