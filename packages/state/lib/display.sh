#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/display.sh - Status display queries
#
# This module provides:
# - User-friendly status strings
# - Merge display status
# - Active operation checks
#
# External commands: tmux, jq

# Requires: BUILD_DIR to be set (via v0_load_config)
# Requires: sm_read_state from io.sh
# Requires: sm_get_phase from schema.sh
# Requires: sm_get_blocker from blocking.sh

# ============================================================================
# Status Display Helpers
# ============================================================================

# sm_get_display_status <op>
# Return user-friendly status string for an operation
# Format: <status>|<color>|<icon>
sm_get_display_status() {
  local op="$1"
  local phase merge_status held

  phase=$(sm_get_phase "${op}")
  merge_status=$(sm_read_state "${op}" "merge_status")
  held=$(sm_read_state "${op}" "held")

  # Check for hold first
  if [[ "${held}" = "true" ]]; then
    echo "held|yellow|[hold]"
    return
  fi

  case "${phase}" in
    init)
      # Check if planning is active
      local session
      session=$(sm_read_state "${op}" "tmux_session")
      if [[ -n "${session}" ]] && [[ "${session}" != "null" ]] && tmux has-session -t "${session}" 2>/dev/null; then
        echo "new|yellow|[planning]"
      else
        echo "new||"
      fi
      ;;
    planned)
      echo "planned|cyan|"
      ;;
    blocked)
      local after
      after=$(sm_get_blocker "${op}")
      echo "blocked|yellow|[waiting: ${after}]"
      ;;
    queued)
      echo "queued|cyan|"
      ;;
    executing)
      local session
      session=$(sm_read_state "${op}" "tmux_session")
      if [[ -n "${session}" ]] && [[ "${session}" != "null" ]] && tmux has-session -t "${session}" 2>/dev/null; then
        echo "assigned|cyan|[building]"
      else
        echo "assigned|cyan|"
      fi
      ;;
    completed)
      local merge_display
      merge_display=$(sm_get_merge_display_status "${op}")
      echo "completed|green|${merge_display}"
      ;;
    pending_merge)
      local merge_display
      merge_display=$(sm_get_merge_display_status "${op}")
      echo "pending_merge|yellow|${merge_display}"
      ;;
    merged)
      echo "merged|green|[merged]"
      ;;
    conflict)
      echo "conflict|red|== CONFLICT =="
      ;;
    failed)
      echo "failed|red|[error]"
      ;;
    interrupted)
      echo "interrupted|yellow|[interrupted]"
      ;;
    cancelled)
      echo "cancelled|dim|"
      ;;
    *)
      echo "${phase}||"
      ;;
  esac
}

# sm_get_merge_display_status <op>
# Return merge-specific display status
sm_get_merge_display_status() {
  local op="$1"
  local merge_status phase

  phase=$(sm_get_phase "${op}")
  merge_status=$(sm_read_state "${op}" "merge_status")

  # Check if already merged
  if [[ "${phase}" = "merged" ]] || [[ "${merge_status}" = "merged" ]]; then
    echo "[merged]"
    return
  fi

  # Check for conflict
  if [[ "${merge_status}" = "conflict" ]] || [[ "${phase}" = "conflict" ]]; then
    echo "(== CONFLICT ==)"
    return
  fi

  # Check merge queue status
  local queue_file="${BUILD_DIR}/mergeq/queue.json"
  if [[ -f "${queue_file}" ]]; then
    local queue_status
    queue_status=$(jq -r --arg op "${op}" '.entries[] | select(.operation == $op) | .status' "${queue_file}" 2>/dev/null)

    case "${queue_status}" in
      processing)
        echo "(merging...)"
        ;;
      pending)
        echo "(in queue)"
        ;;
      *)
        if [[ "${phase}" = "pending_merge" ]]; then
          echo "(pending merge)"
        fi
        ;;
    esac
  elif [[ "${phase}" = "pending_merge" ]]; then
    echo "(pending merge)"
  fi
}

# sm_is_active_operation <op>
# Check if operation is active (not in terminal state)
sm_is_active_operation() {
  local op="$1"
  local phase
  phase=$(sm_get_phase "${op}")

  # Active: anything not in terminal state
  [[ "${phase}" != "merged" ]] && [[ "${phase}" != "cancelled" ]]
}
