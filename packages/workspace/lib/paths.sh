#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# workspace/paths.sh - Path resolution helpers
#
# PURE: All functions are pure (no side effects)

# Expected environment variables:
# V0_ROOT - Path to project root
# V0_STATE_DIR - Path to project state directory
# V0_WORKSPACE_DIR - Path to workspace directory
# REPO_NAME - Name of the repository

# ws_get_workspace_dir
# Get the workspace directory path
# Returns: workspace directory path
ws_get_workspace_dir() {
  echo "${V0_WORKSPACE_DIR}"
}

# ws_get_workspace_parent
# Get the parent directory where workspace is stored
# Returns: parent directory path (V0_STATE_DIR/workspace)
ws_get_workspace_parent() {
  echo "${V0_STATE_DIR}/workspace"
}

# ws_workspace_exists
# Check if workspace directory exists
# Returns: 0 if exists, 1 if not
ws_workspace_exists() {
  [[ -d "${V0_WORKSPACE_DIR}" ]]
}

# ws_is_valid_workspace
# Check if a directory is a valid git workspace (has .git)
# Args: directory path (defaults to V0_WORKSPACE_DIR)
# Returns: 0 if valid, 1 if not
ws_is_valid_workspace() {
  local dir="${1:-${V0_WORKSPACE_DIR}}"
  [[ -d "${dir}" ]] && { [[ -d "${dir}/.git" ]] || [[ -f "${dir}/.git" ]]; }
}
