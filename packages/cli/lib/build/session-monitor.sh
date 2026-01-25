#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Session monitoring utilities for v0-feature
# Source this file to get session monitoring functions

# monitor_plan_session <session> <exit_file> <plan_locations> <idle_event>
# Monitor a tmux session for plan file creation and idle completion
# Args:
#   $1 = session name
#   $2 = exit file path (signals session complete)
#   $3 = colon-separated list of plan file locations to check
#   $4 = idle event name (e.g., "plan:idle_complete")
# Output: Sets global FOUND_FILE to the found plan file path, or empty if not found
# Returns: 0 if completed normally, 1 if error
monitor_plan_session() {
  local session="$1"
  local exit_file="$2"
  local plan_locations="$3"
  local idle_event="$4"

  local idle_count=0
  local idle_threshold=6
  local last_mtime=""
  FOUND_FILE=""

  while tmux has-session -t "${session}" 2>/dev/null; do
    if [[ -f "${exit_file}" ]]; then
      tmux kill-session -t "${session}" 2>/dev/null || true
      break
    fi
    sleep 2

    # Find which plan file exists for mtime check
    local plan_file=""
    IFS=':' read -ra locations <<< "${plan_locations}"
    for loc in "${locations[@]}"; do
      if [[ -f "${loc}" ]]; then
        plan_file="${loc}"
        break
      fi
    done

    if [[ -n "${plan_file}" ]]; then
      local current_mtime
      current_mtime=$(stat -f %m "${plan_file}" 2>/dev/null || stat -c %Y "${plan_file}" 2>/dev/null || echo "0")
      if [[ "${current_mtime}" = "${last_mtime}" ]]; then
        idle_count=$((idle_count + 1))
        if [[ ${idle_count} -ge ${idle_threshold} ]]; then
          emit_event "${idle_event}" "Plan file exists and agent idle, terminating session"
          tmux kill-session -t "${session}" 2>/dev/null || true
          echo "0" > "${exit_file}"
          break
        fi
      else
        idle_count=0
      fi
      last_mtime="${current_mtime}"
      FOUND_FILE="${plan_file}"
    fi
  done
}

# monitor_decompose_session <session> <exit_file> <plan_file> <pattern> <idle_event>
# Monitor a tmux session for feature ID pattern and idle completion
# Args:
#   $1 = session name
#   $2 = exit file path (signals session complete)
#   $3 = plan file path
#   $4 = issue pattern regex (from v0_issue_pattern)
#   $5 = idle event name (e.g., "feature:idle_complete")
# Returns: 0 if completed normally, 1 if error
monitor_decompose_session() {
  local session="$1"
  local exit_file="$2"
  local plan_file="$3"
  local pattern="$4"
  local idle_event="$5"

  local idle_count=0
  local idle_threshold=6
  local last_mtime=""
  local mtime_before
  mtime_before=$(stat -f %m "${plan_file}" 2>/dev/null || stat -c %Y "${plan_file}" 2>/dev/null)

  local plan_has_feature=""
  grep -qE "\`${pattern}\`" "${plan_file}" 2>/dev/null && plan_has_feature=1

  while tmux has-session -t "${session}" 2>/dev/null; do
    if [[ -f "${exit_file}" ]]; then
      tmux kill-session -t "${session}" 2>/dev/null || true
      break
    fi
    sleep 2

    local mtime_now
    mtime_now=$(stat -f %m "${plan_file}" 2>/dev/null || stat -c %Y "${plan_file}" 2>/dev/null)

    if [[ "${mtime_now}" != "${mtime_before}" ]] || [[ -n "${plan_has_feature}" ]]; then
      if grep -qE "\`${pattern}\`" "${plan_file}" 2>/dev/null; then
        local current_mtime
        current_mtime=$(stat -f %m "${plan_file}" 2>/dev/null || stat -c %Y "${plan_file}" 2>/dev/null || echo "0")
        if [[ "${current_mtime}" = "${last_mtime}" ]]; then
          idle_count=$((idle_count + 1))
          if [[ ${idle_count} -ge ${idle_threshold} ]]; then
            emit_event "${idle_event}" "Plan has feature ID and agent idle, terminating session"
            tmux kill-session -t "${session}" 2>/dev/null || true
            echo "0" > "${exit_file}"
            break
          fi
        else
          idle_count=0
        fi
        last_mtime="${current_mtime}"
      fi
    fi
  done
}

# get_session_exit_code <exit_file>
# Read and clean up exit file, return exit code
# Args:
#   $1 = exit file path
# Output: exit code (0-255) or 1 if file not found
# Side effect: removes exit file if it exists
get_session_exit_code() {
  local exit_file="$1"

  if [[ -f "${exit_file}" ]]; then
    local exit_code
    exit_code=$(cat "${exit_file}")
    rm -f "${exit_file}"
    echo "${exit_code}"
  else
    echo "1"
  fi
}
