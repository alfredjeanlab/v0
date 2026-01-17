#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# nudge-common.sh - Shared functions for the nudge worker daemon
#
# The nudge worker monitors Claude tmux sessions and automatically terminates
# idle sessions that have finished thinking (detected via API stop reasons in
# session logs).

# Ensure V0_DIR is set
V0_DIR="${V0_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# nudge_pid_file - Get the PID file path
# Uses V0_STATE_DIR if available, falls back to current directory
nudge_pid_file() {
  echo "${V0_STATE_DIR:-.}/.nudge.pid"
}

# ============================================================================
# Core Nudge Worker Functions
# ============================================================================

# Check if nudge worker is running
# Returns: 0 if running, 1 if not
nudge_running() {
  local pid_file
  pid_file=$(nudge_pid_file)

  # Check by PID file first (more reliable)
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}" 2>/dev/null)
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi

  # Fallback to pgrep
  pgrep -f "v0-nudge.*daemon" > /dev/null 2>&1
}

# Start nudge worker if not running
# Returns: 0 on success or if already running
ensure_nudge_running() {
  if ! nudge_running; then
    "${V0_DIR}/bin/v0-nudge" start &
  fi
}

# ============================================================================
# Session Discovery Functions
# ============================================================================

# Get all v0 tmux sessions
# Outputs: session names, one per line
get_v0_sessions() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^v0-' || true
}

# Get Claude project directory for a worktree path
# Claude stores session logs in ~/.claude/projects/{encoded-path}/
# where encoded-path is the worktree path with / replaced by -
# Args: $1 = worktree path (absolute)
# Outputs: Claude project directory path
get_claude_project_dir() {
  local worktree_path="$1"

  # Remove leading slash and replace remaining / with -
  local encoded_path
  encoded_path=$(echo "${worktree_path}" | sed 's|^/||; s|/|-|g')

  echo "${HOME}/.claude/projects/-${encoded_path}"
}

