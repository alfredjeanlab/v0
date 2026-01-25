#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/recovery.sh - Resume and error clearing
#
# This module provides:
# - Resume phase determination
# - Error state clearing
#
# External commands: via sm_read_state, sm_bulk_update_state, sm_emit_event

# Requires: sm_read_state, sm_bulk_update_state from io.sh
# Requires: sm_emit_event from logging.sh
# Requires: sm_get_phase from schema.sh

# ============================================================================
# Resume/Recovery Functions
# ============================================================================

# sm_get_resume_phase <op>
# Determine what phase to resume from based on current state
# For failed/interrupted/cancelled operations, determines best resume point
sm_get_resume_phase() {
  local op="$1"
  local phase
  phase=$(sm_get_phase "${op}")

  case "${phase}" in
    failed|interrupted|cancelled)
      # Determine resume point based on state
      local epic_id plan_file
      epic_id=$(sm_read_state "${op}" "epic_id")
      plan_file=$(sm_read_state "${op}" "plan_file")

      if [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]]; then
        echo "queued"
      elif [[ -n "${plan_file}" ]] && [[ "${plan_file}" != "null" ]]; then
        echo "planned"
      else
        echo "init"
      fi
      ;;
    blocked)
      # Return blocked_phase or init
      local blocked_phase
      blocked_phase=$(sm_read_state "${op}" "blocked_phase")
      if [[ -n "${blocked_phase}" ]] && [[ "${blocked_phase}" != "null" ]]; then
        echo "${blocked_phase}"
      else
        echo "init"
      fi
      ;;
    *)
      echo "${phase}"
      ;;
  esac
}

# sm_clear_error_state <op>
# Clear error state and prepare for resume
sm_clear_error_state() {
  local op="$1"
  local resume_phase
  resume_phase=$(sm_get_resume_phase "${op}")

  sm_bulk_update_state "${op}" \
    "phase" "\"${resume_phase}\"" \
    "error" "null"

  sm_emit_event "${op}" "resume:from_error" "Resuming from ${resume_phase}"
}
