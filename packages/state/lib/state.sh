#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/state.sh - Orchestrator for state machine modules
#
# This file sources all state machine modules in dependency order.
# It is the single entry point for consuming the state machine functionality.

_OP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Level 0 (no dependencies)
source "${_OP_LIB_DIR}/rules.sh"
source "${_OP_LIB_DIR}/format.sh"

# Level 1 (depends on rules)
source "${_OP_LIB_DIR}/io.sh"
source "${_OP_LIB_DIR}/logging.sh"

# Level 2 (depends on io, logging)
source "${_OP_LIB_DIR}/schema.sh"

# Level 3 (depends on schema, io, logging)
source "${_OP_LIB_DIR}/transitions.sh"
source "${_OP_LIB_DIR}/recovery.sh"

# Level 4 (depends on transitions, io)
# Note: holds.sh must come before blocking.sh because blocking.sh uses sm_is_held
source "${_OP_LIB_DIR}/holds.sh"
source "${_OP_LIB_DIR}/blocking.sh"
source "${_OP_LIB_DIR}/merge-ready.sh"
source "${_OP_LIB_DIR}/display.sh"
