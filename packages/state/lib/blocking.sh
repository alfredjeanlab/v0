#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/blocking.sh - Dependency management
#
# This module provides:
# - Blocked state checks
# - Blocker status queries
# - Unblock operations
# - Dependent triggering
#
# External commands: jq, spawns v0-feature

# Requires: BUILD_DIR, V0_DIR to be set (via v0_load_config)
# Requires: sm_read_state, sm_bulk_update_state from io.sh
# Requires: sm_emit_event from logging.sh
# Requires: sm_get_phase from schema.sh
# Requires: sm_is_held from holds.sh

# ============================================================================
# Blocking/Dependency Helpers
# ============================================================================

# sm_is_blocked <op>
# Check if operation is blocked by --after dependency
sm_is_blocked() {
  local op="$1"
  local phase after
  phase=$(sm_get_phase "${op}")
  after=$(sm_read_state "${op}" "after")

  [[ "${phase}" = "blocked" ]] || { [[ -n "${after}" ]] && [[ "${after}" != "null" ]]; }
}

# sm_get_blocker <op>
# Get the operation blocking this one
sm_get_blocker() {
  local op="$1"
  sm_read_state "${op}" "after"
}

# sm_get_blocker_status <blocker_op>
# Get phase of the blocking operation
sm_get_blocker_status() {
  local blocker_op="$1"
  local state_file="${BUILD_DIR}/operations/${blocker_op}/state.json"

  if [[ ! -f "${state_file}" ]]; then
    echo "unknown"
    return 1
  fi

  jq -r '.phase // "unknown"' "${state_file}"
}

# sm_is_blocker_merged <op>
# Check if the blocking operation has merged
sm_is_blocker_merged() {
  local op="$1"
  local blocker
  blocker=$(sm_get_blocker "${op}")

  if [[ -z "${blocker}" ]] || [[ "${blocker}" = "null" ]]; then
    return 0  # No blocker, not blocked
  fi

  local blocker_phase
  blocker_phase=$(sm_get_blocker_status "${blocker}")
  [[ "${blocker_phase}" = "merged" ]]
}

# sm_unblock_operation <op>
# Clear blocked state and restore phase
sm_unblock_operation() {
  local op="$1"
  local resume_phase
  resume_phase=$(sm_read_state "${op}" "blocked_phase")

  if [[ -z "${resume_phase}" ]] || [[ "${resume_phase}" = "null" ]]; then
    resume_phase="init"
  fi

  sm_bulk_update_state "${op}" \
    "phase" "\"${resume_phase}\"" \
    "after" "null" \
    "blocked_phase" "null"

  sm_emit_event "${op}" "unblock:resumed" "Resumed from ${resume_phase}"
}

# sm_find_dependents <op>
# Find operations waiting for the given operation
# Returns operation names, one per line
sm_find_dependents() {
  local merged_op="$1"

  [[ ! -d "${BUILD_DIR}/operations" ]] && return

  for state_file in "${BUILD_DIR}"/operations/*/state.json; do
    [[ -f "${state_file}" ]] || continue

    local after
    after=$(jq -r '.after // empty' "${state_file}")
    if [[ "${after}" = "${merged_op}" ]]; then
      jq -r '.name' "${state_file}"
    fi
  done
}

# sm_trigger_dependents <op>
# Unblock and resume dependent operations
sm_trigger_dependents() {
  local merged_op="$1"
  local dep_op

  for dep_op in $(sm_find_dependents "${merged_op}"); do
    if sm_is_held "${dep_op}"; then
      sm_emit_event "${dep_op}" "unblock:held" "Dependency ${merged_op} merged but operation held"
      echo "Dependent '${dep_op}' remains held"
    else
      sm_unblock_operation "${dep_op}"
      # Resume in background
      "${V0_DIR}/bin/v0-feature" "${dep_op}" --resume &
    fi
  done
}
