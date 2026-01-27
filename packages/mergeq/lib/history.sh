#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/history.sh - History query functions for merge queue
#
# Depends on: io.sh (for queue file access), rules.sh (for status constants)
# IMPURE: Uses jq

# Expected environment variables:
# MERGEQ_DIR - Directory for merge queue state
# QUEUE_FILE - Path to queue.json file

# mq_list_history <limit>
# List completed merge queue entries
# Returns TSV: operation<TAB>status<TAB>updated_at<TAB>issue_id
# Terminal statuses: completed, failed, conflict
mq_list_history() {
  local limit="${1:-10}"

  [[ ! -f "${QUEUE_FILE}" ]] && return 0

  # Extract terminal entries, sort by updated_at descending
  jq -r '
    .entries
    | map(select(.status == "completed" or .status == "failed" or .status == "conflict"))
    | sort_by(.updated_at) | reverse
    | .[]
    | [.operation, .status, .updated_at, .issue_id // ""] | @tsv
  ' "${QUEUE_FILE}" 2>/dev/null | head -n "${limit}"
}

# mq_show_history <limit>
# Display formatted merge queue history
# Used by: v0 mergeq --history
mq_show_history() {
  local limit="${1:-10}"
  local entries
  entries=$(mq_list_history "${limit}")

  if [[ -z "${entries}" ]]; then
    echo "No completed merges"
    return 0
  fi

  echo "Completed Merges:"
  echo ""

  while IFS=$'\t' read -r op status updated_at issue_id; do
    local date_str
    date_str=$(format_timestamp "${updated_at}")
    local status_icon=""
    case "${status}" in
      completed) status_icon="+" ;;
      failed)    status_icon="x" ;;
      conflict)  status_icon="!" ;;
    esac
    printf "%-20s %s (%s)\n" "${op}" "${status_icon}" "${date_str}"
  done <<< "${entries}"
}
