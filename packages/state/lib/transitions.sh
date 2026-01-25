#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/transitions.sh - Phase transition functions
#
# This module provides:
# - Transition validation
# - All phase transition functions
#
# External commands: date, jq (via helpers)

# Requires: sm_get_state_file from rules.sh
# Requires: sm_allowed_transitions, sm_is_terminal_phase from rules.sh
# Requires: sm_bulk_update_state from io.sh
# Requires: sm_emit_event from logging.sh
# Requires: sm_get_phase from schema.sh

# ============================================================================
# Phase Transition Guards
# ============================================================================

# sm_can_transition <op> <to_phase>
# Check if transition from current phase to target phase is valid
# Returns: 0 if allowed, 1 if not
sm_can_transition() {
  local op="$1"
  local to_phase="$2"
  local from_phase
  from_phase=$(sm_get_phase "${op}")

  if [[ -z "${from_phase}" ]]; then
    return 1
  fi

  local allowed
  allowed=$(sm_allowed_transitions "${from_phase}")

  # Check if to_phase is in allowed list
  [[ " ${allowed} " == *" ${to_phase} "* ]]
}

# ============================================================================
# Phase Transitions
# ============================================================================

# Generic transition helper (internal)
_sm_do_transition() {
  local op="$1"
  local to_phase="$2"
  local event="$3"
  local details="${4:-}"
  shift 4
  # Remaining args are additional field=value pairs

  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    echo "Error: No state file for operation '${op}'" >&2
    return 1
  fi

  local from_phase
  from_phase=$(sm_get_phase "${op}")

  # Build update command
  local args=("${op}" "phase" "\"${to_phase}\"")
  while [[ $# -gt 0 ]]; do
    args+=("$1" "$2")
    shift 2
  done

  sm_bulk_update_state "${args[@]}"
  sm_emit_event "${op}" "${event}" "${details:-${from_phase} -> ${to_phase}}"
}

# sm_transition_to_planned <op> <plan_file>
# Transition operation to planned phase
sm_transition_to_planned() {
  local op="$1"
  local plan_file="$2"

  if ! sm_can_transition "${op}" "planned"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'planned'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "planned" "plan:created" "${plan_file}" \
    "plan_file" "\"${plan_file}\""
}

# sm_transition_to_queued <op> [epic_id]
# Transition operation to queued phase
sm_transition_to_queued() {
  local op="$1"
  local epic_id="${2:-}"

  if ! sm_can_transition "${op}" "queued"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'queued'" >&2
    return 1
  fi

  if [[ -n "${epic_id}" ]]; then
    _sm_do_transition "${op}" "queued" "work:queued" "Issues created" \
      "epic_id" "\"${epic_id}\""
  else
    _sm_do_transition "${op}" "queued" "work:queued" "Ready for execution"
  fi
}

# sm_transition_to_blocked <op> <blocked_by> <resume_phase>
# Transition operation to blocked phase
sm_transition_to_blocked() {
  local op="$1"
  local blocked_by="$2"
  local resume_phase="$3"

  if ! sm_can_transition "${op}" "blocked"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'blocked'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "blocked" "blocked:waiting" "Waiting for ${blocked_by}" \
    "after" "\"${blocked_by}\"" \
    "blocked_phase" "\"${resume_phase}\""
}

# sm_transition_to_executing <op> <session>
# Transition operation to executing phase
sm_transition_to_executing() {
  local op="$1"
  local session="$2"

  if ! sm_can_transition "${op}" "executing"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'executing'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "executing" "agent:launched" "tmux session ${session}" \
    "tmux_session" "\"${session}\""
}

# sm_transition_to_completed <op>
# Transition operation to completed phase
sm_transition_to_completed() {
  local op="$1"

  if ! sm_can_transition "${op}" "completed"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'completed'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "completed" "work:completed" "" \
    "completed_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
}

# sm_transition_to_pending_merge <op>
# Transition operation to pending_merge phase
sm_transition_to_pending_merge() {
  local op="$1"

  if ! sm_can_transition "${op}" "pending_merge"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'pending_merge'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "pending_merge" "merge:queued" ""
}

# sm_transition_to_merged <op>
# Transition operation to merged phase
sm_transition_to_merged() {
  local op="$1"

  if ! sm_can_transition "${op}" "merged"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'merged'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "merged" "merge:completed" "" \
    "merged_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    "merge_status" "\"merged\""
}

# sm_transition_to_failed <op> <error>
# Transition operation to failed phase
sm_transition_to_failed() {
  local op="$1"
  local error="$2"

  if ! sm_can_transition "${op}" "failed"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'failed'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "failed" "error:failed" "${error}" \
    "error" "$(printf '%s' "${error}" | jq -Rs .)"
}

# sm_transition_to_conflict <op>
# Transition operation to conflict phase (merge conflict)
sm_transition_to_conflict() {
  local op="$1"

  if ! sm_can_transition "${op}" "conflict"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'conflict'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "conflict" "merge:conflict" "" \
    "merge_status" "\"conflict\""
}

# sm_transition_to_interrupted <op>
# Transition operation to interrupted phase
sm_transition_to_interrupted() {
  local op="$1"

  if ! sm_can_transition "${op}" "interrupted"; then
    local current
    current=$(sm_get_phase "${op}")
    echo "Error: Cannot transition from '${current}' to 'interrupted'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "interrupted" "work:interrupted" ""
}

# sm_transition_to_cancelled <op>
# Transition operation to cancelled state
# Cancelled is allowed from any non-terminal state
# Also clears any hold on the operation
sm_transition_to_cancelled() {
  local op="$1"

  local phase
  phase=$(sm_get_phase "${op}")
  if sm_is_terminal_phase "${phase}"; then
    echo "Error: Cannot cancel operation in terminal state '${phase}'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "cancelled" "operation:cancelled" "" \
    "cancelled_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    "held" "false" \
    "held_at" "null"
}
