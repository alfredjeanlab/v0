#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Queue display utilities for v0-status
# Source this file to get unified queue display functions

# show_items_indented - Unified function to display items with indentation
# Replaces: show_bugs_indented, show_chores_indented
# Args:
#   $1 = type ("bug" or "chore")
#   $2 = limit (max items to show per section)
#   $3 = label (display label, e.g., "Bugs" or "Chores")
show_items_indented() {
  local type="$1"
  local limit="$2"
  local label="$3"
  local in_progress open

  in_progress=$(wk list --type "${type}" --status in_progress 2>/dev/null || true)
  open=$(wk list --type "${type}" --status todo 2>/dev/null || true)

  if [[ -z "${in_progress}" ]] && [[ -z "${open}" ]]; then
    echo -e "  ${label}: ${C_DIM}none${C_RESET}"
    return
  fi

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

# show_mergeq_indented - Display merge queue with indentation
# Args:
#   $1 = limit (max items to show)
#   $2 = queue_file path (optional, defaults to BUILD_DIR/mergeq/queue.json)
show_mergeq_indented() {
  local limit="$1"
  local queue_file="${2:-${BUILD_DIR}/mergeq/queue.json}"

  if [[ ! -f "${queue_file}" ]]; then
    echo -e "  Merges: ${C_DIM}none${C_RESET}"
    return
  fi

  local entries total
  entries=$(jq -r '.entries[] | select(.status == "pending" or .status == "processing") | "\(.status)\t\(.operation)"' "${queue_file}" 2>/dev/null || true)

  if [[ -z "${entries}" ]]; then
    echo -e "  Merges: ${C_DIM}none${C_RESET}"
  else
    total=$(echo "${entries}" | wc -l | tr -d ' ')

    echo "  Merges:"
    if [[ "${total}" -le "${limit}" ]]; then
      echo "${entries}" | while IFS=$'\t' read -r status op; do
        local status_color="${C_CYAN}"
        [[ "${status}" = "pending" ]] && status_color=""
        printf "    ${status_color}%-12s${C_RESET} %s\n" "[${status}]" "${op}"
      done
    else
      echo "${entries}" | head -n "${limit}" | while IFS=$'\t' read -r status op; do
        local status_color="${C_CYAN}"
        [[ "${status}" = "pending" ]] && status_color=""
        printf "    ${status_color}%-12s${C_RESET} %s\n" "[${status}]" "${op}"
      done
      local remaining=$((total - limit))
      echo -e "    ${C_DIM}... and ${remaining} more in queue${C_RESET}"
    fi
  fi
}

# Convenience wrappers that match the original function signatures
show_bugs_indented() {
  show_items_indented "bug" "$1" "Bugs"
}

show_chores_indented() {
  show_items_indented "chore" "$1" "Chores"
}
