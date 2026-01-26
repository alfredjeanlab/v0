#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Configuration loading and initialization for v0
# Source this file to get config functions

# Global standalone state directory (no project required)
V0_STANDALONE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/v0/standalone"

# Infer workspace mode based on develop branch
# Returns: "worktree" or "clone"
v0_infer_workspace_mode() {
  local develop_branch="${1:-${V0_DEVELOP_BRANCH:-main}}"
  case "${develop_branch}" in
    main|develop|master) echo "clone" ;;
    *) echo "worktree" ;;
  esac
}

# Maximum operations to show in v0 status list (default: 15)
# Set to 0 or very high number to disable limit
V0_STATUS_LIMIT="${V0_STATUS_LIMIT:-15}"

# Initialize standalone directory structure
v0_init_standalone() {
    mkdir -p "${V0_STANDALONE_DIR}/build/chore"
    mkdir -p "${V0_STANDALONE_DIR}/logs"

    # Initialize .wok if not present
    if [[ ! -f "${V0_STANDALONE_DIR}/.wok/config.toml" ]]; then
        (cd "${V0_STANDALONE_DIR}" && wk init --prefix "chore")
    fi
}

# Find project root by walking up directory tree looking for .v0.rc
v0_find_project_root() {
  local dir="${1:-$(pwd)}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -f "${dir}/.v0.rc" ]]; then
      echo "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

# Find the main repo directory (not a worktree)
# This is needed for the merge queue daemon which must run from the main repo
# to be able to checkout the main branch
# Returns: main repo directory path, or current V0_ROOT if not in a worktree
v0_find_main_repo() {
  local dir="${1:-${V0_ROOT:-$(pwd)}}"

  # Check if we're in a git repo
  if ! git -C "${dir}" rev-parse --git-dir &>/dev/null; then
    echo "${dir}"
    return 0
  fi

  # Get the common git directory (shared between all worktrees)
  local git_common_dir
  git_common_dir=$(git -C "${dir}" rev-parse --git-common-dir 2>/dev/null)

  if [[ -z "${git_common_dir}" ]]; then
    echo "${dir}"
    return 0
  fi

  # Normalize the path
  git_common_dir=$(cd "${dir}" && cd "${git_common_dir}" && pwd)

  # The main repo is the parent of the .git directory
  # For the main repo: git_common_dir = /path/to/repo/.git
  # For a worktree: git_common_dir = /path/to/main-repo/.git
  local main_repo
  main_repo=$(dirname "${git_common_dir}")

  echo "${main_repo}"
}

# Load project configuration
# Sets: V0_ROOT, PROJECT, ISSUE_PREFIX, REPO_NAME, V0_STATE_DIR, V0_BUILD_DIR, etc.
v0_load_config() {
  local require_config="${1:-true}"

  # First try to find project root by walking up from current directory
  # This ensures commands run from within a project use that project's config
  local found_root
  if found_root=$(v0_find_project_root 2>/dev/null); then
    V0_ROOT="${found_root}"
  # Fall back to pre-set V0_ROOT if it has a valid .v0.rc
  # This handles worktrees and other scenarios where cwd doesn't contain .v0.rc
  # but V0_ROOT was explicitly set by the parent process
  elif [[ -n "${V0_ROOT:-}" ]] && [[ -f "${V0_ROOT}/.v0.rc" ]]; then
    # V0_ROOT is already set and valid, keep it
    :
  elif [[ "${require_config}" = "true" ]]; then
    echo "Error: No .v0.rc found in current directory or parents." >&2
    echo "Run 'v0 init' to create one, or cd to a project with .v0.rc" >&2
    exit 1
  else
    return 1
  fi

  # Defaults (can be overridden in .v0.rc)
  V0_BUILD_DIR=".v0/build"
  V0_PLANS_DIR="plans"
  V0_DEVELOP_BRANCH="main"
  V0_FEATURE_BRANCH="feature/{name}"
  V0_BUGFIX_BRANCH="fix/{id}"
  V0_CHORE_BRANCH="chore/{id}"
  V0_WORKTREE_INIT="${V0_WORKTREE_INIT:-}"  # Optional worktree init hook
  V0_GIT_REMOTE="origin"                     # Git remote for push/fetch operations
  V0_WORKSPACE_MODE="${V0_WORKSPACE_MODE:-}" # 'worktree' or 'clone' (inferred if empty)

  # Load project config (overrides defaults)
  source "${V0_ROOT}/.v0.rc"

  # Validate required fields
  if [[ -z "${PROJECT}" ]]; then
    echo "Error: PROJECT not set in .v0.rc" >&2
    exit 1
  fi
  if [[ -z "${ISSUE_PREFIX}" ]]; then
    echo "Error: ISSUE_PREFIX not set in .v0.rc" >&2
    exit 1
  fi

  # Derived values
  REPO_NAME=$(basename "${V0_ROOT}")
  V0_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/v0/${PROJECT}"

  # Infer workspace mode if not set
  if [[ -z "${V0_WORKSPACE_MODE}" ]]; then
    V0_WORKSPACE_MODE=$(v0_infer_workspace_mode "${V0_DEVELOP_BRANCH}")
  fi

  # Workspace directory for merge operations (keeps V0_ROOT clean)
  V0_WORKSPACE_DIR="${V0_STATE_DIR}/workspace/${REPO_NAME}"

  # Full paths
  BUILD_DIR="${V0_ROOT}/${V0_BUILD_DIR}"
  PLANS_DIR="${V0_ROOT}/${V0_PLANS_DIR}"

  # V0_TEST_MODE: When set to 1, disable notifications automatically
  # This allows tests to run without triggering OS notifications
  if [[ "${V0_TEST_MODE:-}" = "1" ]]; then
    export DISABLE_NOTIFICATIONS=1
  fi

  # Export for subprocesses
  export V0_ROOT PROJECT ISSUE_PREFIX REPO_NAME V0_STATE_DIR BUILD_DIR PLANS_DIR
  export V0_BUILD_DIR V0_PLANS_DIR V0_DEVELOP_BRANCH V0_FEATURE_BRANCH V0_BUGFIX_BRANCH V0_CHORE_BRANCH
  # shellcheck disable=SC2090  # V0_WORKTREE_INIT is a shell command used with eval
  export V0_WORKTREE_INIT
  export V0_GIT_REMOTE
  export V0_WORKSPACE_MODE V0_WORKSPACE_DIR
}

# Load standalone configuration (no .v0.rc required)
# Sets minimal variables needed for chore operations
v0_load_standalone_config() {
    v0_init_standalone

    # Set variables that chore command needs
    export V0_STANDALONE=1
    export V0_STATE_DIR="${V0_STANDALONE_DIR}"
    export BUILD_DIR="${V0_STANDALONE_DIR}/build"
    export PROJECT="standalone"
    export ISSUE_PREFIX="chore"

    # No V0_ROOT in standalone mode
    export V0_ROOT=""
    export V0_DEVELOP_BRANCH=""
}

# Check if we're in standalone mode
v0_is_standalone() {
    [[ "${V0_STANDALONE:-0}" == "1" ]]
}

# Detect the best default branch for development
# Returns: branch name (develop if exists, otherwise v0/develop for new projects)
v0_detect_develop_branch() {
  local remote="${1:-origin}"

  # Check if 'develop' exists locally
  if git branch --list develop 2>/dev/null | v0_grep_quiet develop; then
    echo "develop"
    return 0
  fi

  # Check if 'develop' exists on remote
  if git ls-remote --heads "${remote}" develop 2>/dev/null | v0_grep_quiet develop; then
    echo "develop"
    return 0
  fi

  # Fallback to v0/develop for new projects
  echo "v0/develop"
}

# Ensure v0/develop branch exists, creating from current HEAD if needed
v0_ensure_develop_branch() {
  local remote="${1:-origin}"

  # Skip if not in a git repository
  if ! git rev-parse --git-dir &>/dev/null; then
    return 0
  fi

  # Check if v0/develop branch exists locally
  if git branch --list "v0/develop" 2>/dev/null | v0_grep_quiet "v0/develop"; then
    return 0
  fi

  # Check if v0/develop branch exists on remote
  if git ls-remote --heads "${remote}" "v0/develop" 2>/dev/null | v0_grep_quiet "v0/develop"; then
    # Fetch and create local tracking branch
    git fetch "${remote}" "v0/develop" 2>/dev/null || true
    git branch --track "v0/develop" "${remote}/v0/develop" 2>/dev/null || true
    return 0
  fi

  # Create new v0/develop branch from current HEAD (typically main)
  local base_branch
  base_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

  git branch "v0/develop" "${base_branch}" 2>/dev/null || {
    echo "Warning: Could not create v0/develop branch" >&2
    return 1
  }

  echo -e "Created branch ${C_CYAN}v0/develop${C_RESET}"
}

# Create .v0.rc template in specified directory
# Args: target_dir [develop_branch] [git_remote]
v0_init_config() {
  local target_dir="${1:-$(pwd)}"
  local develop_branch="${2:-}"
  local git_remote="${3:-origin}"
  # Normalize the path (convert "." to absolute path)
  target_dir="$(cd "${target_dir}" && pwd)"
  local config_file="${target_dir}/.v0.rc"

  # Try to infer project name from directory
  local project_name
  project_name=$(basename "${target_dir}")

  # Initialize or load wk workspace
  local issue_prefix
  if [[ -f "${target_dir}/.wok/config.toml" ]]; then
    # Read prefix from existing wk config
    issue_prefix=$(v0_grep '^prefix' "${target_dir}/.wok/config.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' || true)
    if [[ -z "${issue_prefix}" ]]; then
      issue_prefix="${project_name}"
    fi
  else
    # Initialize wk and let it determine the prefix
    echo "Initializing wk workspace..."
    if wk init; then
      echo "Created wk configuration at ${target_dir}/.wok"

      # Read the prefix that wk determined
      issue_prefix=$(v0_grep '^prefix' "${target_dir}/.wok/config.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' || true)
      if [[ -z "${issue_prefix}" ]]; then
        issue_prefix="${project_name}"
      fi

      # Add .wok to gitignore when wk init runs
      if [[ -f "${target_dir}/.gitignore" ]]; then
        if ! v0_grep_quiet "^\.wok/" "${target_dir}/.gitignore"; then
          echo ".wok/" >> "${target_dir}/.gitignore"
          echo "Added .wok/ to .gitignore"
        fi
      else
        echo ".wok/" > "${target_dir}/.gitignore"
        echo "Created .gitignore with .wok/"
      fi
    fi
  fi

  # Ensure .v0/ is in gitignore (always, regardless of wk state)
  if [[ -f "${target_dir}/.gitignore" ]]; then
    if ! v0_grep_quiet "^\.v0/" "${target_dir}/.gitignore"; then
      echo ".v0/" >> "${target_dir}/.gitignore"
      echo "Added .v0/ to .gitignore"
    fi
  else
    echo ".v0/" > "${target_dir}/.gitignore"
    echo "Created .gitignore with .v0/"
  fi

  # Default to v0/develop for new projects
  if [[ -z "${develop_branch}" ]]; then
    develop_branch="v0/develop"
  fi

  # Create v0/develop branch if it doesn't exist (only for 'v0/develop' branch)
  if [[ "${develop_branch}" == "v0/develop" ]]; then
    v0_ensure_develop_branch "${git_remote}"
  fi

  # Always show where agents will merge
  echo -e "Agents will merge into \`${C_CYAN}${develop_branch}${C_RESET}\`"

  # Infer workspace mode based on develop branch
  local workspace_mode
  workspace_mode=$(v0_infer_workspace_mode "${develop_branch}")

  # Only create or update .v0.rc if it doesn't exist
  if [[ -f "${config_file}" ]]; then
    echo ".v0.rc already exists in ${target_dir}"
  else
    # Generate config with conditional commenting based on defaults
    local branch_line remote_line workspace_line
    # Always write branch explicitly (self-documenting config)
    branch_line="V0_DEVELOP_BRANCH=\"${develop_branch}\"     # Target branch for merges"

    if [[ "${git_remote}" != "origin" ]]; then
      remote_line="V0_GIT_REMOTE=\"${git_remote}\"        # Git remote for push/fetch"
    else
      remote_line="# V0_GIT_REMOTE=\"origin\"        # Git remote for push/fetch"
    fi

    # Add workspace mode comment explaining the setting
    workspace_line="# V0_WORKSPACE_MODE=\"${workspace_mode}\"  # 'worktree' or 'clone' (auto-detected)"

    cat > "${config_file}" <<EOF
# v0 project configuration
# See: https://github.com/alfredjeanlab/v0

# Required: Project identity
PROJECT="${project_name}"
ISSUE_PREFIX="${issue_prefix}"    # Issue IDs: ${issue_prefix}-abc123

# Optional: Override defaults
# V0_BUILD_DIR=".v0/build"      # Build state directory
# V0_PLANS_DIR="plans"          # Implementation plans
${branch_line}
# V0_FEATURE_BRANCH="feature/{name}"
# V0_BUGFIX_BRANCH="fix/{id}"
# V0_CHORE_BRANCH="chore/{id}"
${remote_line}
${workspace_line}
# DISABLE_NOTIFICATIONS=1       # Disable macOS notifications
EOF

    echo "Created ${config_file}"
    echo ""
    echo "Edit the file to configure your project, then run v0 commands."
    echo ""
    echo "To start background workers:"
    echo "  v0 startup         # Starts fix, chore, and mergeq workers"
    echo ""
    echo "  # Or start individual workers: v0 fix --start, v0 chore --start"
    echo "  # Focused commands (v0 feature, v0 plan) manage their own sessions"
  fi

  # Load config to set up derived values needed for workspace creation
  V0_ROOT="${target_dir}"
  PROJECT="${project_name}"
  REPO_NAME=$(basename "${target_dir}")
  V0_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/v0/${PROJECT}"
  V0_DEVELOP_BRANCH="${develop_branch}"
  V0_GIT_REMOTE="${git_remote}"
  V0_WORKSPACE_MODE="${workspace_mode}"
  V0_WORKSPACE_DIR="${V0_STATE_DIR}/workspace/${REPO_NAME}"

  # Create workspace for merge operations (quietly - errors still go to stderr)
  if ! ws_ensure_workspace > /dev/null; then
    echo ""
    echo -e "${C_YELLOW}Warning: Failed to create workspace${C_RESET}"
    echo "  Workspace will be created on first merge operation."
  fi

  # Security warning about autonomous workers
  echo ""
  echo -e "${C_YELLOW}${C_BOLD}WARNING:${C_RESET}${C_YELLOW} v0 workers run with --dangerously-skip-permissions${C_RESET}"
  echo ""
  echo "  This means Claude can execute commands without approval prompts."
  echo "  Workers operate autonomously - review the v0 documentation and ensure"
  echo "  you understand the implications before running workers in this project."
  echo ""
}
