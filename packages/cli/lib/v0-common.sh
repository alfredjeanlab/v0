#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# v0-common.sh - Shared functions for v0 tools
# Source this at the start of each v0 command

# Find v0 installation directory (3 levels up from packages/cli/lib/)
V0_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Source state machine library for centralized state management
# shellcheck source=packages/state/lib/state-machine.sh
source "${V0_INSTALL_DIR}/packages/state/lib/state-machine.sh"

# Color support (only when stdout is a TTY, or when V0_FORCE_COLOR is set)
if [[ -t 1 ]] || [[ -n "${V0_FORCE_COLOR:-}" ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_BLUE='\033[34m'
    C_CYAN='\033[36m'
    C_RED='\033[31m'
    C_MAGENTA='\033[35m'
    C_LAVENDER='\033[38;5;183m'
    # Help output colors (muted/pastel palette)
    C_HELP_SECTION='\033[38;5;74m'   # Pastel cyan/steel blue
    C_HELP_COMMAND='\033[38;5;250m'  # Light grey
    C_HELP_DEFAULT='\033[38;5;243m'  # Muted/darker grey
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_RED=''
    C_MAGENTA=''
    C_LAVENDER=''
    C_HELP_SECTION=''
    C_HELP_COMMAND=''
    C_HELP_DEFAULT=''
fi

# Source help colorization functions
# shellcheck source=packages/cli/lib/help-colors.sh
source "${V0_INSTALL_DIR}/packages/cli/lib/help-colors.sh"

# Source modular components
# shellcheck source=packages/core/lib/grep.sh
source "${V0_INSTALL_DIR}/packages/core/lib/grep.sh"

# shellcheck source=packages/core/lib/config.sh
source "${V0_INSTALL_DIR}/packages/core/lib/config.sh"

# shellcheck source=packages/core/lib/logging.sh
source "${V0_INSTALL_DIR}/packages/core/lib/logging.sh"

# shellcheck source=packages/core/lib/pruning.sh
source "${V0_INSTALL_DIR}/packages/core/lib/pruning.sh"

# shellcheck source=packages/core/lib/prune-daemon.sh
source "${V0_INSTALL_DIR}/packages/core/lib/prune-daemon.sh"

# shellcheck source=packages/core/lib/git-verify.sh
source "${V0_INSTALL_DIR}/packages/core/lib/git-verify.sh"

# shellcheck source=packages/workspace/lib/workspace.sh
source "${V0_INSTALL_DIR}/packages/workspace/lib/workspace.sh"

# ============================================================================
# Session and Branch Utilities
# ============================================================================

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

# Get issue ID pattern for grep/regex matching
v0_issue_pattern() {
  echo "${ISSUE_PREFIX}-[a-z0-9]+"
}

# v0_resolve_to_wok_id <id_or_name>
# Resolve an operation name or wok ticket ID to a wok ticket ID
# Returns: wok ticket ID if found, empty if unresolvable
v0_resolve_to_wok_id() {
  local input="$1"
  local issue_pattern
  issue_pattern=$(v0_issue_pattern)

  # If input matches wok ticket pattern, return as-is
  if [[ "${input}" =~ ^${issue_pattern}$ ]]; then
    echo "${input}"
    return 0
  fi

  # Otherwise, treat as operation name and look up epic_id
  local state_file="${BUILD_DIR}/operations/${input}/state.json"
  if [[ -f "${state_file}" ]]; then
    local epic_id
    epic_id=$(jq -r '.epic_id // empty' "${state_file}")
    if [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]]; then
      echo "${epic_id}"
      return 0
    fi
  fi

  # Return empty if unresolvable (will be skipped by caller)
  return 1
}

# ============================================================================
# Wok Blocking Helpers
# ============================================================================

# v0_get_blockers <epic_id>
# Returns JSON array of blocker issue IDs from wok
# Output: ["v0-abc", "v0-def"] or []
v0_get_blockers() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] && echo "[]" && return

  local blockers
  blockers=$(wk show "${epic_id}" -o json 2>/dev/null | jq -r '.blockers // []')
  echo "${blockers:-[]}"
}

