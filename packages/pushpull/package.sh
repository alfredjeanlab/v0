# Package: pushpull
# SPDX-License-Identifier: MIT
#
# Bidirectional sync between user branches and agent branch.
# Provides v0 pull (merge agent -> user) and v0 push (reset agent to user).

PKG_NAME="pushpull"
PKG_DEPS=(core)
PKG_EXPORTS=(lib/pushpull.sh)
PKG_TEST_ONLY=false
