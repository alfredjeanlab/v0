# Package: test-support
# SPDX-License-Identifier: MIT
#
# Test infrastructure - helpers, mocks, fixtures.
# Development-only package, not shipped in production.

PKG_NAME="test-support"
PKG_DEPS=()
PKG_EXPORTS=(lib/test_helper.bash)
PKG_TEST_ONLY=true