# Get the most recent JSONL session file in a Claude project directory
# Args: $1 = project directory
# Outputs: path to most recent .jsonl file, or empty if none
get_latest_session_file() {
  local project_dir="$1"

  [[ ! -d "${project_dir}" ]] && return 1

  # Find most recent .jsonl file by modification time
  # shellcheck disable=SC2012  # ls is fine here, filenames are controlled
  ls -t "${project_dir}"/*.jsonl 2>/dev/null | head -1
}

# ============================================================================
# File Time Functions (cross-platform)
# ============================================================================

# Get file modification time in seconds since epoch
# Args: $1 = file path
# Outputs: timestamp in seconds, or empty on error
get_file_mtime() {
  local file="$1"

  if [[ "$(uname)" = "Darwin" ]]; then
    stat -f %m "${file}" 2>/dev/null
  else
    stat -c %Y "${file}" 2>/dev/null
  fi
}

# Check if file is stale (not modified in N seconds)
# Args: $1 = file path, $2 = threshold seconds (default: 30)
# Returns: 0 if stale (old), 1 if fresh (recent)
is_file_stale() {
  local file="$1"
  local threshold="${2:-30}"

  local mtime now age

  mtime=$(get_file_mtime "${file}") || return 1
  now=$(date +%s)
  age=$((now - mtime))

  [[ ${age} -ge ${threshold} ]]
}

# ============================================================================
# Session State Detection Functions
# ============================================================================

# Parse the last assistant message from JSONL session log
# Returns JSON with stop_reason, has_tool_use fields
# Args: $1 = session file path
# Outputs: JSON object or empty if no state found
get_session_state() {
  local session_file="$1"

  [[ ! -f "${session_file}" ]] && return 1

  # Get last 50 lines and find the final assistant message with stop_reason
  # Streaming creates multiple entries; we want the final one with a non-null stop_reason
  # Use -c for compact output (one JSON object per line)
  tail -50 "${session_file}" 2>/dev/null | jq -c '
    select(.type == "assistant" and .message.stop_reason != null) |
    {
      stop_reason: .message.stop_reason,
      has_tool_use: ([.message.content[]? | select(.type == "tool_use")] | length > 0)
    }
  ' 2>/dev/null | tail -1
}

# Check if session appears to have an API error
# Args: $1 = session file path
# Returns: 0 if error detected, 1 if no error
check_for_api_error() {
  local session_file="$1"

  [[ ! -f "${session_file}" ]] && return 1

  # Look for error patterns in recent entries
  # HTTP codes: 401/403 (auth), 429 (rate limit), 500/529 (server error)
  tail -20 "${session_file}" 2>/dev/null | grep -qE '"error"|"status":\s*(401|403|429|500|529)'
}

# Determine if session is idle and done
# Args: $1 = session file path
# Returns: 0 if done (should terminate), 1 if still active, 2 if error state
is_session_done() {
  local session_file="$1"

  local state stop_reason has_tool_use

  state=$(get_session_state "${session_file}") || state=""
  [[ -z "${state}" ]] && return 1  # No state found, assume still active

  stop_reason=$(echo "${state}" | jq -r '.stop_reason // empty')
  has_tool_use=$(echo "${state}" | jq -r '.has_tool_use // false')

  # Check for error cases first
  if check_for_api_error "${session_file}"; then
    return 2  # Error state
  fi

  case "${stop_reason}" in
    end_turn)
      # Done if not waiting for tool calls
      if [[ "${has_tool_use}" = "true" ]]; then
        return 1  # Waiting for tool execution
      fi
      return 0  # Finished
      ;;
    tool_use)
      return 1  # Explicitly waiting for tool
      ;;
    max_tokens|refusal|model_context_window_exceeded)
      return 2  # Error case
      ;;
    pause_turn)
      return 1  # Paused (e.g., web search), not done
      ;;
    *)
      return 1  # Unknown, assume active
      ;;
  esac
}

# ============================================================================
# Session-to-Worktree Mapping Functions
# ============================================================================

# Find worktree for a tmux session by searching state files
# Args: $1 = session name
# Outputs: worktree path if found
# Returns: 0 if found, 1 if not found
find_session_worktree() {
  local session="$1"

  # Search in all project state directories
  for state_root in "${HOME}/.local/state/v0"/*; do
    [[ ! -d "${state_root}" ]] && continue

    # Check tree directories for matching session via .tmux-session file
    for tree_dir in "${state_root}/tree"/*; do
      [[ ! -d "${tree_dir}" ]] && continue

      if [[ -f "${tree_dir}/.tmux-session" ]]; then
        local stored_session
        stored_session=$(cat "${tree_dir}/.tmux-session" 2>/dev/null)
        if [[ "${stored_session}" = "${session}" ]]; then
          echo "${tree_dir}"
          return 0
        fi
      fi
    done

    # Also check operations state for feature sessions
    local build_dir="${state_root}/../.v0/build"
    if [[ -d "${build_dir}/operations" ]]; then
      for op_dir in "${build_dir}/operations"/*; do
        [[ ! -f "${op_dir}/state.json" ]] && continue

        local tmux_session tree
        tmux_session=$(jq -r '.tmux_session // empty' "${op_dir}/state.json" 2>/dev/null)
        if [[ "${tmux_session}" = "${session}" ]]; then
          tree=$(jq -r '.worktree // empty' "${op_dir}/state.json" 2>/dev/null)
          if [[ -n "${tree}" ]] && [[ -d "${tree}" ]]; then
            # Return the parent of worktree (the tree_dir)
            dirname "${tree}"
            return 0
          fi
        fi
      done
    fi
  done

  return 1
}

# Write the current tmux session name to the tree directory
# Call this when creating a session to enable reverse lookup
# Args: $1 = tree_dir, $2 = session_name
write_session_marker() {
  local tree_dir="$1"
  local session_name="$2"

  [[ -d "${tree_dir}" ]] || return 1
  echo "${session_name}" > "${tree_dir}/.tmux-session"
}
