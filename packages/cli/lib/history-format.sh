#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# history-format.sh - Shared timestamp formatting for history commands
#
# This module provides common formatting functions used by:
# - v0 chore --history
# - v0 fix --history
# - v0 mergeq --history
# - v0 log

# format_timestamp <iso_timestamp>
# Format ISO timestamp for display
# Today: relative (just now, 5 mins ago, 2 hrs ago)
# Other: date only (2026-01-24)
format_timestamp() {
  local iso_timestamp="$1"
  local today now_epoch ts_epoch diff_secs

  # Handle empty input
  [[ -z "${iso_timestamp}" ]] && { echo "unknown"; return; }

  # Get today's date
  today=$(date +%Y-%m-%d)

  # Extract date portion from timestamp
  local ts_date
  ts_date=$(echo "${iso_timestamp}" | cut -dT -f1)

  if [[ "${ts_date}" = "${today}" ]]; then
    # Today - show relative time
    now_epoch=$(date +%s)
    # Parse ISO timestamp to epoch (handle both with and without Z suffix)
    local clean_ts
    clean_ts="${iso_timestamp%Z}"
    ts_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${clean_ts}" +%s 2>/dev/null || date -d "${iso_timestamp}" +%s 2>/dev/null)

    if [[ -z "${ts_epoch}" ]]; then
      echo "${ts_date}"
      return
    fi

    diff_secs=$((now_epoch - ts_epoch))

    if [[ "${diff_secs}" -lt 60 ]]; then
      echo "just now"
    elif [[ "${diff_secs}" -lt 3600 ]]; then
      local mins=$((diff_secs / 60))
      if [[ "${mins}" -eq 1 ]]; then
        echo "1 min ago"
      else
        echo "${mins} mins ago"
      fi
    else
      local hrs=$((diff_secs / 3600))
      if [[ "${hrs}" -eq 1 ]]; then
        echo "1 hr ago"
      else
        echo "${hrs} hrs ago"
      fi
    fi
  else
    # Not today - show date
    echo "${ts_date}"
  fi
}

# get_chore_history_raw <limit>
# Get raw chore history as TSV: id<TAB>timestamp<TAB>message
# Used by v0 log to aggregate and sort history from multiple sources
get_chore_history_raw() {
  local limit="${1:-10}"
  local chores
  chores=$(wk list --type chore --status "done" 2>/dev/null || true)

  [[ -z "${chores}" ]] && return 0

  local count=0
  while IFS= read -r line; do
    [[ "${count}" -ge "${limit}" ]] && break

    local id
    # Extract issue ID - match any prefix-hexid format
    id=$(echo "${line}" | v0_grep_extract '[a-zA-Z0-9]+-[a-f0-9]+' | head -1)
    [[ -z "${id}" ]] && continue

    local state_file="${BUILD_DIR}/chore/${id}/state.json"
    if [[ -f "${state_file}" ]]; then
      local pushed_at commit_msg
      pushed_at=$(v0_grep_extract '"pushed_at": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      commit_msg=$(v0_grep_extract '"commit_message": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      [[ -n "${pushed_at}" ]] && printf "%s\t%s\t%s\n" "${id}" "${pushed_at}" "${commit_msg}"
    fi

    count=$((count + 1))
  done <<< "${chores}"
}

# get_fix_history_raw <limit>
# Get raw fix history as TSV: id<TAB>timestamp<TAB>message
# Used by v0 log to aggregate and sort history from multiple sources
get_fix_history_raw() {
  local limit="${1:-10}"
  local bugs
  bugs=$(wk list --type bug --status "done" 2>/dev/null || true)

  [[ -z "${bugs}" ]] && return 0

  local count=0
  while IFS= read -r line; do
    [[ "${count}" -ge "${limit}" ]] && break

    local id
    id=$(echo "${line}" | v0_grep_extract "$(v0_issue_pattern)" | head -1)
    [[ -z "${id}" ]] && continue

    local state_file="${BUILD_DIR}/fix/${id}/state.json"
    if [[ -f "${state_file}" ]]; then
      local pushed_at commit_msg
      pushed_at=$(v0_grep_extract '"pushed_at": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      commit_msg=$(v0_grep_extract '"commit_message": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      [[ -n "${pushed_at}" ]] && printf "%s\t%s\t%s\n" "${id}" "${pushed_at}" "${commit_msg}"
    fi

    count=$((count + 1))
  done <<< "${bugs}"
}
