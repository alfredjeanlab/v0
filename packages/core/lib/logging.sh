#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Logging and notification functions for v0
# Source this file to get logging utilities

# Log event to project log
v0_log() {
  local event="$1"
  local message="$2"
  local log_dir="${BUILD_DIR}/logs"
  mkdir -p "${log_dir}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${event}: ${message}" >> "${log_dir}/v0.log"
}

# v0_notify - Send notification (log + OS notification on macOS)
# Args: $1 = title, $2 = message
# Set DISABLE_NOTIFICATIONS=1 or V0_TEST_MODE=1 to disable OS notifications
v0_notify() {
  local title="$1"
  local message="$2"

  # Always log
  v0_log "notify" "${title}: ${message}"

  # Skip OS notifications if disabled or in test mode
  if [[ "${DISABLE_NOTIFICATIONS:-}" = "1" ]] || [[ "${V0_TEST_MODE:-}" = "1" ]]; then
    return 0
  fi

  # macOS notification if available
  if [[ "$(uname)" = "Darwin" ]] && command -v osascript &> /dev/null; then
    osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
  fi
}

# ============================================================================
# Trace Logging (for debugging)
# ============================================================================

# v0_trace <event> <message>
# Log trace events to trace.log for debugging
# Cheap append-only operation with minimal performance impact
v0_trace() {
  local event="$1"
  shift
  local message="$*"

  # Ensure BUILD_DIR is set
  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local trace_dir="${BUILD_DIR}/logs"
  local trace_file="${trace_dir}/trace.log"

  # Create log directory if needed (only on first trace)
  if [[ ! -d "${trace_dir}" ]]; then
    mkdir -p "${trace_dir}" 2>/dev/null || return 0
  fi

  # Append trace entry (suppress errors to avoid breaking callers)
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${event}" "${message}" >> "${trace_file}" 2>/dev/null || true
}

# v0_trace_rotate
# Rotate trace.log if it exceeds 1MB
# Call periodically (e.g., at start of long operations)
v0_trace_rotate() {
  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local trace_file="${BUILD_DIR}/logs/trace.log"
  [[ ! -f "${trace_file}" ]] && return 0

  local size
  # macOS uses -f%z, Linux uses -c%s
  size=$(stat -f%z "${trace_file}" 2>/dev/null || stat -c%s "${trace_file}" 2>/dev/null || echo 0)

  if (( size > 1048576 )); then  # 1MB
    mv "${trace_file}" "${trace_file}.old" 2>/dev/null || true
    v0_trace "rotate" "Rotated trace.log (was ${size} bytes)"
  fi
}

# v0_capture_error_context
# Capture debugging context when an error occurs
# Call this in error handlers to help with debugging
v0_capture_error_context() {
  [[ -z "${BUILD_DIR:-}" ]] && return 0

  local context_file="${BUILD_DIR}/logs/error-context.log"
  local log_dir="${BUILD_DIR}/logs"

  mkdir -p "${log_dir}" 2>/dev/null || return 0

  {
    echo "=== Error Context $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
    echo "PWD: $(pwd)"
    echo "Script: ${BASH_SOURCE[1]:-unknown}"
    echo "Line: ${BASH_LINENO[0]:-unknown}"
    echo "Git branch: $(git branch --show-current 2>/dev/null || echo 'N/A')"
    echo "Git status:"
    git status --porcelain 2>/dev/null | head -10 || echo "  (git status failed)"
    echo ""
  } >> "${context_file}" 2>/dev/null || true
}
