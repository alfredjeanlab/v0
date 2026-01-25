#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/holds.sh - Hold management
#
# This module provides:
# - Hold state checks
# - Set/clear holds
# - Combined transition+hold operations
#
# External commands: date (via helpers)

# Requires: sm_read_state, sm_bulk_update_state from io.sh
# Requires: sm_emit_event from logging.sh
# Requires: sm_ensure_current_schema from schema.sh

# ============================================================================
# Hold Helpers
# ============================================================================

# sm_is_held <op>
# Check if operation is held
sm_is_held() {
  local op="$1"
  local held
  held=$(sm_read_state "${op}" "held")
  [[ "${held}" = "true" ]]
}

# sm_set_hold <op>
# Put operation on hold
sm_set_hold() {
  local op="$1"

  sm_bulk_update_state "${op}" \
    "held" "true" \
    "held_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

  sm_emit_event "${op}" "hold:set" "Operation put on hold"
}

# sm_clear_hold <op>
# Release hold on operation
sm_clear_hold() {
  local op="$1"

  sm_bulk_update_state "${op}" \
    "held" "false" \
    "held_at" "null"

  sm_emit_event "${op}" "hold:cleared" "Hold released"
}

# sm_exit_if_held <op> <command>
# Print hold notice and exit if operation is held
sm_exit_if_held() {
  local op="$1"
  local command="$2"

  if sm_is_held "${op}"; then
    echo "Operation '${op}' is on hold."
    echo ""
    echo "The operation will not proceed until the hold is released."
    echo ""
    echo "Release hold with:"
    echo "  v0 resume ${op}"
    echo ""
    echo "Or cancel the operation:"
    echo "  v0 cancel ${op}"
    exit 0
  fi
}

# sm_transition_to_planned_and_hold <op> <plan_file>
# Transition to planned phase and set hold in one atomic update
sm_transition_to_planned_and_hold() {
  local op="$1"
  local plan_file="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  sm_ensure_current_schema "${op}"

  sm_bulk_update_state "${op}" \
    "phase" "\"planned\"" \
    "plan_file" "\"${plan_file}\"" \
    "held" "true" \
    "held_at" "\"${now}\""

  sm_emit_event "${op}" "plan:created" "${plan_file}"
  sm_emit_event "${op}" "hold:auto_set" "Automatically held after planning"
}

