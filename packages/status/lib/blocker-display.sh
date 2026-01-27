#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# blocker-display.sh - Optimized blocker display for v0 status

# Global cache for batched wk show results
# Format: id<TAB>status<TAB>blockers<TAB>plan_label (one per line)
# blockers is comma-separated list of blocker IDs
# Populated by _status_init_blocker_cache, used by _status_cache_lookup
_STATUS_ISSUE_CACHE=""

# _status_init_blocker_cache <epic_id> [epic_id...]
# Pre-fetch all issue data in a single wk show call
# Stores pre-processed results in _STATUS_ISSUE_CACHE for O(1) bash lookups
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

  # Single batch call to get all issues, pre-process to TSV in one jq pass
  # Output: id<TAB>status<TAB>blockers_csv<TAB>plan_label
  local initial_tsv
  initial_tsv=$(wk show "${valid_ids[@]}" -o json 2>/dev/null | jq -r '
    [.id, .status, (.blockers // [] | join(",")),
     ((.labels // []) | map(select(startswith("plan:"))) | .[0] // "")] | @tsv
  ' 2>/dev/null) || return 0

  # Extract all blocker IDs that we need to fetch
  local blocker_ids
  blocker_ids=$(echo "${initial_tsv}" | cut -f3 | tr ',' '\n' | sort -u | grep -v '^$' || true)

  if [[ -n "${blocker_ids}" ]]; then
    # Fetch blockers in a second batch call, same TSV format
    local blocker_tsv
    # Word splitting intentional: blocker_ids contains newline-separated IDs
    # shellcheck disable=SC2086
    blocker_tsv=$(wk show ${blocker_ids} -o json 2>/dev/null | jq -r '
      [.id, .status, (.blockers // [] | join(",")),
       ((.labels // []) | map(select(startswith("plan:"))) | .[0] // "")] | @tsv
    ' 2>/dev/null) || true

    # Combine both caches
    _STATUS_ISSUE_CACHE="${initial_tsv}"$'\n'"${blocker_tsv}"
  else
    _STATUS_ISSUE_CACHE="${initial_tsv}"
  fi
}

# _status_cache_lookup <issue_id> <field_num>
# Look up a field from the cache by ID using pure bash
# field_num: 1=id, 2=status, 3=blockers_csv, 4=plan_label
# Output: field value or empty if not found
_status_cache_lookup() {
  local issue_id="$1"
  local field_num="$2"
  [[ -z "${_STATUS_ISSUE_CACHE}" ]] && return

  local line
  while IFS= read -r line; do
    # Match line starting with issue_id followed by tab
    if [[ "${line}" == "${issue_id}"$'\t'* ]]; then
      # Extract requested field
      echo "${line}" | cut -f"${field_num}"
      return
    fi
  done <<< "${_STATUS_ISSUE_CACHE}"
}

# _status_get_blocker_display <epic_id>
# Get display string for first open blocker
# Uses _STATUS_ISSUE_CACHE if available, falls back to direct wk call
# Output: "op_name" or "issue_id" or empty
_status_get_blocker_display() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return

  # Try cache first for blockers list
  local blockers_csv
  blockers_csv=$(_status_cache_lookup "${epic_id}" 3)

  # Fall back to direct wk call if not in cache
  if [[ -z "${blockers_csv}" ]] && [[ -z "$(_status_cache_lookup "${epic_id}" 1)" ]]; then
    local issue_json
    issue_json=$(wk show "${epic_id}" -o json 2>/dev/null) || return 0
    blockers_csv=$(echo "${issue_json}" | jq -r '(.blockers // []) | join(",")' 2>/dev/null)
  fi

  [[ -z "${blockers_csv}" ]] && return

  # Check each blocker until we find an open one
  local blocker_id status plan_label
  IFS=',' read -ra blocker_ids <<< "${blockers_csv}"
  for blocker_id in "${blocker_ids[@]}"; do
    [[ -z "${blocker_id}" ]] && continue

    # Try cache first for blocker status
    status=$(_status_cache_lookup "${blocker_id}" 2)
    if [[ -z "${status}" ]]; then
      # Fall back to direct wk call
      status=$(wk show "${blocker_id}" -o json 2>/dev/null | jq -r '.status // "unknown"') || {
        # wk failed, assume blocker is open
        echo "${blocker_id}"
        return
      }
    fi

    case "${status}" in
      done|closed)
        # This blocker is resolved, check next
        continue
        ;;
    esac

    # Found an open blocker - get plan label from cache or derive from ID
    plan_label=$(_status_cache_lookup "${blocker_id}" 4)
    if [[ -z "${plan_label}" ]] && [[ -z "$(_status_cache_lookup "${blocker_id}" 1)" ]]; then
      # Not in cache, fetch and extract
      plan_label=$(wk show "${blocker_id}" -o json 2>/dev/null | jq -r '
        (.labels // []) | map(select(startswith("plan:"))) | .[0] // ""
      ' 2>/dev/null)
    fi

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
