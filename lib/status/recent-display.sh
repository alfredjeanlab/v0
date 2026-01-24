#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Recently completed display utilities for v0-status
# Source this file to get recently completed display functions
# Depends on: lib/status/timestamps.sh (timestamp_to_epoch, format_elapsed)

# Get recently merged operations (features/builds)
# Args: $1 = hours to look back (default: 72)
# Output: name|merged_at (one per line, sorted most recent first)
get_merged_operations() {
  local since_hours="${1:-72}"
  local cutoff_time
  cutoff_time=$(date -v-"${since_hours}"H +%s 2>/dev/null || date -d "${since_hours} hours ago" +%s 2>/dev/null || echo 0)

  if [[ ! -d "${BUILD_DIR}/operations" ]]; then
    return
  fi

  # Phase 4 optimization: Single jq -s for all files instead of N separate calls
  # Use compgen to check for glob matches (bash 3.2 compatible)
  if compgen -G "${BUILD_DIR}/operations/*/state.json" > /dev/null 2>&1; then
    jq -rs '.[] | select(.merge_status == "merged" and .merged_at != null) | "\(.name)|\(.merged_at)"' \
      "${BUILD_DIR}"/operations/*/state.json 2>/dev/null | while IFS='|' read -r name merged_at; do
      [[ -z "${name}" ]] && continue
      # Timestamp filtering still in bash (macOS date compatibility)
      local merged_epoch
      merged_epoch=$(timestamp_to_epoch "${merged_at}")
      if [[ -n "${merged_epoch}" ]] && [[ "${merged_epoch}" -ge "${cutoff_time}" ]]; then
        echo "${name}|${merged_at}"
      fi
    done | sort -t'|' -k2 -r
  fi
}

# Get recently completed bugs
# Args: $1 = hours to look back (default: 72), $2 = max results (optional)
# Output: id|title|updated_at (one per line, filtered by recency)
get_completed_bugs() {
  local since_hours="${1:-72}"
  local limit="${2:-}"

  local json_output limit_arg=""
  [[ -n "${limit}" ]] && limit_arg="--limit ${limit}"
  # Use wk list filter to efficiently get only recently updated bugs
  json_output=$(wk list --type bug --status "done" --output json -q "updated < ${since_hours}h" ${limit_arg:+"${limit_arg}"} 2>/dev/null) || return
  [[ -z "${json_output}" ]] && return

  # wk list --format json doesn't include updated_at, so we fetch from wk show for display
  echo "${json_output}" | jq -r '.issues[] | .id' 2>/dev/null | while read -r id; do
    [[ -z "${id}" ]] && continue
    local issue_json title updated_at _fields
    issue_json=$(wk show "${id}" --output json 2>/dev/null) || continue
    # Batch read title and updated_at in single jq call
    _fields=$(echo "${issue_json}" | jq -r '[.title // .summary // "Untitled", .updated_at // .closed_at // ""] | join("|")' 2>/dev/null)
    IFS='|' read -r title updated_at <<< "${_fields}"
    echo "${id}|${title}|${updated_at}"
  done
}

# Get recently completed chores
# Args: $1 = hours to look back (default: 72), $2 = max results (optional)
# Output: id|title|updated_at (one per line, filtered by recency)
get_completed_chores() {
  local since_hours="${1:-72}"
  local limit="${2:-}"

  local json_output limit_arg=""
  [[ -n "${limit}" ]] && limit_arg="--limit ${limit}"
  # Use wk list filter to efficiently get only recently updated chores
  json_output=$(wk list --type chore --status "done" --output json -q "updated < ${since_hours}h" ${limit_arg:+"${limit_arg}"} 2>/dev/null) || return
  [[ -z "${json_output}" ]] && return

  # wk list --format json doesn't include updated_at, so we fetch from wk show for display
  echo "${json_output}" | jq -r '.issues[] | .id' 2>/dev/null | while read -r id; do
    [[ -z "${id}" ]] && continue
    local issue_json title updated_at _fields
    issue_json=$(wk show "${id}" --output json 2>/dev/null) || continue
    # Batch read title and updated_at in single jq call
    _fields=$(echo "${issue_json}" | jq -r '[.title // .summary // "Untitled", .updated_at // .closed_at // ""] | join("|")' 2>/dev/null)
    IFS='|' read -r title updated_at <<< "${_fields}"
    echo "${id}|${title}|${updated_at}"
  done
}

# Helper: Format completed item for display
# Args: $1 = id, $2 = title, $3 = updated_at
# Output: formatted line to stdout
_format_completed_item() {
  local id="$1"
  local title="$2"
  local updated_at="$3"

  local display_title="${title:0:50}"
  [[ ${#title} -gt 50 ]] && display_title="${display_title}..."

  if [[ -n "${updated_at}" ]]; then
    local now_epoch updated_epoch elapsed_sec elapsed
    now_epoch=$(date +%s)
    updated_epoch=$(timestamp_to_epoch "${updated_at}")
    if [[ -n "${updated_epoch}" ]] && [[ "${updated_epoch}" -gt 0 ]]; then
      elapsed_sec=$((now_epoch - updated_epoch))
      elapsed=$(format_elapsed "${elapsed_sec}")
      echo "    - ${id}: ${display_title} (${elapsed})"
    else
      echo "    - ${id}: ${display_title}"
    fi
  else
    echo "    - ${id}: ${display_title}"
  fi
}

# Show recently completed section in status output
# Args: $1 = max items per category (default: 5)
show_recently_completed() {
  local max_items="${1:-5}"
  local completed_bugs completed_chores

  # Fetch data first to check if there's anything to show
  completed_bugs=$(get_completed_bugs 72 $((max_items + 1)))
  completed_chores=$(get_completed_chores 72 $((max_items + 1)))

  # If nothing to show, omit the entire section
  if [[ -z "${completed_bugs}" ]] && [[ -z "${completed_chores}" ]]; then
    return
  fi

  echo ""
  echo "Recently Completed:"

  # Show completed bugs
  if [[ -n "${completed_bugs}" ]]; then
    echo "  Bugs:"
    echo "${completed_bugs}" | head -n "${max_items}" | while IFS='|' read -r id title updated_at; do
      _format_completed_item "${id}" "${title}" "${updated_at}"
    done
    local total
    total=$(echo "${completed_bugs}" | wc -l | tr -d ' ')
    if [[ "${total}" -gt "${max_items}" ]]; then
      echo "    ... and more"
    fi
  fi

  # Show completed chores
  if [[ -n "${completed_chores}" ]]; then
    echo "  Chores:"
    echo "${completed_chores}" | head -n "${max_items}" | while IFS='|' read -r id title updated_at; do
      _format_completed_item "${id}" "${title}" "${updated_at}"
    done
    local total
    total=$(echo "${completed_chores}" | wc -l | tr -d ' ')
    if [[ "${total}" -gt "${max_items}" ]]; then
      echo "    ... and more"
    fi
  fi
}
