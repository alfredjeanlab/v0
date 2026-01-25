#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Feature initialization utilities
# Source this file to get feature initialization functions

# feature_init_state <name> <prompt> <labels_array_name> <options_json>
# Initialize feature operation state
# Args:
#   $1 = operation name
#   $2 = prompt text
#   $3 = name of array containing labels
#   $4 = JSON object with options (no_merge, after, eager, safe)
# Uses: STATE_DIR, STATE_FILE from caller
feature_init_state() {
  local name="$1"
  local prompt="$2"
  local labels_array_name="$3"
  local options_json="$4"

  mkdir -p "${STATE_DIR}/logs"
  local machine
  machine=$(hostname -s)

  # Build labels JSON from array
  local labels_json="[]"
  local -n labels_ref="${labels_array_name}" 2>/dev/null || true
  if [[ ${#labels_ref[@]} -gt 0 ]]; then
    labels_json=$(printf '%s\n' "${labels_ref[@]}" | jq -R . | jq -s .)
  fi

  # Extract options
  local no_merge after eager safe
  no_merge=$(echo "${options_json}" | jq -r '.no_merge // false')
  after=$(echo "${options_json}" | jq -r '.after // ""')
  eager=$(echo "${options_json}" | jq -r '.eager // false')
  safe=$(echo "${options_json}" | jq -r '.safe // false')

  local merge_queued="true"
  [[ "${no_merge}" = "true" ]] && merge_queued="false"

  local after_json="null"
  local eager_json="false"
  local safe_json="false"
  if [[ -n "${after}" ]]; then
    after_json="\"${after}\""
    [[ "${eager}" = "true" ]] && eager_json="true"
  fi
  [[ "${safe}" = "true" ]] && safe_json="true"

  cat > "${STATE_FILE}" <<EOF
{
  "name": "${name}",
  "machine": "${machine}",
  "prompt": $(printf '%s' "${prompt}" | jq -Rs .),
  "phase": "init",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "labels": ${labels_json},
  "plan_file": null,
  "epic_id": null,
  "tmux_session": null,
  "worktree": null,
  "current_issue": null,
  "completed": [],
  "merge_queued": ${merge_queued},
  "merge_status": null,
  "merged_at": null,
  "merge_error": null,
  "after": ${after_json},
  "eager": ${eager_json},
  "safe": ${safe_json},
  "blocked_phase": null,
  "worker_pid": null,
  "worker_log": null,
  "worker_started_at": null
}
EOF
}
