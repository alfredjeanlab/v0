#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# PostToolUse hook - notify when items start (todo -> in_progress)
set -e

INPUT=$(cat)

# Check if this was a Bash tool call
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" != "Bash" ] && exit 0

# Check if command contains "wk start"
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [[ "$COMMAND" == *"wk start"* ]]; then
  # Extract the issue ID (last argument to wk start)
  ISSUE_ID=$(echo "$COMMAND" | grep -oE '[a-z0-9]+-[a-z0-9]+' | tail -1)

  if [ -n "$ISSUE_ID" ]; then
    LOG_DIR="${V0_BUILD_DIR:-$HOME/.v0/build}/logs"
    mkdir -p "$LOG_DIR"

    # Log the event
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] progress: $ISSUE_ID started" >> "$LOG_DIR/progress.log"

    # macOS notification (skip if in test mode)
    if [ "${V0_TEST_MODE:-}" != "1" ] && [ "$(uname)" = "Darwin" ] && command -v osascript &> /dev/null; then
      # Get issue type and project for descriptive title
      issue_type=$(wk show "$ISSUE_ID" 2>/dev/null | head -1 | grep -o '\[[^]]*\]' | tr -d '[]')
      project_name=$(echo "$ISSUE_ID" | cut -d'-' -f1)

      # Format title based on issue type
      case "$issue_type" in
        bug) notify_title="Fix: $project_name" ;;
        chore) notify_title="Chore: $project_name" ;;
        feature) notify_title="Feature: $project_name" ;;
        task) notify_title="Task: $project_name" ;;
        *) notify_title="Work: $project_name" ;;
      esac

      osascript -e "display notification \"Started: $ISSUE_ID\" with title \"$notify_title\"" 2>/dev/null || true
    fi
  fi
fi

exit 0
