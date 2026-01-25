#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/merge.sh - Orchestrator for merge modules
#
# This file sources all merge modules in dependency order.
# It is the single entry point for consuming the merge functionality.

_MG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Level 0 (depends on v0-common.sh)
source "${_MG_LIB_DIR}/resolve.sh"

# Level 1 (depends on resolve)
source "${_MG_LIB_DIR}/conflict.sh"
source "${_MG_LIB_DIR}/execution.sh"

# Level 2 (depends on execution)
source "${_MG_LIB_DIR}/state-update.sh"
