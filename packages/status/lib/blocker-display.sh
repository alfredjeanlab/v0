#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# blocker-display.sh - Optimized blocker display for v0 status

# _status_get_blocker_display <epic_id>
# Get display string for first open blocker
# Optimized: single wk call per operation, cached lookups for op names
# Output: "op_name" or "issue_id" or empty
_status_get_blocker_display() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return

  # Single wk call to get blockers
  local issue_json
  issue_json=$(wk show "${epic_id}" -o json 2>/dev/null) || return

  local blockers
  blockers=$(echo "${issue_json}" | jq -r '.blockers // []')
  [[ "${blockers}" == "[]" ]] && return

  # Check each blocker until we find an open one
  local blocker_id
  for blocker_id in $(echo "${blockers}" | jq -r '.[]'); do
    local blocker_json
    blocker_json=$(wk show "${blocker_id}" -o json 2>/dev/null) || {
      # wk failed, assume blocker is open
      echo "${blocker_id}"
      return
    }

    local status
    status=$(echo "${blocker_json}" | jq -r '.status // "unknown"')
    case "${status}" in
      done|closed)
        # This blocker is resolved, check next
        continue
        ;;
    esac

    # Found an open blocker - resolve to op name and return
    local plan_label
    plan_label=$(echo "${blocker_json}" | jq -r '.labels // [] | .[] | select(startswith("plan:"))' | head -1)

    if [[ -n "${plan_label}" ]]; then
      echo "${plan_label#plan:}"
    else
      echo "${blocker_id}"
    fi
    return
  done

  # All blockers resolved
  return
}

# _status_batch_get_blockers <epic_ids_file>
# Batch query blockers for multiple operations
# Input: file with epic_id per line
# Output: epic_id<tab>first_blocker_display per line
# Optimization: Uses wk list with label filters where possible
_status_batch_get_blockers() {
  local epic_ids_file="$1"

  # For now, iterate (future: batch wk command if available)
  while IFS= read -r epic_id; do
    [[ -z "${epic_id}" ]] && continue
    local display
    display=$(_status_get_blocker_display "${epic_id}")
    [[ -n "${display}" ]] && printf '%s\t%s\n' "${epic_id}" "${display}"
  done < "${epic_ids_file}"
}
