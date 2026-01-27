#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/execution.sh - Merge execution and cleanup
#
# Depends on: resolve.sh, conflict.sh
# IMPURE: Uses git, file system operations

# Expected environment variables:
# BUILD_DIR - Path to build directory
# V0_GIT_REMOTE - Git remote name
# V0_DEVELOP_BRANCH - Main development branch name
# V0_WORKSPACE_DIR - Path to workspace directory
# C_RED, C_BOLD, C_RESET - Color codes from v0-common.sh

# mg_ensure_workspace
# Ensure workspace exists and is ready for merge operations
# Changes to workspace directory
# Returns 0 on success, 1 on failure
mg_ensure_workspace() {
    # Ensure workspace exists
    if ! ws_ensure_workspace; then
        echo "Error: Failed to create workspace" >&2
        return 1
    fi

    # Change to workspace directory
    cd "${V0_WORKSPACE_DIR}" || {
        echo "Error: Failed to change to workspace directory: ${V0_WORKSPACE_DIR}" >&2
        return 1
    }

    # Sync to develop branch
    if ! ws_sync_to_develop; then
        echo "Error: Failed to sync workspace to ${V0_DEVELOP_BRANCH}" >&2
        return 1
    fi

    return 0
}

# mg_acquire_lock <branch>
# Acquire merge lock
# Sets MG_LOCKFILE
# Returns 0 on success, 1 on failure
mg_acquire_lock() {
    local branch="$1"

    MG_LOCKFILE="${BUILD_DIR}/.merge.lock"

    if [[ -f "${MG_LOCKFILE}" ]]; then
        local holder
        holder=$(cat "${MG_LOCKFILE}")
        v0_trace "merge:lock" "Lock held by ${holder}, cannot acquire for ${branch}"
        echo "Error: Merge lock held by: ${holder}"
        echo "If stale, remove: rm ${MG_LOCKFILE}"
        return 1
    fi

    mkdir -p "${BUILD_DIR}"
    echo "${branch} (pid $$)" > "${MG_LOCKFILE}"
    v0_trace "merge:lock" "Acquired lock for ${branch} (pid $$)"
    trap 'mg_release_lock' EXIT
}

# mg_release_lock
# Release merge lock
mg_release_lock() {
    v0_trace "merge:lock" "Released lock"
    rm -f "${MG_LOCKFILE:-}"
}

# mg_ensure_develop_branch
# Ensure we're on the develop branch and up to date before merging
# Returns 0 on success, 1 on failure
mg_ensure_develop_branch() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    if [[ "${current_branch}" != "${V0_DEVELOP_BRANCH}" ]]; then
        echo "Switching to ${V0_DEVELOP_BRANCH} (was on ${current_branch})"
        if ! git checkout "${V0_DEVELOP_BRANCH}"; then
            echo "Error: Failed to checkout ${V0_DEVELOP_BRANCH}" >&2
            return 1
        fi
    fi

    # Fetch and pull latest to stay current.
    # The fetch is critical: conflict detection (mg_has_conflicts) runs git merge-tree
    # against HEAD, so HEAD must reflect the latest remote state. Without this fetch,
    # the daemon subprocess may have stale refs and report false conflicts.
    # See: c8784a6 which fixed the analogous issue for readiness checks.
    git fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
    git pull --ff-only "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true

    return 0
}

# mg_do_merge <worktree> <branch>
# Execute the merge (fast-forward or regular)
# Returns 0 on success, 1 on failure
mg_do_merge() {
    local worktree="$1"
    local branch="$2"

    v0_trace "merge:start" "Attempting merge of ${branch} with worktree ${worktree}"

    # Try fast-forward first
    if git merge --ff-only "${branch}" 2>/dev/null; then
        v0_trace "merge:success" "${branch} fast-forward merge successful"
        echo "Fast-forward merge successful"
        return 0
    fi

    # Rebase branch onto develop branch to enable fast-forward
    v0_trace "merge:rebase" "Rebasing ${branch} onto ${V0_DEVELOP_BRANCH}"
    echo "Rebasing ${branch} onto ${V0_DEVELOP_BRANCH}..."
    git -C "${worktree}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
    if git -C "${worktree}" rebase "${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}" 2>/dev/null; then
        if git merge --ff-only "${branch}"; then
            v0_trace "merge:success" "${branch} fast-forward merge successful (after rebase)"
            echo "Fast-forward merge successful (after rebase)"
            return 0
        fi
    fi
    git -C "${worktree}" rebase --abort 2>/dev/null || true

    # Fallback to regular merge
    v0_trace "merge:fallback" "Trying regular merge for ${branch}"
    if git merge --no-edit "${branch}"; then
        v0_trace "merge:success" "${branch} merge commit created"
        echo "Merge successful"
        return 0
    fi

    git merge --abort 2>/dev/null || true
    v0_trace "merge:conflict" "${branch} has conflicts, merge aborted"
    echo
    echo -e "${C_RED}${C_BOLD}Error:${C_RESET} Merge would have conflicts. To resolve:"
    echo -e "  ${C_BOLD}v0 merge ${worktree} --resolve${C_RESET}"
    return 1
}

