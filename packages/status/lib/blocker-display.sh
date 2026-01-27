#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# blocker-display.sh - Optimized blocker display for v0 status

# Global cache for batched wk show results (JSONL format)
# Populated by _status_init_blocker_cache, used by _status_lookup_issue
_STATUS_ISSUE_CACHE=""

# _status_init_blocker_cache <epic_id> [epic_id...]
# Pre-fetch all issue data in a single wk show call
# Stores results in _STATUS_ISSUE_CACHE for later lookup
# Call this once before the display loop with all epic_ids
_status_init_blocker_cache() {
  local ids=("$@")
  [[ ${#ids[@]} -eq 0 ]] && return

  # Filter out empty/null values
  local valid_ids=()
  for id in "${ids[@]}"; do
    [[ -n "${id}" ]] && [[ "${id}" != "null" ]] && valid_ids+=("${id}")
  done
  [[ ${#valid_ids[@]} -eq 0 ]] && return

  # Single batch call to get all issues
  local initial_cache
  initial_cache=$(wk show "${valid_ids[@]}" -o json 2>/dev/null) || return 0

  # Extract all blocker IDs that we need to fetch
  local blocker_ids
  blocker_ids=$(echo "${initial_cache}" | jq -r '.blockers[]?' 2>/dev/null | sort -u)

  if [[ -n "${blocker_ids}" ]]; then
    # Fetch blockers in a second batch call
    local blocker_cache
    # Word splitting intentional: blocker_ids contains newline-separated IDs
    # shellcheck disable=SC2086
    blocker_cache=$(wk show ${blocker_ids} -o json 2>/dev/null) || true

    # Combine both caches
    _STATUS_ISSUE_CACHE="${initial_cache}"$'\n'"${blocker_cache}"
  else
    _STATUS_ISSUE_CACHE="${initial_cache}"
  fi
}

# _status_lookup_issue <issue_id>
# Look up an issue from the cache by ID
# Output: JSON object or empty if not found
_status_lookup_issue() {
  local issue_id="$1"
  [[ -z "${_STATUS_ISSUE_CACHE}" ]] && return

  # Use jq to find the matching issue (grep would be faster but less safe)
  echo "${_STATUS_ISSUE_CACHE}" | jq -c "select(.id == \"${issue_id}\")" 2>/dev/null | head -1
}

# _status_get_blocker_display <epic_id>
# Get display string for first open blocker
# Uses _STATUS_ISSUE_CACHE if available, falls back to direct wk call
# Output: "op_name" or "issue_id" or empty
_status_get_blocker_display() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return

  # Try cache first, fall back to direct call
  local issue_json
  issue_json=$(_status_lookup_issue "${epic_id}")
  if [[ -z "${issue_json}" ]]; then
    issue_json=$(wk show "${epic_id}" -o json 2>/dev/null) || return 0
  fi

  local blockers
  blockers=$(echo "${issue_json}" | jq -r '.blockers // []')
  [[ "${blockers}" == "[]" ]] && return

  # Check each blocker until we find an open one
  local blocker_id
  for blocker_id in $(echo "${blockers}" | jq -r '.[]'); do
    # Try cache first for blocker lookup
    local blocker_json
    blocker_json=$(_status_lookup_issue "${blocker_id}")
    if [[ -z "${blocker_json}" ]]; then
      blocker_json=$(wk show "${blocker_id}" -o json 2>/dev/null) || {
        # wk failed, assume blocker is open
        echo "${blocker_id}"
        return
      }
    fi

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

# _status_batch_get_blockers <epic_ids...>
# Batch query blockers for multiple operations
# Output: epic_id<tab>first_blocker_display per line (only for blocked ops)
_status_batch_get_blockers() {
  local epic_ids=("$@")
  [[ ${#epic_ids[@]} -eq 0 ]] && return 0

  # Initialize cache with all epic_ids (2 wk calls total)
  _status_init_blocker_cache "${epic_ids[@]}"

  # Now resolve each - all lookups hit cache
  for epic_id in "${epic_ids[@]}"; do
    [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && continue
    local display
    display=$(_status_get_blocker_display "${epic_id}")
    [[ -n "${display}" ]] && printf '%s\t%s\n' "${epic_id}" "${display}"
  done
  return 0
}
