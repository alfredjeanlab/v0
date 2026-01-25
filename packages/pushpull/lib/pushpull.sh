#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# pushpull.sh - Entry point for pushpull package
#
# Provides bidirectional sync between user branches and the agent branch:
# - pull: merge agent changes into user branch
# - push: reset agent branch to user branch state

# Find package directory
_PUSHPULL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source modules
# shellcheck source=packages/pushpull/lib/pull.sh
source "${_PUSHPULL_DIR}/lib/pull.sh"
# shellcheck source=packages/pushpull/lib/push.sh
source "${_PUSHPULL_DIR}/lib/push.sh"
