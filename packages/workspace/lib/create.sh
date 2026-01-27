#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# workspace/create.sh - Workspace creation (worktree and clone modes)
#
# Depends on: paths.sh, validate.sh
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

  # Initialize wok workspace link if wok exists in main repo
  ws_init_wok_link "${V0_WORKSPACE_DIR}"

  echo "Workspace worktree created at ${V0_WORKSPACE_DIR}"
  return 0
}

# ws_init_wok_link <worktree_path>
# Initialize wok in a worktree, linking to main repo's .wok database
# Idempotent: succeeds if already initialized with valid config
ws_init_wok_link() {
  local worktree_path="$1"

  # Skip if wk command not available
  if ! command -v wk &>/dev/null; then
    return 0
  fi

  # Find main repo's .wok directory
  # Use git-common-dir to get the main repo from a worktree
  local main_repo
  local git_common_dir
  git_common_dir=$(git -C "${worktree_path}" rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "${git_common_dir}" ]] && [[ "${git_common_dir}" != ".git" ]] && [[ "${git_common_dir}" != "${worktree_path}/.git" ]]; then
    # git_common_dir points to main repo's .git, get parent
    main_repo=$(dirname "${git_common_dir}")
  else
    main_repo="${V0_ROOT:-${worktree_path}}"
  fi

  local wok_dir="${main_repo}/.wok"
  if [[ ! -d "${wok_dir}" ]]; then
    return 0  # No wok in main repo, skip
  fi

  local worktree_wok="${worktree_path}/.wok"

  # Check if already properly initialized (config.toml exists)
  if [[ -f "${worktree_wok}/config.toml" ]]; then
    return 0  # Already initialized
  fi

  # Handle incomplete .wok directory (e.g., only .gitignore from checkout)
  # wk init fails with "already initialized" if .wok/ exists, even without config
  if [[ -d "${worktree_wok}" ]] && [[ ! -f "${worktree_wok}/config.toml" ]]; then
    rm -rf "${worktree_wok}"
  fi

  # Initialize wok workspace link with prefix if configured
  if [[ -n "${ISSUE_PREFIX:-}" ]]; then
    wk init --workspace "${wok_dir}" --prefix "${ISSUE_PREFIX}" --path "${worktree_path}" >/dev/null 2>&1 || true
  else
    wk init --workspace "${wok_dir}" --path "${worktree_path}" >/dev/null 2>&1 || true
  fi
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

  # Initialize wok workspace link if wok exists in main repo
  ws_init_wok_link "${V0_WORKSPACE_DIR}"

  echo "Workspace clone created at ${V0_WORKSPACE_DIR}"
  return 0
}

# ws_ensure_workspace
# Idempotent function that creates workspace if missing or mismatched
# Validates workspace matches current config (mode + branch)
# Uses V0_WORKSPACE_MODE to determine creation method
# Returns: 0 on success, 1 on failure
ws_ensure_workspace() {
  # Check if workspace already exists, is valid, AND matches current config
  if ws_is_valid_workspace; then
    if ws_matches_config; then
      # Ensure wok link is initialized (repairs incomplete .wok from older workspaces)
      ws_init_wok_link "${V0_WORKSPACE_DIR}"
      return 0
    fi
    # Config mismatch - need to recreate
    echo "Recreating workspace to match current config..." >&2
    ws_remove_workspace
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
