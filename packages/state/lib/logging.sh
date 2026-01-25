#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/logging.sh - Event logging with rotation
#
# This module provides:
# - Event emission
# - Log rotation
#
# External commands: date, mkdir, stat, mv, rm

# Requires: BUILD_DIR, SM_LOG_MAX_SIZE, SM_LOG_KEEP_COUNT from rules.sh

# ============================================================================
# Event Logging
# ============================================================================

# sm_emit_event <op> <event> [details]
# Log an event with automatic rotation
sm_emit_event() {
  local op="$1"
  local event="$2"
  local details="${3:-}"
  local log_dir="${BUILD_DIR}/operations/${op}/logs"
  local log_file="${log_dir}/events.log"

  mkdir -p "${log_dir}"

  # Rotate if needed
  if [[ -f "${log_file}" ]]; then
    local size
    size=$(stat -f%z "${log_file}" 2>/dev/null || stat -c%s "${log_file}" 2>/dev/null || echo 0)
    if [[ "${size}" -gt "${SM_LOG_MAX_SIZE}" ]]; then
      sm_rotate_log "${log_file}"
    fi
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${event}: ${details}" >> "${log_file}"
}

# sm_rotate_log <log_file>
# Rotate log files: events.log -> events.log.1 -> events.log.2 -> ...
sm_rotate_log() {
  local log_file="$1"
  local i

  # Remove oldest if at limit
  rm -f "${log_file}.${SM_LOG_KEEP_COUNT}"

  # Shift existing rotated logs
  for ((i = SM_LOG_KEEP_COUNT - 1; i >= 1; i--)); do
    [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i + 1))"
  done

  # Rotate current log
  mv "${log_file}" "${log_file}.1"
}
