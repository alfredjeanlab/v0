# Package: mergeq
# SPDX-License-Identifier: MIT
#
# Merge queue daemon and management - rules, I/O, locking, processing.
# Handles the automatic merge queue for integrating completed work.

PKG_NAME="mergeq"
PKG_DEPS=(core)
PKG_EXPORTS=(lib/mergeq.sh)
PKG_TEST_ONLY=false
