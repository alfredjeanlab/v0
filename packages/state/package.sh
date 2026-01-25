# Package: state
# SPDX-License-Identifier: MIT
#
# State machine for operations - rules, formats, I/O, schema, transitions.
# Manages operation state files and their lifecycle.

PKG_NAME="state"
PKG_DEPS=(core)
PKG_EXPORTS=(lib/state.sh)
PKG_TEST_ONLY=false
