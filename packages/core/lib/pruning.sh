#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Log and queue pruning functions for v0
# Source this file to get cleanup functions

# v0_clean_log_file <log_file>
# Remove ANSI escape sequences from a log file in place
# This cleans terminal color codes, cursor controls, and other escape sequences
# that get captured when using `script` to log tmux session output
v0_clean_log_file() {
  local log_file="$1"
  [[ -z "${log_file}" ]] && return 0
  [[ ! -f "${log_file}" ]] && return 0

  local tmp_file
  tmp_file=$(mktemp)

  # Use perl for comprehensive ANSI/terminal escape sequence removal
  perl -pe '
    s/\e\[[0-9;?]*[A-Za-z]//g;           # CSI sequences (colors, cursor, etc)
    s/\e\][^\a\e]*(?:\a|\e\\)//g;        # OSC sequences (title, etc)
    s/\e\[[\x20-\x3f]*[\x40-\x7e]//g;    # Other CSI
    s/\e[PX^_].*?\e\\//g;                # DCS, SOS, PM, APC sequences
    s/\e.//g;                            # Any remaining ESC+char
  ' "${log_file}" > "${tmp_file}" 2>/dev/null && mv "${tmp_file}" "${log_file}"

  rm -f "${tmp_file}" 2>/dev/null || true
}

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
