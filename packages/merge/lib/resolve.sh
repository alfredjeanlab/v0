#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/resolve.sh - Path resolution for merge operations
#
# Depends on: v0-common.sh (for sm_* functions), mergeq (for mq_* functions)
# IMPURE: Uses git, jq, file system operations

# Expected environment variables:
# BUILD_DIR - Path to build directory
# REPO_NAME - Name of the repository
# V0_GIT_REMOTE - Git remote name

# mg_resolve_branch_to_ref <branch-name>
# Resolve branch name to git ref, verify it exists
# Sets: MG_BRANCH, MG_HAS_WORKTREE=false
# Returns 0 if branch exists, 1 if not
mg_resolve_branch_to_ref() {
    local branch="$1"

    # Check if branch exists locally
    if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        return 0
    fi

    # Check remote
    if git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
        # Create local tracking branch
        git branch "${branch}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null || true
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        return 0
    fi

    return 1
}

# mg_resolve_queue_entry_to_branch <name>
# Resolve an operation/branch name via the merge queue
# Sets: MG_BRANCH, MG_HAS_WORKTREE=false, MG_OP_NAME
# Returns 0 if found in queue and branch exists, 1 if not
mg_resolve_queue_entry_to_branch() {
    local name="$1"

    # Skip if queue file doesn't exist
    if [[ ! -f "${QUEUE_FILE:-}" ]]; then
        return 1
    fi

    # Check if entry exists in merge queue
    if ! mq_entry_exists "${name}"; then
        return 1
    fi

    # Queue entries use operation name which is typically the branch name
    local branch="${name}"

    # Check if branch exists locally
    if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        MG_OP_NAME="${name}"
        MG_WORKTREE=""
        MG_TREE_DIR=""
        return 0
    fi

    # Check remote
    if git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
        # Create local tracking branch
        git branch "${branch}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null || true
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        MG_OP_NAME="${name}"
        MG_WORKTREE=""
        MG_TREE_DIR=""
        return 0
    fi

    return 1
}

# mg_resolve_operation_to_worktree <operation>
# Resolve operation name to worktree path
# Sets: MG_WORKTREE, MG_TREE_DIR, MG_OP_NAME, MG_HAS_WORKTREE, MG_BRANCH
# Returns 0 on success (with worktree or just branch), 1 on failure
mg_resolve_operation_to_worktree() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    if [[ ! -f "${state_file}" ]]; then
        # Fallback 1: Check merge queue for this entry
        if mg_resolve_queue_entry_to_branch "${op_name}"; then
            return 0
        fi

        # Fallback 2: Try direct branch resolution (local or remote)
        if mg_resolve_branch_to_ref "${op_name}"; then
            MG_OP_NAME=""  # No operation, just a branch
            MG_WORKTREE=""
            MG_TREE_DIR=""
            return 0
        fi

        # All fallbacks failed
        echo "Error: No operation found for '${op_name}'" >&2
        echo "" >&2
        echo "List operations with: v0 status" >&2

        # Check if it's a pending merge and provide helpful hint
        if [[ -f "${QUEUE_FILE:-}" ]] && mq_entry_exists "${op_name}"; then
            echo "" >&2
            echo "Note: '${op_name}' is in the merge queue but the branch doesn't exist." >&2
            echo "The branch may need to be fetched: git fetch ${V0_GIT_REMOTE}" >&2
        fi

        return 1
    fi

    # Get worktree path from state
    local worktree
    worktree=$(sm_read_state "${op_name}" "worktree")

    # Get branch from state (even if worktree missing)
    local branch
    branch=$(sm_read_state "${op_name}" "branch")

    if [[ -z "${worktree}" ]] || [[ "${worktree}" = "null" ]] || [[ ! -d "${worktree}" ]]; then
        # Worktree missing - try branch-only merge if branch exists
        if [[ -n "${branch}" ]] && [[ "${branch}" != "null" ]]; then
            if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
                MG_BRANCH="${branch}"
                MG_HAS_WORKTREE=false
                MG_OP_NAME="${op_name}"
                MG_WORKTREE=""
                MG_TREE_DIR=""
                return 0
            fi
            # Also check remote
            if git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
                # Create local tracking branch
                git branch "${branch}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null || true
                MG_BRANCH="${branch}"
                MG_HAS_WORKTREE=false
                MG_OP_NAME="${op_name}"
                MG_WORKTREE=""
                MG_TREE_DIR=""
                return 0
            fi
        fi

        # Check operation status to give a more informative error
        local phase merge_status
        phase=$(sm_read_state "${op_name}" "phase")
        merge_status=$(sm_read_state "${op_name}" "merge_status")

        if [[ "${phase}" = "merged" ]] || [[ "${merge_status}" = "merged" ]]; then
            echo "Error: Operation '${op_name}' has already been merged" >&2
            return 1
        fi

        if [[ "${phase}" = "cancelled" ]]; then
            echo "Error: Operation '${op_name}' has been cancelled" >&2
            return 1
        fi

        if [[ "${merge_status}" = "conflict" ]] || [[ "${merge_status}" = "failed" ]] || [[ "${merge_status}" = "verification_failed" ]]; then
            # Check if the merge_commit is actually on main (verification may have been transient)
            local merge_commit main_repo
            merge_commit=$(sm_read_state "${op_name}" "merge_commit")
            main_repo="${_MG_MAIN_REPO:-${V0_ROOT:-$(pwd)}}"

            if [[ -n "${merge_commit}" ]] && [[ "${merge_commit}" != "null" ]] && \
               git -C "${main_repo}" merge-base --is-ancestor "${merge_commit}" "${V0_DEVELOP_BRANCH:-main}" 2>/dev/null; then
                # Branch was actually merged - clean up and report success
                echo "Operation '${op_name}' was already merged (cleaning up)..."

                # Update mergeq entry to completed
                if [[ -f "${QUEUE_FILE:-}" ]] && mq_entry_exists "${op_name}"; then
                    mq_update_entry_status "${op_name}" "completed" 2>/dev/null || true
                fi

                # Delete remote branch if it still exists
                if [[ -n "${branch}" ]] && [[ "${branch}" != "null" ]]; then
                    git -C "${main_repo}" push "${V0_GIT_REMOTE}" --delete "${branch}" 2>/dev/null || true
                fi

                # Transition operation to merged state
                sm_transition_to_merged "${op_name}" 2>/dev/null || true

                echo "Cleanup complete. Operation '${op_name}' is now marked as merged."
                return 1
            fi

            echo "Error: Operation '${op_name}' previously failed to merge (status: ${merge_status})" >&2
            echo "" >&2
            echo "The worktree and branch have been cleaned up." >&2
            echo "To retry, recreate the operation or manually create a new branch." >&2
            return 1
        fi

        echo "Error: Worktree not found and branch doesn't exist for '${op_name}'" >&2
        return 1
    fi

    # Auto-correct if state.json stored tree dir instead of worktree path
    if ! git -C "${worktree}" rev-parse --git-dir &>/dev/null; then
        if [[ -d "${worktree}/${REPO_NAME}" ]] && git -C "${worktree}/${REPO_NAME}" rev-parse --git-dir &>/dev/null; then
            worktree="${worktree}/${REPO_NAME}"
        fi
    fi

    MG_WORKTREE="${worktree}"
    MG_TREE_DIR="$(dirname "${worktree}")"
    MG_OP_NAME="${op_name}"
    MG_HAS_WORKTREE=true
    MG_BRANCH="${branch:-}"
}

