# Package: merge
# SPDX-License-Identifier: MIT
#
# Merge operations - conflict resolution, execution, state updates.
# Performs the actual merge work for the merge queue.

PKG_NAME="merge"
PKG_DEPS=(core state mergeq)
PKG_EXPORTS=(lib/merge.sh)
PKG_TEST_ONLY=false
