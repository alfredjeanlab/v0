#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/queue.sh - Orchestrator for merge queue modules
#
# This file sources all merge queue modules in dependency order.
# It is the single entry point for consuming the merge queue functionality.

_MQ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Level 0 (no dependencies)
source "${_MQ_LIB_DIR}/rules.sh"

# Level 1 (depends on rules)
source "${_MQ_LIB_DIR}/io.sh"
source "${_MQ_LIB_DIR}/locking.sh"

# Level 2 (depends on io, locking)
source "${_MQ_LIB_DIR}/daemon.sh"
source "${_MQ_LIB_DIR}/display.sh"
source "${_MQ_LIB_DIR}/history.sh"

# Level 3 (depends on daemon, display)
source "${_MQ_LIB_DIR}/readiness.sh"
source "${_MQ_LIB_DIR}/resolution.sh"

# Level 4 (depends on readiness, resolution)
source "${_MQ_LIB_DIR}/processing.sh"
