#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Stop hook for chore worker - verifies no chores remain
set -e

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
STOP_REASON=$(echo "$INPUT" | jq -r '.reason // ""')

# Approve immediately if stop is due to system reasons (auth, credits, etc.)
case "$STOP_REASON" in
  *auth*|*login*|*credential*|*credit*|*subscription*|*billing*|*payment*)
    echo '{"decision": "approve"}'
    exit 0
    ;;
esac

if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check for remaining chores
READY_CHORES=$(wk ready --type chore 2>/dev/null | wc -l | tr -d ' ')
IN_PROGRESS=$(wk list --type chore --status in_progress 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((READY_CHORES + IN_PROGRESS))

if [ "$TOTAL" -gt 0 ]; then
  echo "{\"decision\": \"block\", \"reason\": \"$TOTAL chores remain. Use 'wk ready --type chore' to find work.\"}"
  exit 0
fi

echo '{"decision": "approve"}'
