#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Stop hook for v0 roadmap operations - verifies roadmap orchestration is complete
# Input: JSON on stdin with session_id, transcript_path, stop_hook_active, reason
# Output: JSON with decision (block/allow) and reason

set -e

# Read hook input
INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "${INPUT}" | jq -r '.stop_hook_active // false')
STOP_REASON=$(echo "${INPUT}" | jq -r '.reason // ""')

# Approve immediately if stop is due to system reasons (auth, credits, etc.)
case "${STOP_REASON}" in
  *auth*|*login*|*credential*|*credit*|*subscription*|*billing*|*payment*)
    echo '{"decision": "approve"}'
    exit 0
    ;;
esac

# Prevent infinite loops - if already continuing from a stop hook, allow stop
if [[ "${STOP_HOOK_ACTIVE}" = "true" ]]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Get roadmap context from environment (set by v0-roadmap-worker)
ROADMAP_NAME="${V0_ROADMAP_NAME:-}"

if [[ -z "${ROADMAP_NAME}" ]]; then
  # No roadmap context - allow stop (likely not a v0 roadmap session)
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if features have been queued for this roadmap
QUEUED_COUNT=$(wk list --label "roadmap:${ROADMAP_NAME}" 2>/dev/null | wc -l | tr -d ' ')

if [[ "${QUEUED_COUNT}" -eq 0 ]]; then
  # No features queued yet - block stop
  echo "{\"decision\": \"block\", \"reason\": \"Roadmap orchestration incomplete: no features have been queued yet. Follow ROADMAP.md instructions to queue features with 'v0 feature --after --label roadmap:${ROADMAP_NAME}'.\"}"
  exit 0
fi

# Check for uncommitted changes in worktree
if [[ -n "${V0_WORKTREE}" ]] && [[ -d "${V0_WORKTREE}" ]]; then
  UNCOMMITTED=$(git -C "${V0_WORKTREE}" status --porcelain 2>/dev/null | grep -cv '^??' || true)
  if [[ "${UNCOMMITTED}" -gt 0 ]]; then
    REPO_NAME=$(basename "${V0_WORKTREE}")
    echo "{\"decision\": \"block\", \"reason\": \"Uncommitted changes in worktree. Run: cd ${REPO_NAME} && git add . && git commit -m \\\"...\\\" && git push ${V0_GIT_REMOTE:-origin}\"}"
    exit 0
  fi
fi

# All checks passed - allow stop
echo '{"decision": "approve"}'
