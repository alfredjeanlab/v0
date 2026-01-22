#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# v0-common.sh - Shared functions for v0 tools
# Source this at the start of each v0 command

# Find v0 installation directory
V0_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source state machine library for centralized state management
# shellcheck source=lib/state-machine.sh
source "${V0_INSTALL_DIR}/lib/state-machine.sh"

# Color support (only when stdout is a TTY)
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_BLUE='\033[34m'
    C_CYAN='\033[36m'
    C_RED='\033[31m'
    C_LAVENDER='\033[38;5;183m'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_RED=''
    C_LAVENDER=''
fi

# Global standalone state directory (no project required)
V0_STANDALONE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/v0/standalone"

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

# Generate a namespaced tmux session name
# Usage: v0_session_name "suffix" "type"
# Example: v0_session_name "worker" "fix" -> "v0-myproject-worker-fix"
v0_session_name() {
  local suffix="$1"
  local type="$2"

  if [[ -z "${PROJECT}" ]]; then
    echo "Error: PROJECT not set. Call v0_load_config first." >&2
    return 1
  fi

  echo "v0-${PROJECT}-${suffix}-${type}"
}

# Detect the best default branch for development
# Returns: branch name (develop if exists, otherwise main)
v0_detect_develop_branch() {
  local remote="${1:-origin}"

  # Check if 'develop' exists locally
  if git branch --list develop 2>/dev/null | grep -q develop; then
    echo "develop"
    return 0
  fi

  # Check if 'develop' exists on remote
  if git ls-remote --heads "${remote}" develop 2>/dev/null | grep -q develop; then
    echo "develop"
    return 0
  fi

  # Fallback to main
  echo "main"
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
    issue_prefix=$(grep -E '^prefix' "${target_dir}/.wok/config.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' || true)
    if [[ -z "${issue_prefix}" ]]; then
      issue_prefix="${project_name}"
    fi
  else
    # Initialize wk and let it determine the prefix
    echo "Initializing wk workspace..."
    if wk init; then
      echo "Created wk configuration at ${target_dir}/.wok"

      # Read the prefix that wk determined
      issue_prefix=$(grep -E '^prefix' "${target_dir}/.wok/config.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' || true)
      if [[ -z "${issue_prefix}" ]]; then
        issue_prefix="${project_name}"
      fi

      # Add .wok to gitignore when wk init runs
      if [[ -f "${target_dir}/.gitignore" ]]; then
        if ! grep -q "^\.wok/" "${target_dir}/.gitignore"; then
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
    if ! grep -q "^\.v0/" "${target_dir}/.gitignore"; then
      echo ".v0/" >> "${target_dir}/.gitignore"
      echo "Added .v0/ to .gitignore"
    fi
  else
    echo ".v0/" > "${target_dir}/.gitignore"
    echo "Created .gitignore with .v0/"
  fi

  # Auto-detect branch if not specified
  if [[ -z "${develop_branch}" ]]; then
    develop_branch="$(v0_detect_develop_branch "${git_remote}")"
  fi

  # Only create or update .v0.rc if it doesn't exist
  if [[ -f "${config_file}" ]]; then
    echo ".v0.rc already exists in ${target_dir}"
  else
    # Generate config with conditional commenting based on defaults
    local branch_line remote_line
    if [[ "${develop_branch}" != "main" ]]; then
      branch_line="V0_DEVELOP_BRANCH=\"${develop_branch}\"     # Target branch for merges"
    else
      branch_line="# V0_DEVELOP_BRANCH=\"main\"      # Target branch for merges (default: main)"
    fi

    if [[ "${git_remote}" != "origin" ]]; then
      remote_line="V0_GIT_REMOTE=\"${git_remote}\"        # Git remote for push/fetch"
    else
      remote_line="# V0_GIT_REMOTE=\"origin\"        # Git remote for push/fetch"
    fi

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

  # Security warning about autonomous workers
  echo ""
  echo -e "${C_YELLOW}${C_BOLD}WARNING:${C_RESET}${C_YELLOW} v0 workers run with --dangerously-skip-permissions${C_RESET}"
  echo ""
  echo "  This means Claude can execute commands without approval prompts."
  echo "  Workers operate autonomously - review the v0 documentation and ensure"
  echo "  you understand the implications before running workers in this project."
  echo ""
}

# Get issue ID pattern for grep/regex matching
v0_issue_pattern() {
  echo "${ISSUE_PREFIX}-[a-z0-9]+"
}

# Expand a branch template by substituting {name} or {id} with a value
# Usage: v0_expand_branch "$V0_FEATURE_BRANCH" "$NAME"
# Example: v0_expand_branch "feature/{name}" "auth" -> "feature/auth"
v0_expand_branch() {
  local template="$1"
  local value="$2"

  # Replace both {name} and {id} placeholders with the value
  local result="${template//\{name\}/${value}}"
  result="${result//\{id\}/${value}}"
  echo "${result}"
}

# Ensure state directory exists
v0_ensure_state_dir() {
  mkdir -p "${V0_STATE_DIR}"
}

# Ensure build directory exists
v0_ensure_build_dir() {
  mkdir -p "${BUILD_DIR}"
}

# Log event to project log
v0_log() {
  local event="$1"
  local message="$2"
  local log_dir="${BUILD_DIR}/logs"
  mkdir -p "${log_dir}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${event}: ${message}" >> "${log_dir}/v0.log"
}

# Check required dependencies
v0_check_deps() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "${cmd}" &> /dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: Missing required commands: ${missing[*]}" >&2
    exit 1
  fi
}

# v0_notify - Send notification (log + OS notification on macOS)
# Args: $1 = title, $2 = message
# Set DISABLE_NOTIFICATIONS=1 or V0_TEST_MODE=1 to disable OS notifications
v0_notify() {
  local title="$1"
  local message="$2"

  # Always log
  v0_log "notify" "${title}: ${message}"

  # Skip OS notifications if disabled or in test mode
  if [[ "${DISABLE_NOTIFICATIONS:-}" = "1" ]] || [[ "${V0_TEST_MODE:-}" = "1" ]]; then
    return 0
  fi

  # macOS notification if available
  if [[ "$(uname)" = "Darwin" ]] && command -v osascript &> /dev/null; then
    osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
  fi
}

# Check if the git worktree is clean (no uncommitted changes)
# Returns 0 if clean, 1 if dirty
# Usage: v0_git_worktree_clean [directory]
v0_git_worktree_clean() {
    local dir="${1:-.}"
    # Check for any changes (staged, unstaged, or untracked in tracked dirs)
    if git -C "${dir}" diff --quiet HEAD 2>/dev/null && \
       git -C "${dir}" diff --cached --quiet 2>/dev/null; then
        return 0
    fi
    return 1
}

# archive_plan <plan_file>
# Archives a plan file to plans/archive/{YYYY-MM-DD}/{filename}
# Returns 0 on success, 1 if source file doesn't exist
archive_plan() {
  local plan_file="$1"

  # Validate input
  if [[ -z "${plan_file}" ]]; then
    return 1
  fi

  # Handle both relative (plans/foo.md) and absolute paths
  local source_path
  if [[ "${plan_file}" = /* ]]; then
    source_path="${plan_file}"
  else
    source_path="${V0_ROOT}/${plan_file}"
  fi

  # Skip if source doesn't exist
  if [[ ! -f "${source_path}" ]]; then
    return 1
  fi

  # Extract filename
  local plan_name
  plan_name=$(basename "${source_path}")

  # Create archive directory with today's date
  local archive_date
  archive_date=$(date +%Y-%m-%d)
  local archive_dir="${PLANS_DIR}/archive/${archive_date}"

  mkdir -p "${archive_dir}"

  # Move plan to archive
  mv "${source_path}" "${archive_dir}/${plan_name}"
}

# Required dependencies for v0
V0_REQUIRED_DEPS=(git tmux jq wk claude flock)

# Get installation instructions for a missing dependency
# Usage: v0_install_instructions <command>
v0_install_instructions() {
  local cmd="$1"
  local os
  os="$(uname -s)"

  case "${cmd}" in
    git)
      case "${os}" in
        Darwin) echo "  brew install git" ;;
        Linux)  echo "  sudo apt install git  # Debian/Ubuntu"
                echo "  sudo dnf install git  # Fedora" ;;
        *)      echo "  https://git-scm.com/downloads" ;;
      esac
      ;;
    tmux)
      case "${os}" in
        Darwin) echo "  brew install tmux" ;;
        Linux)  echo "  sudo apt install tmux  # Debian/Ubuntu"
                echo "  sudo dnf install tmux  # Fedora" ;;
        *)      echo "  https://github.com/tmux/tmux" ;;
      esac
      ;;
    jq)
      case "${os}" in
        Darwin) echo "  brew install jq" ;;
        Linux)  echo "  sudo apt install jq  # Debian/Ubuntu"
                echo "  sudo dnf install jq  # Fedora" ;;
        *)      echo "  https://jqlang.github.io/jq/download/" ;;
      esac
      ;;
    wk)
      echo "  https://github.com/alfredjeanlab/wk"
      ;;
    claude)
      echo "  https://claude.ai/claude-code"
      echo "  npm install -g @anthropic-ai/claude-code"
      ;;
    flock)
      case "${os}" in
        Darwin) echo "  brew install flock" ;;
        Linux)  echo "  sudo apt install util-linux  # Debian/Ubuntu (usually pre-installed)"
                echo "  sudo dnf install util-linux  # Fedora (usually pre-installed)" ;;
        *)      echo "  https://github.com/discoteq/flock" ;;
      esac
      ;;
    *)
      echo "  (no installation instructions available)"
      ;;
  esac
}

# Check all required dependencies and report missing ones
# Returns 0 if all deps present, 1 if any missing
# Outputs missing deps and instructions to stderr
v0_precheck() {
  local missing=()

  for cmd in "${V0_REQUIRED_DEPS[@]}"; do
    if ! command -v "${cmd}" &> /dev/null; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Missing required dependencies:" >&2
  echo "" >&2

  for cmd in "${missing[@]}"; do
    echo "  ${cmd}" >&2
  done

  echo "" >&2
  echo "Installation instructions:" >&2
  echo "" >&2

  for cmd in "${missing[@]}"; do
    echo "${cmd}:" >&2
    v0_install_instructions "${cmd}" >&2
    echo "" >&2
  done

  return 1
}

# ============================================================================
# Trace Logging (for debugging)
# ============================================================================

# v0_trace <event> <message>
# Log trace events to trace.log for debugging
# Cheap append-only operation with minimal performance impact
v0_trace() {
  local event="$1"
  shift
  local message="$*"

  # Ensure BUILD_DIR is set
  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local trace_dir="${BUILD_DIR}/logs"
  local trace_file="${trace_dir}/trace.log"

  # Create log directory if needed (only on first trace)
  if [[ ! -d "${trace_dir}" ]]; then
    mkdir -p "${trace_dir}" 2>/dev/null || return 0
  fi

  # Append trace entry (suppress errors to avoid breaking callers)
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${event}" "${message}" >> "${trace_file}" 2>/dev/null || true
}

# v0_trace_rotate
# Rotate trace.log if it exceeds 1MB
# Call periodically (e.g., at start of long operations)
v0_trace_rotate() {
  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local trace_file="${BUILD_DIR}/logs/trace.log"
  [[ ! -f "${trace_file}" ]] && return 0

  local size
  # macOS uses -f%z, Linux uses -c%s
  size=$(stat -f%z "${trace_file}" 2>/dev/null || stat -c%s "${trace_file}" 2>/dev/null || echo 0)

  if (( size > 1048576 )); then  # 1MB
    mv "${trace_file}" "${trace_file}.old" 2>/dev/null || true
    v0_trace "rotate" "Rotated trace.log (was ${size} bytes)"
  fi
}

# v0_capture_error_context
# Capture debugging context when an error occurs
# Call this in error handlers to help with debugging
v0_capture_error_context() {
  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local context_file="${BUILD_DIR}/logs/error-context.log"
  local log_dir="${BUILD_DIR}/logs"

  mkdir -p "${log_dir}" 2>/dev/null || return 0

  {
    echo "=== Error Context $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
    echo "PWD: $(pwd)"
    echo "Script: ${BASH_SOURCE[1]:-unknown}"
    echo "Line: ${BASH_LINENO[0]:-unknown}"
    echo "Git branch: $(git branch --show-current 2>/dev/null || echo 'N/A')"
    echo "Git status:"
    git status --porcelain 2>/dev/null | head -10 || echo "  (git status failed)"
    echo ""
  } >> "${context_file}" 2>/dev/null || true
}

# ============================================================================
# Log Pruning
# ============================================================================

# v0_prune_logs [--dry-run]
# Prune log entries older than 6 hours from logs with ISO 8601 timestamps
# Only processes logs with [YYYY-MM-DDTHH:MM:SSZ] format at line start
# Usage: v0_prune_logs [--dry-run]
v0_prune_logs() {
  local dry_run=""
  [[ "$1" = "--dry-run" ]] && dry_run=1

  [[ -z "${BUILD_DIR:-}" ]] && return 0
  [[ ! -d "${BUILD_DIR}" ]] && return 0

  # Calculate cutoff time (6 hours ago) in epoch seconds
  local cutoff_epoch
  cutoff_epoch=$(date -u -v-6H +%s 2>/dev/null || date -u -d '6 hours ago' +%s 2>/dev/null || echo "")
  [[ -z "${cutoff_epoch}" ]] && return 0

  local pruned_count=0
  local log_files
  log_files=$(find "${BUILD_DIR}" -name "*.log" -type f 2>/dev/null || true)

  # No log files found
  [[ -z "${log_files}" ]] && return 0

  while IFS= read -r log_file; do
    [[ -z "${log_file}" ]] && continue
    [[ ! -f "${log_file}" ]] && continue

    # Check if file has ISO 8601 timestamps by looking at first line with a timestamp
    local first_ts_line
    first_ts_line=$(grep -m1 '^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\]' "${log_file}" 2>/dev/null || true)
    [[ -z "${first_ts_line}" ]] && continue

    # Process the file: keep lines with recent timestamps or no timestamp
    local tmp_file
    tmp_file=$(mktemp)
    local lines_before lines_after

    lines_before=$(wc -l < "${log_file}" | tr -d ' ')

    while IFS= read -r line; do
      # Extract timestamp if line starts with [YYYY-MM-DDTHH:MM:SSZ]
      local ts
      ts=$(echo "${line}" | grep -oE '^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\]' 2>/dev/null || true)

      if [[ -z "${ts}" ]]; then
        # Line doesn't start with timestamp - keep it (could be continuation)
        echo "${line}" >> "${tmp_file}"
      else
        # Parse timestamp and compare with cutoff
        local ts_clean line_epoch
        ts_clean="${ts:1:19}"  # Extract YYYY-MM-DDTHH:MM:SS from [YYYY-MM-DDTHH:MM:SSZ]

        # Convert to epoch (macOS vs GNU date)
        line_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts_clean}" +%s 2>/dev/null || \
                     date -u -d "${ts_clean}" +%s 2>/dev/null || echo 0)

        if [[ "${line_epoch}" -ge "${cutoff_epoch}" ]]; then
          echo "${line}" >> "${tmp_file}"
        fi
      fi
    done < "${log_file}"

    lines_after=$(wc -l < "${tmp_file}" | tr -d ' ')
    local removed=$((lines_before - lines_after))

    if [[ "${removed}" -gt 0 ]]; then
      if [[ -n "${dry_run}" ]]; then
        echo "Would prune ${removed} lines from: ${log_file#"${BUILD_DIR}/"}"
      else
        mv "${tmp_file}" "${log_file}"
        echo "Pruned ${removed} lines from: ${log_file#"${BUILD_DIR}/"}"
      fi
      pruned_count=$((pruned_count + 1))
    else
      rm -f "${tmp_file}"
    fi
  done <<< "${log_files}"

  if [[ "${pruned_count}" -eq 0 ]]; then
    [[ -n "${dry_run}" ]] && echo "No log entries older than 6 hours to prune"
  fi
}

# ============================================================================
# Merge Verification Functions
# ============================================================================

# v0_verify_commit_on_branch <commit> <branch> [require_remote]
# Verify that a specific commit exists on a branch
# Returns 0 if commit is on branch, 1 if not
#
# This is the primary verification function - works for all merge workflows
# because it checks a specific commit hash, not a branch name.
#
# Args:
#   commit         - Commit hash to verify
#   branch         - Branch to check (e.g., "main", "origin/main")
#   require_remote - If "true", also verify on origin/${branch} (default: false)
v0_verify_commit_on_branch() {
  local commit="$1"
  local branch="$2"
  local require_remote="${3:-false}"

  # Validate commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    return 1  # Commit doesn't exist
  fi

  # Check if commit is ancestor of local branch
  if ! git merge-base --is-ancestor "${commit}" "${branch}" 2>/dev/null; then
    return 1
  fi

  # Optionally check remote
  if [[ "${require_remote}" = "true" ]]; then
    git fetch "${V0_GIT_REMOTE}" "${branch}" --quiet 2>/dev/null || true
    if ! git merge-base --is-ancestor "${commit}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
      return 1
    fi
  fi

  return 0
}

# v0_verify_push <commit>
# Verify a pushed commit exists on local main.
# Returns 0 if commit is on main, 1 if not.
#
# Why this is sufficient:
# - git push returns 0 only if the push succeeded
# - If push succeeded, the remote has the commit
# - We verify locally that the commit is on main (sanity check)
# - Remote state queries (ls-remote, fetch) can return stale data
#
# Args:
#   commit - Commit hash to verify
v0_verify_push() {
  local commit="$1"

  # Validate commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} does not exist locally" >&2
    return 1
  fi

  # Verify commit is on local main
  if ! git merge-base --is-ancestor "${commit}" main 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} is not on main branch" >&2
    return 1
  fi

  return 0
}

# v0_diagnose_push_verification <commit> <remote_branch>
# Output diagnostic information when push verification fails
v0_diagnose_push_verification() {
  local commit="$1"
  local remote_branch="$2"
  local remote="${remote_branch%%/*}"
  local branch="${remote_branch#*/}"

  echo "=== Push Verification Diagnostic ===" >&2
  echo "Commit to verify: ${commit}" >&2
  echo "Target branch: ${remote_branch}" >&2
  echo "" >&2

  # Check local refs
  echo "Local refs:" >&2
  echo "  HEAD: $(git rev-parse HEAD 2>/dev/null || echo 'N/A')" >&2
  echo "  main: $(git rev-parse main 2>/dev/null || echo 'N/A')" >&2
  echo "  ${remote_branch}: $(git rev-parse "${remote_branch}" 2>/dev/null || echo 'N/A')" >&2
  echo "" >&2

  # Check remote state
  echo "Remote state (via ls-remote):" >&2
  git ls-remote "${remote}" "refs/heads/${branch}" 2>/dev/null || echo "  Failed to query remote" >&2
  echo "" >&2

  # Check if commit exists at all
  if git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "Commit ${commit:0:8} exists locally" >&2
  else
    echo "Commit ${commit:0:8} NOT FOUND locally" >&2
  fi

  # Check ancestry
  echo "" >&2
  echo "Ancestry check:" >&2
  if git merge-base --is-ancestor "${commit}" main 2>/dev/null; then
    echo "  ${commit:0:8} IS ancestor of local main" >&2
  else
    echo "  ${commit:0:8} is NOT ancestor of local main" >&2
  fi

  echo "==================================" >&2
}

# v0_verify_merge_by_op <operation> [require_remote]
# Verify merge using operation's recorded merge commit
# This is the ONLY reliable way to verify after merge completion.
#
# Works for all merge workflows because v0-merge records HEAD after do_merge():
# - Direct FF: records the branch tip (same hash)
# - Rebase+FF: records the rebased commit (new hash that's on main)
# - Merge commit: records the merge commit
#
# Args:
#   operation      - Operation name
#   require_remote - If "true", verify on origin/main (default: false)
v0_verify_merge_by_op() {
  local op="$1"
  local require_remote="${2:-false}"
  local merge_commit
  merge_commit=$(sm_read_state "${op}" "merge_commit")

  if [[ -z "${merge_commit}" ]] || [[ "${merge_commit}" = "null" ]]; then
    return 1  # No recorded merge commit
  fi

  v0_verify_commit_on_branch "${merge_commit}" "main" "${require_remote}"
}

# v0_prune_mergeq [--dry-run]
# Prune completed mergeq entries older than 6 hours
# Removes entries with terminal status (completed, failed, conflict) whose
# updated_at (or enqueued_at) timestamp is older than 6 hours
# Usage: v0_prune_mergeq [--dry-run]
v0_prune_mergeq() {
  local dry_run=""
  [[ "$1" = "--dry-run" ]] && dry_run=1

  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local queue_file="${BUILD_DIR}/mergeq/queue.json"
  [[ ! -f "${queue_file}" ]] && return 0

  # Calculate cutoff time (6 hours ago) in epoch seconds
  local cutoff_epoch
  cutoff_epoch=$(date -u -v-6H +%s 2>/dev/null || date -u -d '6 hours ago' +%s 2>/dev/null || echo "")
  [[ -z "${cutoff_epoch}" ]] && return 0

  # Count entries before pruning
  local entries_before
  entries_before=$(jq '.entries | length' "${queue_file}" 2>/dev/null || echo 0)
  [[ "${entries_before}" -eq 0 ]] && return 0

  # Build jq filter to keep entries that are:
  # 1. Not in terminal state (pending, processing, resumed), OR
  # 2. In terminal state but updated/enqueued within the last 6 hours
  #
  # Terminal states: completed, failed, conflict
  # We use updated_at if present, otherwise fall back to enqueued_at
  local tmp_file
  tmp_file=$(mktemp)

  # Use jq with epoch comparison
  # Pass cutoff as argument to avoid shell injection
  if ! jq --arg cutoff "${cutoff_epoch}" '
    def is_terminal: . == "completed" or . == "failed" or . == "conflict";
    def parse_ts: if . == null then 0 else fromdateiso8601 end;
    def get_age: (.updated_at // .enqueued_at) | parse_ts;
    .entries |= [.[] | select(
      (.status | is_terminal | not) or
      (get_age >= ($cutoff | tonumber))
    )]
  ' "${queue_file}" > "${tmp_file}" 2>/dev/null; then
    rm -f "${tmp_file}"
    return 0
  fi

  # Count entries after pruning
  local entries_after
  entries_after=$(jq '.entries | length' "${tmp_file}" 2>/dev/null || echo "${entries_before}")
  local removed=$((entries_before - entries_after))

  if [[ "${removed}" -gt 0 ]]; then
    if [[ -n "${dry_run}" ]]; then
      echo "Would prune ${removed} mergeq entries older than 6 hours"
      rm -f "${tmp_file}"
    else
      mv "${tmp_file}" "${queue_file}"
      echo "Pruned ${removed} mergeq entries older than 6 hours"
    fi
  else
    rm -f "${tmp_file}"
    if [[ -n "${dry_run}" ]]; then
      echo "No mergeq entries older than 6 hours to prune"
    fi
  fi
}
