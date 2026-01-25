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
# C_RED, C_BOLD, C_RESET - Color codes from v0-common.sh

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
        echo "Error: Merge lock held by: ${holder}"
        echo "If stale, remove: rm ${MG_LOCKFILE}"
        return 1
    fi

    mkdir -p "${BUILD_DIR}"
    echo "${branch} (pid $$)" > "${MG_LOCKFILE}"
    trap 'mg_release_lock' EXIT
}

# mg_release_lock
# Release merge lock
mg_release_lock() {
    rm -f "${MG_LOCKFILE:-}"
}

# mg_do_merge <worktree> <branch>
# Execute the merge (fast-forward or regular)
# Returns 0 on success, 1 on failure
mg_do_merge() {
    local worktree="$1"
    local branch="$2"

    # Try fast-forward first
    if git merge --ff-only "${branch}" 2>/dev/null; then
        echo "Fast-forward merge successful"
        return 0
    fi

    # Rebase branch onto develop branch to enable fast-forward
    echo "Rebasing ${branch} onto ${V0_DEVELOP_BRANCH}..."
    git -C "${worktree}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
    if git -C "${worktree}" rebase "${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}" 2>/dev/null; then
        if git merge --ff-only "${branch}"; then
            echo "Fast-forward merge successful (after rebase)"
            return 0
        fi
    fi
    git -C "${worktree}" rebase --abort 2>/dev/null || true

    # Fallback to regular merge
    if git merge --no-edit "${branch}"; then
        echo "Merge successful"
        return 0
    fi

    git merge --abort 2>/dev/null || true
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

    git worktree remove "${worktree}" --force
    git branch -d "${branch}" 2>/dev/null || git branch -D "${branch}"
    rm -rf "${tree_dir}"
    echo "Removed worktree, branch, and tree dir: ${branch}"
}

# mg_push_and_verify <merge_commit>
# Push to remote and verify
# Returns 0 on success, 1 on failure
mg_push_and_verify() {
    local merge_commit="$1"

    if ! git push "${V0_GIT_REMOTE}"; then
        echo "Error: Push failed" >&2
        return 1
    fi

    if ! v0_verify_push "${merge_commit}"; then
        echo "Error: Merge commit not found on main after push" >&2
        return 1
    fi

    return 0
}

# mg_delete_remote_branch <branch>
# Delete the remote branch after successful merge
mg_delete_remote_branch() {
    local branch="$1"
    git push "${V0_GIT_REMOTE}" --delete "${branch}" 2>/dev/null || true
}

# mg_get_merge_commit
# Get the current HEAD commit hash (after merge)
mg_get_merge_commit() {
    git rev-parse HEAD
}
