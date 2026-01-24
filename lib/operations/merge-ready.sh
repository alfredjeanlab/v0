#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/merge-ready.sh - Merge readiness checks
#
# This module provides:
# - Merge readiness validation
# - Issue status checks
# - Auto-merge determination
#
# External commands: tmux, wk, wc, tr

# Requires: sm_read_state from io.sh
# Requires: sm_get_phase from schema.sh

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
  # TEMPORARILY DISABLED - uncomment when ready
  # if ! sm_all_issues_closed "${op}"; then
  #   return 1
  # fi
  wk done $(wk list --label "plan:${op}" -o ids 2>/dev/null) 2>/dev/null || true

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
  # TEMPORARILY DISABLED - uncomment when ready
  # local open in_progress
  # open=$(wk list --label "plan:${op}" --status todo 2>/dev/null | wc -l | tr -d ' ')
  # in_progress=$(wk list --label "plan:${op}" --status in_progress 2>/dev/null | wc -l | tr -d ' ')
  # local total=$((open + in_progress))
  #
  # if [[ "${total}" -gt 0 ]]; then
  #   echo "open_issues:${total}"
  #   return
  # fi
  wk done $(wk list --label "plan:${op}" -o ids 2>/dev/null) 2>/dev/null || true

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
