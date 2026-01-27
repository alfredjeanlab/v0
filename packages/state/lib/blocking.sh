#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/blocking.sh - Dependency management via wok
#
# This module provides blocking checks that query wok
# instead of using local state.json fields.
#
# External commands: wk, jq
#
# Requires: BUILD_DIR to be set (via v0_load_config)
# Requires: sm_read_state from io.sh
# Requires: sm_emit_event from logging.sh
# Requires: v0_get_blockers, v0_get_first_open_blocker, v0_is_blocked,
#           v0_blocker_to_op_name from v0-common.sh

# ============================================================================
# Blocking/Dependency Helpers
# ============================================================================

# sm_is_blocked <op>
# Check if operation is blocked by any open dependencies in wok
sm_is_blocked() {
  local op="$1"
  local epic_id
  epic_id=$(sm_read_state "${op}" "epic_id")

  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return 1

  v0_is_blocked "${epic_id}"
}

# sm_get_blocker <op>
# Get the first open blocker operation/issue for display
# Returns operation name if resolvable, otherwise issue ID
sm_get_blocker() {
  local op="$1"
  local epic_id
  epic_id=$(sm_read_state "${op}" "epic_id")

  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return

  local blocker_id
  blocker_id=$(v0_get_first_open_blocker "${epic_id}")
  [[ -z "${blocker_id}" ]] && return

  # Try to resolve to operation name
  v0_blocker_to_op_name "${blocker_id}"
}

# sm_get_blocker_status <blocker>
# Get phase/status of the blocking operation or issue
sm_get_blocker_status() {
  local blocker="$1"

  # Try as operation name first
  local state_file="${BUILD_DIR}/operations/${blocker}/state.json"
  if [[ -f "${state_file}" ]]; then
    jq -r '.phase // "unknown"' "${state_file}"
    return
  fi

  # Try as wok issue ID
  # Run wk from V0_ROOT since wok may not be initialized in the current directory
  local wk_dir="${V0_ROOT:-$(pwd)}"
  local status
  status=$(cd "${wk_dir}" && wk show "${blocker}" -o json 2>/dev/null | jq -r '.status // "unknown"')
  echo "${status}"
}

# sm_is_blocker_merged <op>
# Check if all blockers have completed (done/closed in wok)
sm_is_blocker_merged() {
  local op="$1"
  local epic_id
  epic_id=$(sm_read_state "${op}" "epic_id")

  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return 0

  # If no open blockers, then all are "merged"
  ! v0_is_blocked "${epic_id}"
}

# sm_find_dependents <op>
# Find operations waiting for the given operation
# Uses wok's blocking relationship queries
sm_find_dependents() {
  local merged_op="$1"
  local merged_epic_id
  merged_epic_id=$(sm_read_state "${merged_op}" "epic_id")

  [[ -z "${merged_epic_id}" ]] || [[ "${merged_epic_id}" == "null" ]] && return

  # Run wk from V0_ROOT since wok may not be initialized in the current directory
  # (e.g., when running from a workspace worktree during merge)
  local wk_dir="${V0_ROOT:-$(pwd)}"

  # Get issues that this one blocks
  local blocking_ids
  blocking_ids=$(cd "${wk_dir}" && wk show "${merged_epic_id}" -o json 2>/dev/null | jq -r '.blocking // [] | .[]')

  # Resolve each to operation name if possible
  local blocked_id
  for blocked_id in ${blocking_ids}; do
    local op_name
    op_name=$(cd "${wk_dir}" && v0_blocker_to_op_name "${blocked_id}")
    # Only return if it's a known operation
    if [[ -f "${BUILD_DIR}/operations/${op_name}/state.json" ]]; then
      echo "${op_name}"
    fi
  done
}

# sm_trigger_dependents <op>
# Notify dependent operations that blocker has merged
# Note: The actual unblocking happens when sm_transition_to_merged marks
# the wok epic as done. This function just logs for visibility.
sm_trigger_dependents() {
  local merged_op="$1"

  # Dependents are unblocked when the blocker's wok epic is marked done
  # (handled by _sm_close_wok_epic in sm_transition_to_merged).
  # This function logs the event for visibility.
  local dep_op
  for dep_op in $(sm_find_dependents "${merged_op}"); do
    sm_emit_event "${dep_op}" "unblock:notified" "Blocker ${merged_op} completed"
  done
}

# REMOVED: sm_unblock_operation - no longer needed, wok tracks automatically
