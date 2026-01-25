#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Stop hook for merge resolution - verifies conflicts are resolved
set -e

# Source grep wrapper for fast pattern matching
_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packages/core/lib/grep.sh
source "${_HOOKS_DIR}/../../core/lib/grep.sh"

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

WORKTREE="${MERGE_WORKTREE:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check for unresolved conflicts
if git -C "$WORKTREE" status --porcelain 2>/dev/null | v0_grep_quiet '^UU|^AA|^DD'; then
  echo '{"decision": "block", "reason": "Merge conflicts still exist. Resolve conflicts then run: git add <files> && git rebase --continue"}'
  exit 0
fi

# Check if rebase is in progress
GIT_DIR=$(git -C "$WORKTREE" rev-parse --git-dir 2>/dev/null)
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
  echo '{"decision": "block", "reason": "Rebase in progress. Run: git rebase --continue (or --abort)"}'
  exit 0
fi

echo '{"decision": "approve"}'
