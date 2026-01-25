#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Worker status display utilities for v0-status
# Source this file to get worker status functions

# Source grep wrapper for better performance (if not already sourced)
if [[ -z "${_V0_GREP_CMD:-}" ]]; then
  _STATUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${_STATUS_LIB_DIR}/../../core/lib/grep.sh"
fi

# get_worker_status <type> [all_sessions] [all_polling]
# Determine worker status using batched session/polling data
# Args:
#   $1 = worker type ("fix" or "chore")
#   $2 = (optional) all_sessions from tmux list-sessions
#   $3 = (optional) all_polling from pgrep
# Output: "running" | "polling" | "stopped"
get_worker_status() {
  local type="$1"
  local all_sessions="${2:-}"
  local all_polling="${3:-}"
  local session="v0-${PROJECT}-worker-${type}"
  local polling_log="/tmp/v0-${PROJECT}-${type}-polling.log"

  # Check if session is running
  if [[ -n "${all_sessions}" ]]; then
    # Use pre-batched session list
    if [[ "${all_sessions}" == *"${session}"* ]]; then
      echo "running"
      return
    fi
  else
    # Direct check
    if tmux has-session -t "${session}" 2>/dev/null; then
      echo "running"
      return
    fi
  fi

  # Check if polling daemon is running
  if [[ -f "${polling_log}" ]]; then
    local polling_pid=""
    if [[ -n "${all_polling}" ]]; then
      # Use pre-batched polling list
      polling_pid=$(echo "${all_polling}" | v0_grep "worker-${type}" | awk '{print $1}')
    else
      # Direct check
      polling_pid=$(pgrep -f "while true.*${session}" 2>/dev/null || true)
    fi
    if [[ -n "${polling_pid}" ]]; then
      echo "polling"
      return
    fi
  fi

  echo "stopped"
}

# get_worker_polling_pid <type> [all_polling]
# Get the polling daemon PID for a worker
# Args:
#   $1 = worker type ("fix" or "chore")
#   $2 = (optional) all_polling from pgrep
# Output: PID or empty string
get_worker_polling_pid() {
  local type="$1"
  local all_polling="${2:-}"
  local session="v0-${PROJECT}-worker-${type}"
  local polling_log="/tmp/v0-${PROJECT}-${type}-polling.log"

  if [[ ! -f "${polling_log}" ]]; then
    return
  fi

  if [[ -n "${all_polling}" ]]; then
    echo "${all_polling}" | v0_grep "worker-${type}" | awk '{print $1}'
  else
    pgrep -f "while true.*${session}" 2>/dev/null || true
  fi
}

# show_worker_header_verbose <type> <status> [polling_pid]
# Display worker status header with session info and attach hint
# For use in --fix/--chore standalone handlers
# Args:
#   $1 = worker type ("fix" or "chore")
#   $2 = status from get_worker_status
#   $3 = (optional) polling PID
show_worker_header_verbose() {
  local type="$1"
  local status="$2"
  local polling_pid="${3:-}"
  local session="v0-${PROJECT}-worker-${type}"
  local label
  case "${type}" in
    fix) label="Fix Worker" ;;
    chore) label="Chore Worker" ;;
    *) label="${type^} Worker" ;;
  esac

  case "${status}" in
    running)
      echo -e "${label}: ${C_CYAN}Active${C_RESET} ${C_DIM}[tmux: ${session}] Attach with: v0 attach ${type}${C_RESET}"
      ;;
    polling)
      echo -e "${label}: ${C_YELLOW}Polling${C_RESET} ${C_DIM}[pid: ${polling_pid}]${C_RESET}"
      ;;
    stopped)
      echo -e "${label}: ${C_DIM}Stopped${C_RESET}"
      ;;
  esac
}

# show_worker_header_compact <type> <status> <queue_empty>
# Display compact worker status for default list view
# Args:
#   $1 = worker type label ("Bugs" or "Chores")
#   $2 = status from get_worker_status
#   $3 = "true" if queue is empty, "false" otherwise
show_worker_header_compact() {
  local label="$1"
  local status="$2"
  local queue_empty="$3"

  case "${status}" in
    running)
      echo -e "${label}: ${C_CYAN}Active${C_RESET}"
      ;;
    polling)
      echo -e "${label}: ${C_YELLOW}Polling${C_RESET}"
      ;;
    stopped)
      if [[ "${queue_empty}" = "true" ]]; then
        echo -e "${label}: ${C_DIM}None${C_RESET}"
      else
        echo -e "${label}: ${C_RED}Stopped${C_RESET}"
      fi
      ;;
  esac
}

# show_worker_items_inline <in_progress> <open> [limit]
# Display worker items inline (for use in default list section)
# Uses pre-fetched data instead of calling wk list
# Args:
#   $1 = in_progress items (newline separated)
#   $2 = open items (newline separated)
#   $3 = (optional) max items per section (default: 3)
show_worker_items_inline() {
  local in_progress="$1"
  local open="$2"
  local limit="${3:-3}"

  if [[ -n "${in_progress}" ]]; then
    local count
    count=$(echo "${in_progress}" | wc -l | tr -d ' ')
    echo -e "  ${C_DIM}In progress:${C_RESET}"
    if [[ "${count}" -le "${limit}" ]]; then
      echo "${in_progress}" | sed 's/^/    /'
    else
      echo "${in_progress}" | head -n "${limit}" | sed 's/^/    /'
      local remaining=$((count - limit))
      echo -e "    ${C_DIM}... and ${remaining} more${C_RESET}"
    fi
  fi

  if [[ -n "${open}" ]]; then
    local count
    count=$(echo "${open}" | wc -l | tr -d ' ')
    echo -e "  ${C_DIM}Queued:${C_RESET}"
    if [[ "${count}" -le "${limit}" ]]; then
      echo "${open}" | sed 's/^/    /'
    else
      echo "${open}" | head -n "${limit}" | sed 's/^/    /'
      local remaining=$((count - limit))
      echo -e "    ${C_DIM}... and ${remaining} more${C_RESET}"
    fi
  fi
}

# show_standalone_worker_status <type>
# Complete standalone worker status view (for --fix/--chore handlers)
# Args:
#   $1 = worker type ("fix" or "chore")
show_standalone_worker_status() {
  local type="$1"
  local issue_type label none_msg
  case "${type}" in
    fix) issue_type="bug"; label="Fix Worker"; none_msg="No bugs available" ;;
    chore) issue_type="chore"; label="Chore Worker"; none_msg="No chores available" ;;
  esac

  local status polling_pid
  status=$(get_worker_status "${type}")
  polling_pid=$(get_worker_polling_pid "${type}")

  show_worker_header_verbose "${type}" "${status}" "${polling_pid}"

  local in_progress open
  in_progress=$(wk list --type "${issue_type}" --status in_progress 2>/dev/null || true)
  open=$(wk list --type "${issue_type}" --status todo 2>/dev/null || true)

  if [[ -z "${in_progress}" ]] && [[ -z "${open}" ]]; then
    echo ""
    echo "${none_msg}"
  else
    echo ""
    show_worker_items_inline "${in_progress}" "${open}" 3
  fi
}