# mg_resolve_path_to_worktree <path>
# Resolve a path to worktree
# Sets: MG_WORKTREE, MG_TREE_DIR, MG_HAS_WORKTREE
# Returns 0 on success, 1 on failure
mg_resolve_path_to_worktree() {
    local input="$1"

    # Check if input is already a git worktree
    if git -C "${input}" rev-parse --git-dir &>/dev/null; then
        MG_WORKTREE="${input}"
        MG_TREE_DIR="$(dirname "${input}")"
    else
        # Input is a tree dir, append REPO_NAME to get worktree
        MG_TREE_DIR="${input}"
        MG_WORKTREE="${input}/${REPO_NAME}"
    fi

    if [[ ! -d "${MG_TREE_DIR}" ]]; then
        echo "Error: Tree directory not found: ${MG_TREE_DIR}"
        return 1
    fi

    if [[ ! -d "${MG_WORKTREE}" ]]; then
        echo "Error: Worktree not found: ${MG_WORKTREE}"
        return 1
    fi

    MG_HAS_WORKTREE=true
}

# mg_validate_worktree <worktree>
# Verify worktree is a valid git repository
# Returns 0 if valid, 1 if not
mg_validate_worktree() {
    local worktree="$1"

    if ! git -C "${worktree}" rev-parse --git-dir &>/dev/null; then
        echo "Error: ${worktree} is not a valid git repository" >&2
        echo "" >&2
        echo "The directory exists but is not a git worktree. This can happen if:" >&2
        echo "  - The main repository was moved or deleted" >&2
        echo "  - The worktree was not properly created" >&2
        echo "" >&2
        echo "To fix: remove the directory and re-create the worktree" >&2
        return 1
    fi
}

# mg_get_branch <worktree>
# Get the current branch name from a worktree
# Outputs: Branch name
mg_get_branch() {
    local worktree="$1"
    git -C "${worktree}" rev-parse --abbrev-ref HEAD
}

# mg_get_worktree_git_dir <worktree>
# Get the git directory for a worktree
# Outputs: Path to git directory
mg_get_worktree_git_dir() {
    local worktree="$1"
    git -C "${worktree}" rev-parse --git-dir
}

# mg_is_input_path <input>
# Check if input looks like a path (starts with / or .)
# Returns 0 if path, 1 if operation name
mg_is_input_path() {
    local input="$1"
    [[ "${input}" == /* ]] || [[ "${input}" == .* ]]
}
