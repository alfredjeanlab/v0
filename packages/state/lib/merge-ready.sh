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

# Define no-op v0_trace if not available (for unit tests that don't source full CLI)
if ! type -t v0_trace &>/dev/null; then
  v0_trace() { :; }
fi

# ============================================================================
# Merge Readiness Checks
# ============================================================================

# _sm_resolve_merge_branch <op> <worktree> <branch>
# Internal helper to resolve a branch for merge operations.
# If branch is not set in state.json, tries conventional branch names on remote.
# Sets _SM_RESOLVED_BRANCH to the resolved branch name or empty string.
# Returns 0 if branch found, 1 if not
_sm_resolve_merge_branch() {
  local op="$1"
  local worktree="$2"
  local branch="$3"
  local git_dir="${V0_WORKSPACE_DIR:-${V0_ROOT}}"  # Explicit git context

  _SM_RESOLVED_BRANCH=""

  v0_trace "mergeq:readiness" "Resolving branch for ${op}: worktree=${worktree:-<none>}, branch=${branch:-<none>}, git_dir=${git_dir}"

  # If we have a valid worktree, no need to resolve branch
  if [[ -n "${worktree}" ]] && [[ "${worktree}" != "null" ]] && [[ -d "${worktree}" ]]; then
    v0_trace "mergeq:readiness" "Using existing worktree: ${worktree}"
    _SM_RESOLVED_BRANCH="${branch}"
    return 0
  fi

  # No worktree - need a valid branch
  if [[ -z "${branch}" ]] || [[ "${branch}" = "null" ]]; then
    # Branch not in state - try conventional branch names on remote
    # This matches the fallback logic in mg_resolve_operation_to_worktree
    local remote="${V0_GIT_REMOTE:-origin}"
    v0_trace "mergeq:readiness" "No branch in state, trying conventional prefixes on ${remote}"
    for prefix in "feature" "fix" "chore" "bugfix" "hotfix"; do
      local candidate="${prefix}/${op}"
      # Use explicit -C flag for workspace context
      if git -C "${git_dir}" show-ref --verify --quiet "refs/remotes/${remote}/${candidate}" 2>/dev/null; then
        v0_trace "mergeq:readiness" "Found branch via prefix: ${candidate}"
        _SM_RESOLVED_BRANCH="${candidate}"
        return 0
      fi
    done
    # No conventional branch found
    v0_trace "mergeq:readiness" "No conventional branch found for ${op}"
    return 1
  fi

  # Have branch from state - verify it exists locally or on remote
  v0_trace "mergeq:readiness" "Verifying branch ${branch} exists in ${git_dir}"
  if git -C "${git_dir}" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    v0_trace "mergeq:readiness" "Branch ${branch} exists as local ref"
    _SM_RESOLVED_BRANCH="${branch}"
    return 0
  fi
  if git -C "${git_dir}" show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE:-origin}/${branch}" 2>/dev/null; then
    v0_trace "mergeq:readiness" "Branch ${branch} exists as remote ref"
    _SM_RESOLVED_BRANCH="${branch}"
    return 0
  fi

  # Branch in state but doesn't exist
  v0_trace "mergeq:readiness" "Branch ${branch} not found in local or remote refs"
  return 1
}

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

  # Guard 2: Must have worktree OR branch must exist
  local worktree branch
  worktree=$(sm_read_state "${op}" "worktree")
  branch=$(sm_read_state "${op}" "branch")

  if ! _sm_resolve_merge_branch "${op}" "${worktree}" "${branch}"; then
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
  # NOTE: wk done moved to sm_transition_to_merged() to avoid side effects during polling

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
# Format: ready | phase:<current> | worktree:missing | branch:missing | session:active | open_issues:<count>
sm_merge_ready_reason() {
  local op="$1"

  # Check phase
  local phase
  phase=$(sm_get_phase "${op}")
  if [[ "${phase}" != "completed" ]] && [[ "${phase}" != "pending_merge" ]]; then
    echo "phase:${phase}"
    return
  fi

  # Check worktree or branch
  local worktree branch
  worktree=$(sm_read_state "${op}" "worktree")
  branch=$(sm_read_state "${op}" "branch")

  if ! _sm_resolve_merge_branch "${op}" "${worktree}" "${branch}"; then
    # Determine specific reason
    if [[ -z "${branch}" ]] || [[ "${branch}" = "null" ]]; then
      echo "worktree:missing"
    else
      echo "branch:missing"
    fi
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
  # NOTE: wk done moved to sm_transition_to_merged() to avoid side effects during polling

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
