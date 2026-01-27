#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Git verification functions for v0
# Source this file to get merge verification functions

# Define no-op v0_trace if not available (for unit tests that don't source full CLI)
if ! type -t v0_trace &>/dev/null; then
  v0_trace() { :; }
fi

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

  v0_trace "mergeq:verify" "Verifying ${commit:0:8} on ${branch} (require_remote=${require_remote})"

  # Validate commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    v0_trace "mergeq:verify" "Commit ${commit:0:8} does not exist"
    return 1  # Commit doesn't exist
  fi

  # Check if commit is ancestor of local branch
  if ! git merge-base --is-ancestor "${commit}" "${branch}" 2>/dev/null; then
    v0_trace "mergeq:verify" "Commit ${commit:0:8} is not ancestor of ${branch}"
    return 1
  fi

  # Optionally check remote
  if [[ "${require_remote}" = "true" ]]; then
    v0_trace "mergeq:verify" "Fetching ${branch} from ${V0_GIT_REMOTE} for remote verification"
    if ! git fetch "${V0_GIT_REMOTE}" "${branch}" --quiet 2>&1; then
      v0_trace "mergeq:verify" "Warning: fetch failed for ${branch}"
    fi
    if ! git merge-base --is-ancestor "${commit}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
      v0_trace "mergeq:verify" "Commit ${commit:0:8} is not ancestor of ${V0_GIT_REMOTE}/${branch}"
      return 1
    fi
  fi

  v0_trace "mergeq:verify" "Commit ${commit:0:8} verified on ${branch}"
  return 0
}

# v0_verify_push <commit>
# Verify a pushed commit exists on the local develop branch.
# Returns 0 if commit is on develop branch, 1 if not.
#
# Uses V0_DEVELOP_BRANCH (defaults to "main") as the target branch.
#
# Why this is sufficient:
# - git push returns 0 only if the push succeeded
# - If push succeeded, the remote has the commit
# - We verify locally that the commit is on the develop branch (sanity check)
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

  # Verify commit is on local develop branch
  local develop_branch="${V0_DEVELOP_BRANCH:-main}"
  if ! git merge-base --is-ancestor "${commit}" "${develop_branch}" 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} is not on ${develop_branch} branch" >&2
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
  local develop_branch="${V0_DEVELOP_BRANCH:-main}"
  echo "Local refs:" >&2
  echo "  HEAD: $(git rev-parse HEAD 2>/dev/null || echo 'N/A')" >&2
  echo "  ${develop_branch}: $(git rev-parse "${develop_branch}" 2>/dev/null || echo 'N/A')" >&2
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
  if git merge-base --is-ancestor "${commit}" "${develop_branch}" 2>/dev/null; then
    echo "  ${commit:0:8} IS ancestor of local ${develop_branch}" >&2
  else
    echo "  ${commit:0:8} is NOT ancestor of local ${develop_branch}" >&2
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

  v0_trace "mergeq:verify" "Verifying merge for operation ${op} (merge_commit=${merge_commit:-<none>})"

  if [[ -z "${merge_commit}" ]] || [[ "${merge_commit}" = "null" ]]; then
    v0_trace "mergeq:verify" "No merge_commit recorded for ${op}"
    return 1  # No recorded merge commit
  fi

  v0_verify_commit_on_branch "${merge_commit}" "${V0_DEVELOP_BRANCH:-main}" "${require_remote}"
}
