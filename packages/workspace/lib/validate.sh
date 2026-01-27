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

# ws_get_remote_url
# Get the URL for a remote in a git repository
# Args: remote_name, directory (defaults to V0_ROOT)
# Outputs: remote URL or empty if not found
ws_get_remote_url() {
  local remote="$1"
  local dir="${2:-${V0_ROOT}}"
  git -C "${dir}" remote get-url "${remote}" 2>/dev/null
}

# ws_remote_matches
# Check if workspace remote URL matches main repo's remote URL
# For clone mode: workspace's "origin" should match V0_ROOT's V0_GIT_REMOTE URL
# For worktree mode: always matches (shares .git directory)
# Returns: 0 if matches, 1 if mismatch
ws_remote_matches() {
  # Worktrees share the .git directory, so remotes are always in sync
  if ws_is_worktree; then
    return 0
  fi

  # For clones, check that workspace's origin matches main repo's configured remote
  local main_url workspace_url
  main_url=$(ws_get_remote_url "${V0_GIT_REMOTE}" "${V0_ROOT}")
  workspace_url=$(ws_get_remote_url "origin" "${V0_WORKSPACE_DIR}")

  if [[ -z "${main_url}" ]]; then
    # Main repo has no remote configured - can't validate
    return 0
  fi

  if [[ "${main_url}" != "${workspace_url}" ]]; then
    echo "Note: Workspace origin '${workspace_url}' differs from ${V0_GIT_REMOTE} '${main_url}'" >&2
    return 1
  fi

  return 0
}

# ws_matches_config
# Check if workspace matches current V0_WORKSPACE_MODE, V0_DEVELOP_BRANCH, and remote URL
# Returns: 0 if matches, 1 if mismatch (workspace should be recreated)
ws_matches_config() {
  # Check workspace type matches configured mode
  local is_worktree=0
  ws_is_worktree && is_worktree=1

  if [[ "${V0_WORKSPACE_MODE}" == "worktree" ]]; then
    if [[ "${is_worktree}" -ne 1 ]]; then
      echo "Note: Workspace is a clone but config expects worktree mode" >&2
      return 1
    fi
  else
    if [[ "${is_worktree}" -eq 1 ]]; then
      echo "Note: Workspace is a worktree but config expects clone mode" >&2
      return 1
    fi
  fi

  # Check workspace is on the correct branch
  if ! ws_is_on_develop; then
    local current_branch
    current_branch=$(ws_get_current_branch)
    echo "Note: Workspace is on '${current_branch}' but config expects '${V0_DEVELOP_BRANCH}'" >&2
    return 1
  fi

  # Check remote URL matches (clone mode only - worktrees share remotes)
  if ! ws_remote_matches; then
    return 1
  fi

  return 0
}

# ws_get_current_branch
# Get the current branch of the workspace
# Returns: branch name
ws_get_current_branch() {
  git -C "${V0_WORKSPACE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# ws_abort_incomplete_operations
# Abort any in-progress rebase or merge in the workspace
# Args: directory path (defaults to V0_WORKSPACE_DIR)
# Returns: 0 always (failures are silently ignored)
ws_abort_incomplete_operations() {
  local dir="${1:-${V0_WORKSPACE_DIR}}"
  local git_dir
  if git_dir=$(ws_get_git_dir "${dir}"); then
    if [[ -d "${git_dir}/rebase-merge" ]] || [[ -d "${git_dir}/rebase-apply" ]]; then
      git -C "${dir}" rebase --abort 2>/dev/null || true
    fi
    if [[ -f "${git_dir}/MERGE_HEAD" ]]; then
      git -C "${dir}" merge --abort 2>/dev/null || true
    fi
  fi
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
  ws_abort_incomplete_operations

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

# ws_check_health
# Comprehensive health check for workspace
# Validates workspace, checks config match, and cleans uncommitted changes
# Returns: 0 if healthy, 1 if not
ws_check_health() {
  # Basic validation
  if ! ws_validate; then
    return 1
  fi

  # Check config matches
  if ! ws_matches_config; then
    return 1
  fi

  # Clean uncommitted changes if present
  if ws_has_uncommitted_changes; then
    echo "Warning: workspace has uncommitted changes, cleaning" >&2
    ws_clean_workspace
  fi

  return 0
}
