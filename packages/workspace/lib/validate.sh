#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# workspace/validate.sh - Validation and health checks
#
# Depends on: paths.sh
# IMPURE: Uses git operations

# Expected environment variables:
# V0_WORKSPACE_DIR - Path to workspace directory
# V0_DEVELOP_BRANCH - Main development branch name
# V0_GIT_REMOTE - Git remote name

# ws_validate
# Check workspace exists and is healthy
# Returns: 0 if valid, 1 if not
ws_validate() {
  if ! ws_workspace_exists; then
    echo "Error: Workspace does not exist at ${V0_WORKSPACE_DIR}" >&2
    return 1
  fi

  if ! ws_is_valid_workspace; then
    echo "Error: Workspace is not a valid git directory: ${V0_WORKSPACE_DIR}" >&2
    return 1
  fi

  # Check if it's a functional git repo
  if ! git -C "${V0_WORKSPACE_DIR}" rev-parse --git-dir &>/dev/null; then
    echo "Error: Workspace is not a functional git repository: ${V0_WORKSPACE_DIR}" >&2
    return 1
  fi

  return 0
}

# ws_is_on_develop
# Verify workspace is on V0_DEVELOP_BRANCH
# Returns: 0 if on develop branch, 1 if not
ws_is_on_develop() {
  local current_branch
  current_branch=$(git -C "${V0_WORKSPACE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [[ "${current_branch}" == "${V0_DEVELOP_BRANCH}" ]]
}

# ws_get_current_branch
# Get the current branch of the workspace
# Returns: branch name
ws_get_current_branch() {
  git -C "${V0_WORKSPACE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# ws_sync_to_develop
# Reset workspace to V0_DEVELOP_BRANCH (fetch + checkout + reset)
# This ensures the workspace is clean and up to date with remote
# Returns: 0 on success, 1 on failure
ws_sync_to_develop() {
  if ! ws_validate; then
    return 1
  fi

  # Fetch latest from remote
  git -C "${V0_WORKSPACE_DIR}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true

  # Abort any in-progress rebase or merge
  if [[ -d "${V0_WORKSPACE_DIR}/.git/rebase-merge" ]] || [[ -d "${V0_WORKSPACE_DIR}/.git/rebase-apply" ]]; then
    git -C "${V0_WORKSPACE_DIR}" rebase --abort 2>/dev/null || true
  fi
  if [[ -f "${V0_WORKSPACE_DIR}/.git/MERGE_HEAD" ]]; then
    git -C "${V0_WORKSPACE_DIR}" merge --abort 2>/dev/null || true
  fi

  # Checkout develop branch
  if ! ws_is_on_develop; then
    if ! git -C "${V0_WORKSPACE_DIR}" checkout "${V0_DEVELOP_BRANCH}" 2>&1; then
      echo "Error: Failed to checkout ${V0_DEVELOP_BRANCH} in workspace" >&2
      return 1
    fi
  fi

  # Pull latest changes (fast-forward only for safety)
  git -C "${V0_WORKSPACE_DIR}" pull --ff-only "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true

  return 0
}

# ws_has_uncommitted_changes
# Check if workspace has uncommitted changes
# Returns: 0 if has uncommitted changes, 1 if clean
ws_has_uncommitted_changes() {
  # Check for staged or modified files (ignore untracked)
  [[ -n "$(git -C "${V0_WORKSPACE_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ]]
}

# ws_has_conflicts
# Check if workspace has merge conflicts
# Returns: 0 if has conflicts, 1 if no conflicts
ws_has_conflicts() {
  git -C "${V0_WORKSPACE_DIR}" status --porcelain 2>/dev/null | grep -q '^UU\|^AA\|^DD'
}

# ws_clean_workspace
# Clean workspace of uncommitted changes (hard reset)
# Returns: 0 on success
ws_clean_workspace() {
  git -C "${V0_WORKSPACE_DIR}" reset --hard HEAD 2>/dev/null || true
  git -C "${V0_WORKSPACE_DIR}" clean -fd 2>/dev/null || true
  return 0
}
