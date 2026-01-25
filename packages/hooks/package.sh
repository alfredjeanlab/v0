# Package: hooks
# SPDX-License-Identifier: MIT
#
# Lifecycle hooks - notify-progress, stop handlers for different worker types.
# Claude Code hooks for worker lifecycle management.

PKG_NAME="hooks"
PKG_DEPS=(core state)
PKG_EXPORTS=(lib/hooks.sh)
PKG_TEST_ONLY=false
