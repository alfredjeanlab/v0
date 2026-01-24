#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Stop hook for fix worker - verifies no bugs remain
set -e

# Determine V0_DIR from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V0_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source worker-common.sh for detect_note_without_fix function
source "${V0_DIR}/lib/worker-common.sh"

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

# Check for abandoned work (in_progress bugs indicate work started but not finished)
# Note: Ready bugs are expected - the workflow is one bug per session
IN_PROGRESS_BUGS=$(wk list --type bug --status in_progress -o json 2>/dev/null | jq -r '.issues[].id' 2>/dev/null || true)
# Count non-empty lines properly
if [[ -z "$(echo "$IN_PROGRESS_BUGS" | tr -d '[:space:]')" ]]; then
  IN_PROGRESS=0
else
  IN_PROGRESS=$(echo "$IN_PROGRESS_BUGS" | grep -c . 2>/dev/null || echo "0")
fi

if [ "$IN_PROGRESS" -gt 0 ]; then
  # Check if any in-progress bugs have notes but no fix commits
  # This indicates the worker documented why they couldn't fix it
  REPO_DIR=""
  if [[ -f ".worker-git-dir" ]]; then
    REPO_DIR=$(cat ".worker-git-dir")
  fi

  for bug_id in $IN_PROGRESS_BUGS; do
    [[ -z "$bug_id" ]] && continue

    if [[ -n "$REPO_DIR" ]] && detect_note_without_fix "$bug_id" "$REPO_DIR"; then
      # Bug has note but no fix - hand off to human
      wk edit "$bug_id" assignee "worker:human" 2>/dev/null || true

      echo "{\"decision\": \"block\", \"reason\": \"Bug $bug_id has a note but no fix. Reassigned to human for review. Use 'wk show $bug_id' to see the note, then either fix it or close with 'wk close $bug_id --reason=\\\"reason\\\"'.\"}"
      exit 0
    fi
  done

  # Normal case: bugs still in progress without note-without-fix scenario
  echo "{\"decision\": \"block\", \"reason\": \"$IN_PROGRESS bug(s) still in progress. Complete with './fixed <id>' or abandon with 'wk reopen <id>'.\"}"
  exit 0
fi

echo '{"decision": "approve"}'