# mg_cleanup_worktree <worktree> <tree_dir> <branch>
# Remove worktree, branch, and tree dir
mg_cleanup_worktree() {
    local worktree="$1"
    local tree_dir="$2"
    local branch="$3"

    v0_trace "merge:cleanup" "Removing worktree and branch: ${branch}"
    git worktree remove "${worktree}" --force
    git branch -d "${branch}" 2>/dev/null || git branch -D "${branch}"
    rm -rf "${tree_dir}"
    v0_trace "merge:cleanup:done" "Cleanup complete for ${branch}"
    echo "Removed worktree, branch, and tree dir: ${branch}"
}

# mg_push_and_verify <merge_commit>
# Push to remote and verify
# Returns 0 on success, 1 on failure
mg_push_and_verify() {
    local merge_commit="$1"

    v0_trace "merge:push" "Pushing ${merge_commit:0:8} to ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}"

    # Explicitly push HEAD to the develop branch to handle cases where
    # the local branch name doesn't match the remote tracking branch
    # (e.g., workspace branch v0/agent/user-id tracking agent/main)
    if ! git push "${V0_GIT_REMOTE}" "HEAD:${V0_DEVELOP_BRANCH}"; then
        v0_trace "merge:push:failed" "Push to ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH} failed"
        echo "Error: Push failed" >&2
        return 1
    fi

    v0_trace "merge:verify" "Verifying ${merge_commit:0:8} is on ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}"
    if ! v0_verify_push "${merge_commit}"; then
        v0_trace "merge:verify:failed" "Commit ${merge_commit:0:8} not found on ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}"
        echo "Error: Merge commit not found on main after push" >&2
        return 1
    fi

    v0_trace "merge:push:success" "Successfully pushed and verified ${merge_commit:0:8}"
    return 0
}

# mg_delete_remote_branch <branch>
# Delete the remote branch after successful merge
mg_delete_remote_branch() {
    local branch="$1"
    git push "${V0_GIT_REMOTE}" --delete "${branch}" 2>/dev/null || true
}

# mg_do_merge_without_worktree <branch>
# Execute merge for branch without a worktree (fast-forward only)
# Returns 0 on success, 1 if conflicts (requires worktree for resolution)
mg_do_merge_without_worktree() {
    local branch="$1"

    v0_trace "merge:start" "Attempting branch-only merge of ${branch} (no worktree)"

    # Try fast-forward first (no worktree needed)
    if git merge --ff-only "${branch}" 2>/dev/null; then
        v0_trace "merge:success" "${branch} fast-forward merge successful (branch-only)"
        echo "Fast-forward merge successful"
        return 0
    fi

    # Can't do non-FF merge without worktree for rebase
    v0_trace "merge:failed" "${branch} cannot fast-forward, worktree required"
    echo "Cannot fast-forward merge. Conflicts require worktree for resolution." >&2
    return 1
}

# mg_cleanup_branch_only <branch>
# Clean up branch when no worktree exists
mg_cleanup_branch_only() {
    local branch="$1"

    git branch -d "${branch}" 2>/dev/null || git branch -D "${branch}"
    echo "Removed branch: ${branch}"
}

# mg_cleanup_merge <worktree> <tree_dir> <branch> [is_temp]
# Unified cleanup after successful merge
# Handles all three cleanup patterns: temp worktree, regular worktree, branch-only
mg_cleanup_merge() {
    local worktree="$1"
    local tree_dir="$2"
    local branch="$3"
    local is_temp="${4:-false}"

    if [[ "${is_temp}" = true ]]; then
        mg_cleanup_temp_worktree
        mg_cleanup_branch_only "${branch}"
    elif [[ -n "${worktree}" ]] && [[ -d "${worktree}" ]]; then
        mg_cleanup_worktree "${worktree}" "${tree_dir}" "${branch}"
    else
        mg_cleanup_branch_only "${branch}"
    fi
}

# mg_get_merge_commit
# Get the current HEAD commit hash (after merge)
mg_get_merge_commit() {
    git rev-parse HEAD
}
