# Package: worker
# SPDX-License-Identifier: MIT
#
# Worker infrastructure - common functions, nudge, coffee, error handling.
# Shared utilities for worker processes (feature, fix, chore workers).

PKG_NAME="worker"
PKG_DEPS=(core)
PKG_EXPORTS=(lib/worker.sh)
PKG_TEST_ONLY=false
