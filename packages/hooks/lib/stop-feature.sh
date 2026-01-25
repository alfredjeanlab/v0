#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Stop hook for v0 feature operations - verifies all plan issues are closed
# Input: JSON on stdin with session_id, transcript_path, stop_hook_active, reason
# Output: JSON with decision (block/allow) and reason

set -e

# Read hook input
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

# Prevent infinite loops - if already continuing from a stop hook, allow stop
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Get operation context from environment (set by v0 feature script)
PLAN_LABEL="${V0_PLAN_LABEL:-}"
OP_NAME="${V0_OP:-}"

if [ -z "$PLAN_LABEL" ] || [ -z "$OP_NAME" ]; then
  # No operation context - allow stop (likely not a v0 session)
  echo '{"decision": "approve"}'
  exit 0
fi

# Check for open/in_progress issues with the plan label
OPEN_COUNT=$(wk list --label "$PLAN_LABEL" --status todo 2>/dev/null | wc -l | tr -d ' ')
IN_PROGRESS_COUNT=$(wk list --label "$PLAN_LABEL" --status in_progress 2>/dev/null | wc -l | tr -d ' ')
TOTAL_INCOMPLETE=$((OPEN_COUNT + IN_PROGRESS_COUNT))

if [ "$TOTAL_INCOMPLETE" -gt 0 ]; then
  # Work remains - block stop
  # Get issue IDs (generic pattern - works with any prefix)
  OPEN_IDS=$(wk list --label "$PLAN_LABEL" --status todo 2>/dev/null | head -3 | grep -oE '[a-zA-Z]+-[a-z0-9]+' | tr '\n' ' ')
  IN_PROGRESS_IDS=$(wk list --label "$PLAN_LABEL" --status in_progress 2>/dev/null | head -3 | grep -oE '[a-zA-Z]+-[a-z0-9]+' | tr '\n' ' ')

  REASON="Work incomplete for $OP_NAME: $TOTAL_INCOMPLETE issues remain."
  [ -n "$OPEN_IDS" ] && REASON="$REASON Open: $OPEN_IDS."
  [ -n "$IN_PROGRESS_IDS" ] && REASON="$REASON In progress: $IN_PROGRESS_IDS."
  REASON="$REASON Use 'wk ready --label $PLAN_LABEL' to find remaining work."

  echo "{\"decision\": \"block\", \"reason\": $(echo "$REASON" | jq -Rs .)}"
  exit 0
fi

# Check for uncommitted changes in worktree
if [ -n "$V0_WORKTREE" ] && [ -d "$V0_WORKTREE" ]; then
  UNCOMMITTED=$(git -C "$V0_WORKTREE" status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
  if [ "$UNCOMMITTED" -gt 0 ]; then
    REPO_NAME=$(basename "$V0_WORKTREE")
    echo "{\"decision\": \"block\", \"reason\": \"Uncommitted changes in worktree. Run: cd $REPO_NAME && git add . && git commit -m \\\"...\\\" && git push ${V0_GIT_REMOTE:-origin}\"}"
    exit 0
  fi
fi

# All checks passed - allow stop
echo '{"decision": "approve"}'
