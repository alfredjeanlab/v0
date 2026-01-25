# Package: status
# SPDX-License-Identifier: MIT
#
# Status display - queue display, worker status, timestamps, recent display.
# User-facing status and monitoring output.

PKG_NAME="status"
PKG_DEPS=(core state mergeq)
PKG_EXPORTS=(lib/status.sh)
PKG_TEST_ONLY=false
