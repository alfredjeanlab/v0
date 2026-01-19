#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# state-machine.sh - Centralized state machine functions for v0 operations
#
# This library provides:
# - State file operations (read, update, bulk update)
# - Phase transition guards and functions
# - Blocking/dependency helpers
# - Hold management
# - Status interpretation for display

# Requires: V0_ROOT, BUILD_DIR, V0_DIR to be set (via v0_load_config)

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
# State File Operations
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

# sm_read_state <op> <field>
# Read a field from state file
# Returns: field value, empty if not found
sm_read_state() {
  local op="$1"
  local field="$2"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  jq -r ".${field} // empty" "${state_file}"
}

# sm_update_state <op> <field> <value>
# Update a single field in state file
# Value should be a valid JSON value (quoted strings, numbers, etc.)
sm_update_state() {
  local op="$1"
  local field="$2"
  local value="$3"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  if jq ".${field} = ${value}" "${state_file}" > "${tmp}"; then
    mv "${tmp}" "${state_file}"
    return 0
  else
    rm -f "${tmp}"
    return 1
  fi
}

# sm_bulk_update_state <op> <field1> <value1> [<field2> <value2> ...]
# Update multiple fields atomically in state file
# Values should be valid JSON values
sm_bulk_update_state() {
  local op="$1"
  shift
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  local jq_filter="."

  while [[ $# -gt 0 ]]; do
    local field="$1"
    local value="$2"
    jq_filter="${jq_filter} | .${field} = ${value}"
    shift 2
  done

  if jq "${jq_filter}" "${state_file}" > "${tmp}"; then
    mv "${tmp}" "${state_file}"
    return 0
  else
    rm -f "${tmp}"
    return 1
  fi
}

# sm_get_phase <op>
# Get current phase of an operation
sm_get_phase() {
  local op="$1"
  sm_read_state "${op}" "phase"
}

# ============================================================================
# Event Logging
# ============================================================================

# sm_emit_event <op> <event> [details]
# Log an event for debugging and audit
sm_emit_event() {
  local op="$1"
  local event="$2"
  local details="${3:-}"
  local log_dir="${BUILD_DIR}/operations/${op}/logs"

  mkdir -p "${log_dir}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${event}: ${details}" >> "${log_dir}/events.log"
}

# ============================================================================
# Phase Transition Guards
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

# sm_is_terminal_phase <phase>
# Check if phase is terminal (no further transitions allowed)
sm_is_terminal_phase() {
  local phase="$1"
  [[ "${phase}" = "merged" ]] || [[ "${phase}" = "cancelled" ]]
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

# ============================================================================
# Resume/Recovery Functions
# ============================================================================

# sm_get_resume_phase <op>
# Determine what phase to resume from based on current state
# For failed/interrupted/cancelled operations, determines best resume point
sm_get_resume_phase() {
  local op="$1"
  local phase
  phase=$(sm_get_phase "${op}")

  case "${phase}" in
    failed|interrupted|cancelled)
      # Determine resume point based on state
      local epic_id plan_file
      epic_id=$(sm_read_state "${op}" "epic_id")
      plan_file=$(sm_read_state "${op}" "plan_file")

      if [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]]; then
        echo "queued"
      elif [[ -n "${plan_file}" ]] && [[ "${plan_file}" != "null" ]]; then
        echo "planned"
      else
        echo "init"
      fi
      ;;
    blocked)
      # Return blocked_phase or init
      local blocked_phase
      blocked_phase=$(sm_read_state "${op}" "blocked_phase")
      if [[ -n "${blocked_phase}" ]] && [[ "${blocked_phase}" != "null" ]]; then
        echo "${blocked_phase}"
      else
        echo "init"
      fi
      ;;
    *)
      echo "${phase}"
      ;;
  esac
}

