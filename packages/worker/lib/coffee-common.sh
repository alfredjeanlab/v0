#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# coffee-common.sh - Coffee (caffeinate) management functions for v0

# coffee_pid_file - Get the PID file path
# Uses V0_STATE_DIR if available, falls back to .v0
coffee_pid_file() {
  echo "${V0_STATE_DIR:-.v0}/.coffee.pid"
}

# coffee_is_running - Check if coffee (caffeinate) process is running
# Returns: 0 if running, 1 if not
coffee_is_running() {
  local pid_file
  pid_file=$(coffee_pid_file)
  [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null
}

# coffee_start - Start coffee (caffeinate) in background
# Args: $1 = hours (default: 2), $2 = additional caffeinate options
# Returns: 0 on success
coffee_start() {
  local hours="${1:-2}"
  local opts="${2:-}"

  if coffee_is_running; then
    return 0
  fi

  # Ensure state directory exists
  local pid_file
  pid_file=$(coffee_pid_file)
  local pid_dir
  pid_dir=$(dirname "${pid_file}")
  mkdir -p "${pid_dir}"

  # Convert hours to seconds using bc for decimal support
  local seconds
  seconds=$(echo "${hours} * 3600" | bc | cut -d'.' -f1)

  # Start caffeinate in background
  # -i: prevent idle sleep (always)
  # Redirect FDs so BATS (and other test runners) don't wait for process to finish
  caffeinate -i ${opts} -t "${seconds}" </dev/null >/dev/null 2>&1 &
  local pid=$!
  echo "${pid}" > "${pid_file}"
}

# coffee_stop - Stop coffee (caffeinate) process
# Returns: 0 on success
coffee_stop() {
  local pid_file
  pid_file=$(coffee_pid_file)
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}")
    kill "${pid}" 2>/dev/null || true
    rm -f "${pid_file}"
  fi
}

# coffee_status - Get coffee status
# Returns: 0 if running, 1 if stopped
# Output: "running:<pid>" or "stopped"
coffee_status() {
  local pid_file
  pid_file=$(coffee_pid_file)
  if coffee_is_running; then
    echo "running:$(cat "${pid_file}")"
    return 0
  else
    echo "stopped"
    return 1
  fi
}

# coffee_pid - Get coffee PID if running
# Returns: 0 if running (outputs PID), 1 if not
coffee_pid() {
  local pid_file
  pid_file=$(coffee_pid_file)
  if coffee_is_running; then
    cat "${pid_file}"
    return 0
  fi
  return 1
}
