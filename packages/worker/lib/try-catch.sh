#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Generic error logging wrapper for background worker scripts
# Captures stdout/stderr, logs failures, and sends notifications on error
#
# Usage: try-catch.sh <log_file> <worker_name> <command_suggestion> [<command> [args...]]
#
# Args:
#   log_file              Path to log file (converted to absolute path)
#   worker_name           Display name for notifications (e.g., "Claude Fix Worker")
#   command_suggestion    Command to suggest in error notifications (e.g., "v0 fix --errors")
#   command [args...]     The command to run and monitor
#
# Environment variables:
#   DISABLE_NOTIFICATIONS: Set to 1 to disable macOS notifications
#   ERROR_FILE: Custom error log file (default: <log_file>.error)
#
# Example:
#   try-catch.sh "claude-worker.log" "Claude Fix Worker" "v0 fix --errors" \
#     claude --model opus 'Fix bugs'

set -e

LOG_FILE="${1:?Log file required as first argument}"
WORKER_NAME="${2:?Worker name required as second argument}"
COMMAND_SUGGESTION="${3:?Command suggestion required as third argument}"
shift 3

# Convert to absolute paths
LOG_FILE="$(cd "$(dirname "${LOG_FILE}")" && pwd)/$(basename "${LOG_FILE}")"
ERROR_FILE="${ERROR_FILE:-${LOG_FILE}.error}"

# Log startup
echo "[$(date)] Starting ${WORKER_NAME}" >> "${LOG_FILE}"

# Run the command, capturing output and exit code
{
  "$@" 2> >(tee -a "${ERROR_FILE}" >&2)
  EXIT_CODE=$?
} || EXIT_CODE=$?

# Check for clean done exit (flag set by done script before killing worker)
TREE_DIR="$(dirname "${LOG_FILE}")"
DONE_EXIT_FLAG="${TREE_DIR}/.done-exit"
CLEAN_EXIT=0

if [[ -f "${DONE_EXIT_FLAG}" ]]; then
  CLEAN_EXIT=1
  # Note: Don't remove the flag here - the polling daemon checks for it
  # and will clean it up at the appropriate time
fi

# Log the result
if [[ ${EXIT_CODE} -ne 0 ]] && [[ ${CLEAN_EXIT} -ne 1 ]]; then
  echo "[$(date)] ${WORKER_NAME} FAILED with exit code ${EXIT_CODE}" >> "${LOG_FILE}"
  echo "[$(date)] Logs: ${LOG_FILE}" >> "${LOG_FILE}"
  echo "[$(date)] Errors: ${ERROR_FILE}" >> "${LOG_FILE}"

  # Signal polling daemon that worker failed (for exponential backoff)
  touch "${TREE_DIR}/.worker-error"

  # Send macOS notification if osascript is available (unless disabled or in test mode)
  if [[ "${DISABLE_NOTIFICATIONS:-}" != "1" ]] && [[ "${V0_TEST_MODE:-}" != "1" ]] && command -v osascript &> /dev/null; then
    osascript -e "display notification \"Run: ${COMMAND_SUGGESTION}\" with title \"${WORKER_NAME} failed (exit ${EXIT_CODE})\""
  fi
else
  echo "[$(date)] ${WORKER_NAME} exited cleanly" >> "${LOG_FILE}"
fi

exit "${EXIT_CODE}"