# sm_clear_error_state <op>
# Clear error state and prepare for resume
sm_clear_error_state() {
  local op="$1"
  local resume_phase
  resume_phase=$(sm_get_resume_phase "${op}")

  sm_bulk_update_state "${op}" \
    "phase" "\"${resume_phase}\"" \
    "error" "null"

  sm_emit_event "${op}" "resume:from_error" "Resuming from ${resume_phase}"
}

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

# ============================================================================
# Merge Readiness Checks
# ============================================================================

# sm_is_merge_ready <op>
# Check if operation is ready for merge
sm_is_merge_ready() {
  local op="$1"

  # Guard 1: Must be in correct phase
  local phase
  phase=$(sm_get_phase "${op}")
  if [[ "${phase}" != "completed" ]] && [[ "${phase}" != "pending_merge" ]]; then
    return 1
  fi

  # Guard 2: Must have worktree
  local worktree
  worktree=$(sm_read_state "${op}" "worktree")
  if [[ -z "${worktree}" ]] || [[ "${worktree}" = "null" ]] || [[ ! -d "${worktree}" ]]; then
    return 1
  fi

  # Guard 3: tmux session must be gone
  local session
  session=$(sm_read_state "${op}" "tmux_session")
  if [[ -n "${session}" ]] && [[ "${session}" != "null" ]] && tmux has-session -t "${session}" 2>/dev/null; then
    return 1
  fi

  # Guard 4: All plan issues must be closed
  if ! sm_all_issues_closed "${op}"; then
    return 1
  fi

  return 0
}

# sm_all_issues_closed <op>
# Check if all issues for operation are closed
sm_all_issues_closed() {
  local op="$1"
  local open in_progress

  open=$(wk list --label "plan:${op}" --status todo 2>/dev/null | wc -l | tr -d ' ')
  in_progress=$(wk list --label "plan:${op}" --status in_progress 2>/dev/null | wc -l | tr -d ' ')

  [[ "${open}" -eq 0 ]] && [[ "${in_progress}" -eq 0 ]]
}

# sm_merge_ready_reason <op>
# Return human-readable reason why merge is/isn't ready
# Format: ready | phase:<current> | worktree:missing | session:active | open_issues:<count>
sm_merge_ready_reason() {
  local op="$1"

  # Check phase
  local phase
  phase=$(sm_get_phase "${op}")
  if [[ "${phase}" != "completed" ]] && [[ "${phase}" != "pending_merge" ]]; then
    echo "phase:${phase}"
    return
  fi

  # Check worktree
  local worktree
  worktree=$(sm_read_state "${op}" "worktree")
  if [[ -z "${worktree}" ]] || [[ "${worktree}" = "null" ]] || [[ ! -d "${worktree}" ]]; then
    echo "worktree:missing"
    return
  fi

  # Check tmux session
  local session
  session=$(sm_read_state "${op}" "tmux_session")
  if [[ -n "${session}" ]] && [[ "${session}" != "null" ]] && tmux has-session -t "${session}" 2>/dev/null; then
    echo "session:active"
    return
  fi

  # Check issues
  local open in_progress
  open=$(wk list --label "plan:${op}" --status todo 2>/dev/null | wc -l | tr -d ' ')
  in_progress=$(wk list --label "plan:${op}" --status in_progress 2>/dev/null | wc -l | tr -d ' ')
  local total=$((open + in_progress))

  if [[ "${total}" -gt 0 ]]; then
    echo "open_issues:${total}"
    return
  fi

  echo "ready"
}

# sm_should_auto_merge <op>
# Check if operation should be auto-merged when complete
sm_should_auto_merge() {
  local op="$1"
  local merge_queued
  merge_queued=$(sm_read_state "${op}" "merge_queued")
  [[ "${merge_queued}" = "true" ]]
}

# ============================================================================
# Status Display Helpers
# ============================================================================

