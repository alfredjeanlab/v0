#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/merge.sh - Orchestrator for merge modules
#
# This file sources all merge modules in dependency order.
# It is the single entry point for consuming the merge functionality.

_MG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set up mergeq paths if not already set (needed for queue-based resolution)
# These must be set before sourcing mergeq library
if [[ -z "${MERGEQ_DIR:-}" ]]; then
    _MG_MAIN_REPO=$(v0_find_main_repo)
    export MERGEQ_DIR="${_MG_MAIN_REPO}/${V0_BUILD_DIR}/mergeq"
    export QUEUE_FILE="${MERGEQ_DIR}/queue.json"
    export QUEUE_LOCK="${MERGEQ_DIR}/.queue.lock"
fi

# Source mergeq for queue-based resolution (mq_entry_exists, etc.)
# shellcheck source=packages/mergeq/lib/queue.sh
source "${_MG_LIB_DIR}/../../mergeq/lib/queue.sh"

# Level 0 (depends on v0-common.sh)
source "${_MG_LIB_DIR}/resolve.sh"

# Level 1 (depends on resolve)
source "${_MG_LIB_DIR}/conflict.sh"
source "${_MG_LIB_DIR}/execution.sh"

# Level 2 (depends on execution)
source "${_MG_LIB_DIR}/state-update.sh"
