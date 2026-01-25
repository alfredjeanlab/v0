#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/format.sh - Pure display formatting (no subprocess calls)
#
# This module provides:
# - Phase display formatting
# - Color name mappings
# - ANSI color codes

# ============================================================================
# Phase Display Formatting
# ============================================================================

# _sm_format_phase_display <phase> <op_type> <merge_queued> <merge_status> <merged_at> <queue_entry_status> [<merge_resumed>] [<worktree_missing>]
# Format phase for display (shared logic for v0-status list view and sm_get_display_status)
# This is a pure formatting function - no file I/O, works with pre-read values
# Returns: display_phase|merge_icon
# Colors are NOT included - caller applies them based on context
_sm_format_phase_display() {
  local phase="$1"
  local op_type="$2"
  local merge_queued="$3"
  local merge_status="$4"
  local merged_at="$5"
  local queue_entry_status="$6"
  local merge_resumed="${7:-false}"
  local worktree_missing="${8:-false}"

  local display_phase="${phase}"
  local merge_icon=""

  case "${phase}" in
    merged)
      display_phase="completed"
      merge_icon="[merged]"
      ;;
    completed|pending_merge)
      # Plan-type operations don't merge
      if [[ "${op_type}" = "plan" ]]; then
        display_phase="plan completed"
        merge_icon=""
      elif [[ "${merge_queued}" = "true" ]]; then
        display_phase="completed"
        # Check queue status first (most authoritative)
        case "${queue_entry_status}" in
          pending|processing)
            # Check for blocking conditions in priority order
            if [[ "${worktree_missing}" = "true" ]]; then
              merge_icon="(== NO WORKTREE ==)"
            elif [[ "${merge_resumed}" = "true" ]]; then
              merge_icon="(== OPEN ISSUES ==)"
            else
              merge_icon="(merging...)"
            fi
            ;;
          completed)
            merge_icon="[merged]"
            ;;
          failed)
            merge_icon="(== MERGE FAILED ==)"
            ;;
          conflict)
            merge_icon="(== CONFLICT ==)"
            ;;
          resumed)
            merge_icon="(== NEEDS MERGE ==)"
            ;;
          *)
            # No queue entry - fall back to state.json
            if [[ "${merge_status}" = "merged" ]]; then
              merge_icon="[merged]"
            elif [[ "${merge_status}" = "conflict" ]]; then
              merge_icon="(== CONFLICT ==)"
            elif [[ -n "${merged_at}" ]] && [[ "${merged_at}" != "null" ]]; then
              merge_icon="[merged]"
            else
              merge_icon="[merge pending]"
            fi
            ;;
        esac
      else
        display_phase="completed"
        merge_icon="(== NEEDS MERGE ==)"
      fi
      ;;
    init)
      display_phase="new"
      ;;
    planned)
      display_phase="planned"
      ;;
    queued|executing)
      display_phase="assigned"
      ;;
    failed)
      display_phase="failed"
      ;;
    interrupted)
      display_phase="interrupted"
      ;;
    conflict)
      display_phase="conflict"
      merge_icon="(== CONFLICT ==)"
      ;;
    cancelled)
      display_phase="cancelled"
      ;;
  esac

  echo "${display_phase}|${merge_icon}"
}

# _sm_get_phase_color <phase> <merge_icon>
# Get color name for a phase display
# Returns: green, yellow, red, cyan, dim, or empty
_sm_get_phase_color() {
  local phase="$1"
  local merge_icon="$2"

  case "${phase}" in
    "completed"|"plan completed"|"merged")
      echo "green"
      ;;
    "new"|"planned"|"interrupted")
      echo "yellow"
      ;;
    "assigned")
      echo "cyan"
      ;;
    "failed"|"conflict")
      echo "red"
      ;;
    "cancelled")
      echo "dim"
      ;;
    *)
      echo ""
      ;;
  esac
}

# _sm_get_merge_icon_color <merge_icon>
# Get color name for merge icon
# Returns: green, yellow, red, cyan, dim, or empty
_sm_get_merge_icon_color() {
  local merge_icon="$1"

  case "${merge_icon}" in
    "[merged]")
      echo "green"
      ;;
    "(merging...)"*|"(resumed)"*|"(in queue)"*)
      echo "cyan"
      ;;
    "[merge pending]"*|"(== NEEDS MERGE ==)"*|"(== OPEN ISSUES =="*)
      echo "yellow"
      ;;
    "(== MERGE FAILED =="*|"(== CONFLICT =="*|"(== NO WORKTREE =="*)
      echo "red"
      ;;
    *)
      echo ""
      ;;
  esac
}

# sm_get_status_color <status>
# Return ANSI color code for a status
# Colors: green, yellow, red, cyan, dim
sm_get_status_color() {
  local status="$1"

  case "${status}" in
    green)  printf '\033[32m' ;;
    yellow) printf '\033[33m' ;;
    red)    printf '\033[31m' ;;
    cyan)   printf '\033[36m' ;;
    dim)    printf '\033[2m' ;;
    *)      printf '' ;;
  esac
}
