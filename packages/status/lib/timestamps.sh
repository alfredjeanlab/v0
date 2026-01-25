#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Timestamp display utilities for v0-status
# Source this file to get timestamp formatting functions

# Convert ISO 8601 timestamp to epoch (macOS compatible)
# Note: Timestamps with Z suffix are UTC, so we parse in UTC timezone
timestamp_to_epoch() {
  local ts="$1"
  local formatted
  formatted=$(echo "${ts}" | sed 's/T/ /; s/Z$//; s/\.[0-9]*//')
  TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "${formatted}" +%s 2>/dev/null
}

# Format elapsed time as human-readable string
format_elapsed() {
  local seconds="$1"
  if [[ "${seconds}" -lt 60 ]]; then
    echo "just now"
  elif [[ "${seconds}" -lt 3600 ]]; then
    local mins=$((seconds / 60))
    echo "${mins} min ago"
  elif [[ "${seconds}" -lt 86400 ]]; then
    local hours=$((seconds / 3600))
    echo "${hours} hr ago"
  else
    local days=$((seconds / 86400))
    echo "${days} day ago"
  fi
}

# Format operation timestamp for display
# Shows relative time for recent operations (< 12 hours), date for older ones
# Args: $1 = ISO 8601 timestamp (UTC with Z suffix)
#       $2 = (optional) cached now_epoch to avoid repeated date calls
format_operation_time() {
  local ts="$1"
  local now_epoch="${2:-$(date +%s)}"  # Use cached if provided
  local ts_epoch elapsed

  ts_epoch=$(timestamp_to_epoch "${ts}")
  if [[ -z "${ts_epoch}" ]]; then
    # Fallback: return first 10 chars (YYYY-MM-DD) if parsing fails
    echo "${ts:0:10}"
    return
  fi

  elapsed=$((now_epoch - ts_epoch))

  # 12 hours = 43200 seconds
  if [[ "${elapsed}" -lt 43200 ]]; then
    format_elapsed "${elapsed}"
  else
    # Convert UTC timestamp to local date
    # Use the epoch value to get local date
    date -r "${ts_epoch}" +%Y-%m-%d 2>/dev/null || echo "${ts:0:10}"
  fi
}

# Format epoch timestamp for display (Phase 2 optimization)
# Shows relative time for recent operations (< 12 hours), date for older ones
# Args: $1 = epoch timestamp, $2 = current epoch (now_epoch)
format_epoch_time() {
  local ts_epoch="$1"
  local now_epoch="$2"

  if [[ -z "${ts_epoch}" ]] || [[ "${ts_epoch}" -eq 0 ]]; then
    echo "unknown"
    return
  fi

  local elapsed=$((now_epoch - ts_epoch))

  # 12 hours = 43200 seconds
  if [[ "${elapsed}" -lt 43200 ]]; then
    format_elapsed "${elapsed}"
  else
    # Convert epoch to local date
    date -r "${ts_epoch}" +%Y-%m-%d 2>/dev/null || echo "unknown"
  fi
}

# Get the most relevant timestamp for display based on current state
# Arguments: phase, created_at, completed_at, merged_at, held_at
# Output: The most appropriate timestamp for display
get_last_updated_timestamp() {
  local phase="$1"
  local created_at="$2"
  local completed_at="$3"
  local merged_at="$4"
  local held_at="$5"

  case "${phase}" in
    merged)
      # Prefer merged_at, fall back to completed_at, then created_at
      if [[ -n "${merged_at}" && "${merged_at}" != "null" ]]; then
        echo "${merged_at}"
      elif [[ -n "${completed_at}" && "${completed_at}" != "null" ]]; then
        echo "${completed_at}"
      else
        echo "${created_at}"
      fi
      ;;
    completed|pending_merge)
      # Show when it was completed
      if [[ -n "${completed_at}" && "${completed_at}" != "null" ]]; then
        echo "${completed_at}"
      else
        echo "${created_at}"
      fi
      ;;
    held)
      # Show when it was put on hold
      if [[ -n "${held_at}" && "${held_at}" != "null" ]]; then
        echo "${held_at}"
      else
        echo "${created_at}"
      fi
      ;;
    *)
      # For init, planned, queued, executing, etc. - use created_at
      echo "${created_at}"
      ;;
  esac
}

# Get the most relevant epoch for display based on current state (Phase 2 optimization)
# Arguments: phase, created_epoch, completed_epoch, merged_epoch, held_epoch
# Output: The most appropriate epoch timestamp for display
get_last_updated_epoch() {
  local phase="$1"
  local created_epoch="$2"
  local completed_epoch="$3"
  local merged_epoch="$4"
  local held_epoch="$5"

  case "${phase}" in
    merged)
      # Prefer merged_epoch, fall back to completed_epoch, then created_epoch
      if [[ -n "${merged_epoch}" ]] && [[ "${merged_epoch}" -gt 0 ]]; then
        echo "${merged_epoch}"
      elif [[ -n "${completed_epoch}" ]] && [[ "${completed_epoch}" -gt 0 ]]; then
        echo "${completed_epoch}"
      else
        echo "${created_epoch}"
      fi
      ;;
    completed|pending_merge)
      # Show when it was completed
      if [[ -n "${completed_epoch}" ]] && [[ "${completed_epoch}" -gt 0 ]]; then
        echo "${completed_epoch}"
      else
        echo "${created_epoch}"
      fi
      ;;
    held)
      # Show when it was put on hold
      if [[ -n "${held_epoch}" ]] && [[ "${held_epoch}" -gt 0 ]]; then
        echo "${held_epoch}"
      else
        echo "${created_epoch}"
      fi
      ;;
    *)
      # For init, planned, queued, executing, etc. - use created_epoch
      echo "${created_epoch}"
      ;;
  esac
}
