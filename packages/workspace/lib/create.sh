#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# workspace/create.sh - Workspace creation (worktree and clone modes)
#
# Depends on: paths.sh
# IMPURE: Uses git, file system operations

# Expected environment variables:
# V0_ROOT - Path to project root
# V0_WORKSPACE_MODE - 'worktree' or 'clone'
# V0_WORKSPACE_DIR - Path to workspace directory
# V0_DEVELOP_BRANCH - Main development branch name
# V0_GIT_REMOTE - Git remote name
# REPO_NAME - Name of the repository

# ws_check_branch_conflict
# Check if V0_DEVELOP_BRANCH is checked out in V0_ROOT (worktree mode only)
# Returns: 0 if no conflict, 1 if conflict exists
ws_check_branch_conflict() {
  local current_branch
  current_branch=$(git -C "${V0_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ "${current_branch}" == "${V0_DEVELOP_BRANCH}" ]]; then
    echo "Error: Cannot create worktree: ${V0_DEVELOP_BRANCH} is checked out in ${V0_ROOT}" >&2
    echo "Please checkout a different branch, or set V0_WORKSPACE_MODE=clone" >&2
    return 1
  fi
  return 0
}

# ws_create_worktree
# Create workspace via git worktree add
# Returns: 0 on success, 1 on failure
ws_create_worktree() {
  local workspace_parent
  workspace_parent=$(ws_get_workspace_parent)

  # Check for branch conflict
  if ! ws_check_branch_conflict; then
    return 1
  fi

  # Create parent directory
  mkdir -p "${workspace_parent}"

  # Create worktree for develop branch
  echo "Creating workspace worktree at ${V0_WORKSPACE_DIR}..."
  if ! git -C "${V0_ROOT}" worktree add "${V0_WORKSPACE_DIR}" "${V0_DEVELOP_BRANCH}" 2>&1; then
    # Try fetching the branch first if it doesn't exist locally
    git -C "${V0_ROOT}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
    if ! git -C "${V0_ROOT}" worktree add "${V0_WORKSPACE_DIR}" "${V0_DEVELOP_BRANCH}" 2>&1; then
      echo "Error: Failed to create worktree at ${V0_WORKSPACE_DIR}" >&2
      return 1
    fi
  fi

  echo "Workspace worktree created at ${V0_WORKSPACE_DIR}"
  return 0
}

# ws_create_clone
# Create workspace via git clone from V0_ROOT
# Returns: 0 on success, 1 on failure
ws_create_clone() {
  local workspace_parent
  workspace_parent=$(ws_get_workspace_parent)

  # Create parent directory
  mkdir -p "${workspace_parent}"

  # Clone from V0_ROOT (local clone is fast)
  echo "Creating workspace clone at ${V0_WORKSPACE_DIR}..."
  if ! git clone "${V0_ROOT}" "${V0_WORKSPACE_DIR}" 2>&1; then
    echo "Error: Failed to clone to ${V0_WORKSPACE_DIR}" >&2
    return 1
  fi

  # Configure the clone to push/pull from the same remote as V0_ROOT
  # Get the remote URL from V0_ROOT
  local remote_url
  remote_url=$(git -C "${V0_ROOT}" remote get-url "${V0_GIT_REMOTE}" 2>/dev/null || true)
  if [[ -n "${remote_url}" ]]; then
    # Add the remote (origin points to V0_ROOT by default after clone)
    git -C "${V0_WORKSPACE_DIR}" remote set-url origin "${remote_url}"
  fi

  # Checkout the develop branch
  if ! git -C "${V0_WORKSPACE_DIR}" checkout "${V0_DEVELOP_BRANCH}" 2>&1; then
    # Try fetching if it doesn't exist locally
    git -C "${V0_WORKSPACE_DIR}" fetch origin "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
    if ! git -C "${V0_WORKSPACE_DIR}" checkout "${V0_DEVELOP_BRANCH}" 2>&1; then
      # Create the branch from origin if it exists there
      if ! git -C "${V0_WORKSPACE_DIR}" checkout -b "${V0_DEVELOP_BRANCH}" "origin/${V0_DEVELOP_BRANCH}" 2>&1; then
        echo "Warning: Could not checkout ${V0_DEVELOP_BRANCH}, staying on current branch" >&2
      fi
    fi
  fi

  echo "Workspace clone created at ${V0_WORKSPACE_DIR}"
  return 0
}

# ws_ensure_workspace
# Idempotent function that creates workspace if missing
# Uses V0_WORKSPACE_MODE to determine creation method
# Returns: 0 on success, 1 on failure
ws_ensure_workspace() {
  # Check if workspace already exists and is valid
  if ws_is_valid_workspace; then
    return 0
  fi

  # Remove invalid workspace directory if it exists
  if [[ -d "${V0_WORKSPACE_DIR}" ]]; then
    echo "Note: Removing invalid workspace directory: ${V0_WORKSPACE_DIR}" >&2
    rm -rf "${V0_WORKSPACE_DIR}"
  fi

  # Create workspace based on mode
  case "${V0_WORKSPACE_MODE}" in
    worktree)
      ws_create_worktree
      ;;
    clone)
      ws_create_clone
      ;;
    *)
      echo "Error: Invalid V0_WORKSPACE_MODE: ${V0_WORKSPACE_MODE}" >&2
      echo "Valid values: 'worktree' or 'clone'" >&2
      return 1
      ;;
  esac
}

# ws_remove_workspace
# Remove the workspace directory
# Returns: 0 on success
ws_remove_workspace() {
  if [[ ! -d "${V0_WORKSPACE_DIR}" ]]; then
    return 0
  fi

  # For worktree mode, use git worktree remove
  if [[ "${V0_WORKSPACE_MODE}" == "worktree" ]]; then
    git -C "${V0_ROOT}" worktree remove "${V0_WORKSPACE_DIR}" --force 2>/dev/null || true
  fi

  # Clean up directory
  rm -rf "${V0_WORKSPACE_DIR}"
  return 0
}
