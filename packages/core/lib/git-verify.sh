#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Git verification functions for v0
# Source this file to get merge verification functions

# v0_verify_commit_on_branch <commit> <branch> [require_remote]
# Verify that a specific commit exists on a branch
# Returns 0 if commit is on branch, 1 if not
#
# This is the primary verification function - works for all merge workflows
# because it checks a specific commit hash, not a branch name.
#
# Args:
#   commit         - Commit hash to verify
#   branch         - Branch to check (e.g., "main", "origin/main")
#   require_remote - If "true", also verify on origin/${branch} (default: false)
v0_verify_commit_on_branch() {
  local commit="$1"
  local branch="$2"
  local require_remote="${3:-false}"

  # Validate commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    return 1  # Commit doesn't exist
  fi

  # Check if commit is ancestor of local branch
  if ! git merge-base --is-ancestor "${commit}" "${branch}" 2>/dev/null; then
    return 1
  fi

  # Optionally check remote
  if [[ "${require_remote}" = "true" ]]; then
    git fetch "${V0_GIT_REMOTE}" "${branch}" --quiet 2>/dev/null || true
    if ! git merge-base --is-ancestor "${commit}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
      return 1
    fi
  fi

  return 0
}

# v0_verify_push <commit>
# Verify a pushed commit exists on local main.
# Returns 0 if commit is on main, 1 if not.
#
# Why this is sufficient:
# - git push returns 0 only if the push succeeded
# - If push succeeded, the remote has the commit
# - We verify locally that the commit is on main (sanity check)
# - Remote state queries (ls-remote, fetch) can return stale data
#
# Args:
#   commit - Commit hash to verify
v0_verify_push() {
  local commit="$1"

  # Validate commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} does not exist locally" >&2
    return 1
  fi

  # Verify commit is on local main
  if ! git merge-base --is-ancestor "${commit}" main 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} is not on main branch" >&2
    return 1
  fi

  return 0
}

# v0_diagnose_push_verification <commit> <remote_branch>
# Output diagnostic information when push verification fails
v0_diagnose_push_verification() {
  local commit="$1"
  local remote_branch="$2"
  local remote="${remote_branch%%/*}"
  local branch="${remote_branch#*/}"

  echo "=== Push Verification Diagnostic ===" >&2
  echo "Commit to verify: ${commit}" >&2
  echo "Target branch: ${remote_branch}" >&2
  echo "" >&2

  # Check local refs
  echo "Local refs:" >&2
  echo "  HEAD: $(git rev-parse HEAD 2>/dev/null || echo 'N/A')" >&2
  echo "  main: $(git rev-parse main 2>/dev/null || echo 'N/A')" >&2
  echo "  ${remote_branch}: $(git rev-parse "${remote_branch}" 2>/dev/null || echo 'N/A')" >&2
  echo "" >&2

  # Check remote state
  echo "Remote state (via ls-remote):" >&2
  git ls-remote "${remote}" "refs/heads/${branch}" 2>/dev/null || echo "  Failed to query remote" >&2
  echo "" >&2

  # Check if commit exists at all
  if git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "Commit ${commit:0:8} exists locally" >&2
  else
    echo "Commit ${commit:0:8} NOT FOUND locally" >&2
  fi

  # Check ancestry
  echo "" >&2
  echo "Ancestry check:" >&2
  if git merge-base --is-ancestor "${commit}" main 2>/dev/null; then
    echo "  ${commit:0:8} IS ancestor of local main" >&2
  else
    echo "  ${commit:0:8} is NOT ancestor of local main" >&2
  fi

  echo "==================================" >&2
}

# v0_verify_merge_by_op <operation> [require_remote]
# Verify merge using operation's recorded merge commit
# This is the ONLY reliable way to verify after merge completion.
#
# Works for all merge workflows because v0-merge records HEAD after do_merge():
# - Direct FF: records the branch tip (same hash)
# - Rebase+FF: records the rebased commit (new hash that's on main)
# - Merge commit: records the merge commit
#
# Args:
#   operation      - Operation name
#   require_remote - If "true", verify on origin/main (default: false)
v0_verify_merge_by_op() {
  local op="$1"
  local require_remote="${2:-false}"
  local merge_commit
  merge_commit=$(sm_read_state "${op}" "merge_commit")

  if [[ -z "${merge_commit}" ]] || [[ "${merge_commit}" = "null" ]]; then
    return 1  # No recorded merge commit
  fi

  v0_verify_commit_on_branch "${merge_commit}" "main" "${require_remote}"
}