# v0_get_first_open_blocker <epic_id>
# Returns the first blocker that is not done/closed
# Output: issue_id or empty
v0_get_first_open_blocker() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] && return

  # Get blockers and filter to first open one
  local blockers
  blockers=$(v0_get_blockers "${epic_id}")
  [[ "${blockers}" == "[]" ]] && return

  # Check each blocker's status (stop at first open)
  local blocker_id
  for blocker_id in $(echo "${blockers}" | jq -r '.[]'); do
    local status
    status=$(wk show "${blocker_id}" -o json 2>/dev/null | jq -r '.status // "unknown"')
    case "${status}" in
      done|closed) continue ;;
      *) echo "${blocker_id}"; return ;;
    esac
  done
}

# v0_is_blocked <epic_id>
# Check if issue has any open blockers
# Returns: 0 if blocked, 1 if not blocked
v0_is_blocked() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] && return 1

  local first_blocker
  first_blocker=$(v0_get_first_open_blocker "${epic_id}")
  [[ -n "${first_blocker}" ]]
}

# v0_blocker_to_op_name <blocker_id>
# Resolve a wok issue ID to an operation name if possible
# Returns: operation name or original issue ID
v0_blocker_to_op_name() {
  local blocker_id="$1"

  # Check if this issue belongs to an operation (has plan: label)
  local labels
  labels=$(wk show "${blocker_id}" -o json 2>/dev/null | jq -r '.labels // []')

  # Look for plan:<name> label
  local plan_label
  plan_label=$(echo "${labels}" | jq -r '.[] | select(startswith("plan:"))' | head -1)

  if [[ -n "${plan_label}" ]]; then
    # Extract name from plan:<name>
    echo "${plan_label#plan:}"
  else
    # No operation found, return issue ID
    echo "${blocker_id}"
  fi
}

# ============================================================================
# Branch Expansion Utilities
# ============================================================================

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

# ============================================================================
# Directory Utilities
# ============================================================================

# Ensure state directory exists
v0_ensure_state_dir() {
  mkdir -p "${V0_STATE_DIR}"
}

# Ensure build directory exists
v0_ensure_build_dir() {
  mkdir -p "${BUILD_DIR}"
}

# ============================================================================
# Dependency Checking
# ============================================================================

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
# Git Utilities
# ============================================================================

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

# ============================================================================
# Plan Utilities
# ============================================================================

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

  # Auto-commit the archived plan
  if git -C "${V0_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
    local relative_path="${V0_PLANS_DIR}/archive/${archive_date}/${plan_name}"

    # Stage both the deletion (from original location) and addition (to archive)
    if git -C "${V0_ROOT}" add -A "${V0_PLANS_DIR}/" && \
       git -C "${V0_ROOT}" commit -m "Archive plan: ${plan_name%.md}" \
         -m "Auto-committed by v0"; then
      v0_log "archive:commit" "Committed archived plan: ${relative_path}"
    else
      v0_log "archive:commit" "Failed to commit archived plan"
    fi
  fi
}

# ============================================================================
# Terminal Title Functions
# ============================================================================

# v0_terminal_supports_title
# Check if terminal supports title setting via OSC escape sequences
# Returns 0 if supported, 1 if not
v0_terminal_supports_title() {
    # Must be a TTY
    [[ -t 1 ]] || return 1

    # Check for known unsupported terminals
    case "${TERM:-}" in
        dumb|"") return 1 ;;
    esac

    return 0
}

# v0_set_terminal_title <title>
# Set terminal window/tab title using OSC 0 escape sequence
# Usage: v0_set_terminal_title "My Title"
# Silently does nothing if terminal doesn't support title setting
v0_set_terminal_title() {
    local title="$1"
    v0_terminal_supports_title || return 0

    # OSC 0 sets both icon name and window title (most compatible)
    # Format: ESC ] 0 ; <title> BEL
    printf '\033]0;%s\007' "${title}"
}