# sm_get_display_status <op>
# Return user-friendly status string for an operation
# Format: <status>|<color>|<icon>
sm_get_display_status() {
  local op="$1"
  local phase merge_status held

  phase=$(sm_get_phase "${op}")
  merge_status=$(sm_read_state "${op}" "merge_status")
  held=$(sm_read_state "${op}" "held")

  # Check for hold first
  if [[ "${held}" = "true" ]]; then
    echo "held|yellow|[hold]"
    return
  fi

  case "${phase}" in
    init)
      # Check if planning is active
      local session
      session=$(sm_read_state "${op}" "tmux_session")
      if [[ -n "${session}" ]] && [[ "${session}" != "null" ]] && tmux has-session -t "${session}" 2>/dev/null; then
        echo "new|yellow|[planning]"
      else
        echo "new||"
      fi
      ;;
    planned)
      echo "planned|cyan|"
      ;;
    blocked)
      local after
      after=$(sm_get_blocker "${op}")
      echo "blocked|yellow|[waiting: ${after}]"
      ;;
    queued)
      echo "queued|cyan|"
      ;;
    executing)
      local session
      session=$(sm_read_state "${op}" "tmux_session")
      if [[ -n "${session}" ]] && [[ "${session}" != "null" ]] && tmux has-session -t "${session}" 2>/dev/null; then
        echo "assigned|cyan|[building]"
      else
        echo "assigned|cyan|"
      fi
      ;;
    completed)
      local merge_display
      merge_display=$(sm_get_merge_display_status "${op}")
      echo "completed|green|${merge_display}"
      ;;
    pending_merge)
      local merge_display
      merge_display=$(sm_get_merge_display_status "${op}")
      echo "pending_merge|yellow|${merge_display}"
      ;;
    merged)
      echo "merged|green|(merged)"
      ;;
    conflict)
      echo "conflict|red|== CONFLICT =="
      ;;
    failed)
      echo "failed|red|[error]"
      ;;
    interrupted)
      echo "interrupted|yellow|[interrupted]"
      ;;
    cancelled)
      echo "cancelled|dim|"
      ;;
    *)
      echo "${phase}||"
      ;;
  esac
}

# sm_get_merge_display_status <op>
# Return merge-specific display status
sm_get_merge_display_status() {
  local op="$1"
  local merge_status phase

  phase=$(sm_get_phase "${op}")
  merge_status=$(sm_read_state "${op}" "merge_status")

  # Check if already merged
  if [[ "${phase}" = "merged" ]] || [[ "${merge_status}" = "merged" ]]; then
    echo "(merged)"
    return
  fi

  # Check for conflict
  if [[ "${merge_status}" = "conflict" ]] || [[ "${phase}" = "conflict" ]]; then
    echo "(== CONFLICT ==)"
    return
  fi

  # Check merge queue status
  local queue_file="${BUILD_DIR}/mergeq/queue.json"
  if [[ -f "${queue_file}" ]]; then
    local queue_status
    queue_status=$(jq -r --arg op "${op}" '.entries[] | select(.operation == $op) | .status' "${queue_file}" 2>/dev/null)

    case "${queue_status}" in
      processing)
        echo "(merging...)"
        ;;
      pending)
        echo "(in queue)"
        ;;
      *)
        if [[ "${phase}" = "pending_merge" ]]; then
          echo "(pending merge)"
        fi
        ;;
    esac
  elif [[ "${phase}" = "pending_merge" ]]; then
    echo "(pending merge)"
  fi
}

# sm_get_status_color <status>
# Return ANSI color code for a status
# Colors: green, yellow, red, cyan, dim
sm_get_status_color() {
  local status="$1"

  case "${status}" in
    green)  printf '\033[32m' ;;
    yellow) printf '\033[33m' ;;
    red)    printf '\033[31m' ;;
    cyan)   printf '\033[36m' ;;
    dim)    printf '\033[2m' ;;
    *)      printf '' ;;
  esac
}

# sm_is_active_operation <op>
# Check if operation is active (not in terminal state)
sm_is_active_operation() {
  local op="$1"
  local phase
  phase=$(sm_get_phase "${op}")

  # Active: anything not in terminal state
  [[ "${phase}" != "merged" ]] && [[ "${phase}" != "cancelled" ]]
}
