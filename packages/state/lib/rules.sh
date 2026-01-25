#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/rules.sh - Pure state machine rules (no subprocess calls)
#
# This module provides:
# - Schema version and log rotation constants
# - State file path construction
# - Transition rules
# - Terminal phase detection

# Requires: BUILD_DIR to be set (via v0_load_config)

# ============================================================================
# Schema Versioning
# ============================================================================
# Current schema version - increment when state.json format changes
SM_STATE_VERSION=1

# ============================================================================
# Log Rotation Settings
# ============================================================================
# Maximum log file size before rotation (100KB)
SM_LOG_MAX_SIZE=102400
# Number of rotated logs to keep
SM_LOG_KEEP_COUNT=3

# ============================================================================
# State Transition Table
# ============================================================================
# From State      -> Allowed Transitions
# -------------------------------------------
# init            -> planned, blocked, failed
# planned         -> queued, blocked, failed
# blocked         -> init, planned, queued (on unblock)
# queued          -> executing, blocked, failed
# executing       -> completed, failed, interrupted
# completed       -> pending_merge, merged, failed
# pending_merge   -> merged, conflict, failed
# merged          -> (terminal)
# failed          -> init, planned, queued (on resume)
# conflict        -> pending_merge (on retry), failed
# interrupted     -> init, planned, queued (on resume)
# cancelled       -> (terminal)

# ============================================================================
# State File Path
# ============================================================================

# sm_get_state_file <op>
# Get the path to state file for an operation
sm_get_state_file() {
  local op="$1"
  echo "${BUILD_DIR}/operations/${op}/state.json"
}

# sm_state_exists <op>
# Check if state file exists for an operation
sm_state_exists() {
  local op="$1"
  local state_file
  state_file=$(sm_get_state_file "${op}")
  [[ -f "${state_file}" ]]
}

# ============================================================================
# Transition Rules
# ============================================================================

# sm_allowed_transitions <phase>
# Return space-separated list of valid next phases for current phase
sm_allowed_transitions() {
  local phase="$1"

  case "${phase}" in
    init)          echo "planned blocked failed" ;;
    planned)       echo "queued blocked failed" ;;
    blocked)       echo "init planned queued" ;;
    queued)        echo "executing blocked failed" ;;
    executing)     echo "completed failed interrupted" ;;
    completed)     echo "pending_merge merged failed" ;;
    pending_merge) echo "merged conflict failed" ;;
    merged)        echo "" ;;  # terminal
    failed)        echo "init planned queued" ;;
    conflict)      echo "pending_merge failed" ;;
    interrupted)   echo "init planned queued" ;;
    cancelled)     echo "" ;;  # terminal
    *)             echo "" ;;
  esac
}

# sm_is_terminal_phase <phase>
# Check if phase is terminal (no further transitions allowed)
sm_is_terminal_phase() {
  local phase="$1"
  [[ "${phase}" = "merged" ]] || [[ "${phase}" = "cancelled" ]]
}
