#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# v0-common.sh - Shared functions for v0 tools
# Source this at the start of each v0 command

# Find v0 installation directory
V0_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_RED=''
fi

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
  V0_MAIN_BRANCH="main"
  V0_FEATURE_BRANCH="feature/{name}"
  V0_BUGFIX_BRANCH="fix/{id}"
  V0_CHORE_BRANCH="chore/{id}"
  V0_WORKTREE_INIT="${V0_WORKTREE_INIT:-}"  # Optional worktree init hook

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
  export V0_BUILD_DIR V0_PLANS_DIR V0_MAIN_BRANCH V0_FEATURE_BRANCH V0_BUGFIX_BRANCH V0_CHORE_BRANCH
  # shellcheck disable=SC2090  # V0_WORKTREE_INIT is a shell command used with eval
  export V0_WORKTREE_INIT
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

# Create .v0.rc template in specified directory
v0_init_config() {
  local target_dir="${1:-$(pwd)}"
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

  # Only create or update .v0.rc if it doesn't exist
  if [[ -f "${config_file}" ]]; then
    echo ".v0.rc already exists in ${target_dir}"
  else
    cat > "${config_file}" <<EOF
# v0 project configuration
# See: https://github.com/alfredjeanlab/v0

# Required: Project identity
PROJECT="${project_name}"
ISSUE_PREFIX="${issue_prefix}"    # Issue IDs: ${issue_prefix}-abc123

# Optional: Override defaults
# V0_BUILD_DIR=".v0/build"      # Build state directory
# V0_PLANS_DIR="plans"          # Implementation plans
# V0_FEATURE_BRANCH="feature/{name}"
# V0_BUGFIX_BRANCH="fix/{id}"
# V0_CHORE_BRANCH="chore/{id}"
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

# v0_find_dependent_operations <operation>
# Find operations waiting for the given operation (have after=<operation>)
# Outputs operation names, one per line
v0_find_dependent_operations() {
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

# v0_trigger_dependent_operations <branch>
# Find and resume operations that were waiting on the given operation
# Called after a successful merge to unblock dependent operations
# Handles both full branch names (feature/name) and operation names (name)
v0_trigger_dependent_operations() {
  local branch="$1"
  local op_name
  op_name=$(basename "${branch}")
  local dep_op
  local triggered=""

  for dep_op in $(v0_find_dependent_operations "${op_name}"); do
    # Skip if already triggered (handles case where branch==op_name)
    [[ "${triggered}" == *"|${dep_op}|"* ]] && continue
    triggered="${triggered}|${dep_op}|"
    local state_file="${BUILD_DIR}/operations/${dep_op}/state.json"

    if [[ ! -f "${state_file}" ]]; then
      echo "Warning: No state file for dependent operation '${dep_op}'" >&2
      continue
    fi

    # Get the phase to resume from
    local blocked_phase
    blocked_phase=$(jq -r '.blocked_phase // "init"' "${state_file}")
    if [[ "${blocked_phase}" = "null" ]] || [[ -z "${blocked_phase}" ]]; then
      blocked_phase="init"
    fi

    # Clear after state and restore phase
    local tmp
    tmp=$(mktemp)
    jq '.after = null | .phase = (.blocked_phase // "init")' "${state_file}" > "${tmp}"
    mv "${tmp}" "${state_file}"

    echo "Unblocking dependent operation: ${dep_op} (resuming from phase: ${blocked_phase})"

    # Only resume if not held - respect existing holds
    if v0_is_held "${dep_op}"; then
      echo "Operation '${dep_op}' remains on hold (use 'v0 resume ${dep_op}' to start)"
    else
      # Resume the operation in background
      "${V0_DIR}/bin/v0-feature" "${dep_op}" --resume &
    fi
  done
}

# v0_is_held <name>
# Check if operation is held
# Returns 0 if held, 1 if not held
v0_is_held() {
  local name="$1"
  local state_file="${BUILD_DIR}/operations/${name}/state.json"
  [[ ! -f "${state_file}" ]] && return 1
  local held
  held=$(jq -r '.held // false' "${state_file}")
  [[ "${held}" = "true" ]]
}

# v0_exit_if_held <name> <command>
# Print hold notice and exit if operation is held
# Usage: v0_exit_if_held <name> <command>
v0_exit_if_held() {
  local name="$1"
  local command="$2"
  if v0_is_held "${name}"; then
    echo "Operation '${name}' is on hold."
    echo ""
    echo "The operation will not proceed until the hold is released."
    echo ""
    echo "Release hold with:"
    echo "  v0 resume ${name}"
    echo ""
    echo "Or cancel the operation:"
    echo "  v0 cancel ${name}"
    exit 0
  fi
}
