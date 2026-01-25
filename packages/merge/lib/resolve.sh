#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/resolve.sh - Path resolution for merge operations
#
# Depends on: v0-common.sh (for sm_* functions)
# IMPURE: Uses git, jq, file system operations

# Expected environment variables:
# BUILD_DIR - Path to build directory
# REPO_NAME - Name of the repository

# mg_resolve_operation_to_worktree <operation>
# Resolve operation name to worktree path
# Sets: MG_WORKTREE, MG_TREE_DIR, MG_OP_NAME
# Returns 0 on success, 1 on failure
mg_resolve_operation_to_worktree() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    if [[ ! -f "${state_file}" ]]; then
        echo "Error: No operation found for '${op_name}'" >&2
        echo "" >&2
        echo "List operations with: v0 status" >&2
        return 1
    fi

    # Get worktree path from state
    local worktree
    worktree=$(sm_read_state "${op_name}" "worktree")
    if [[ -z "${worktree}" ]] || [[ "${worktree}" = "null" ]]; then
        echo "Error: Operation '${op_name}' has no worktree" >&2
        return 1
    fi

    if [[ ! -d "${worktree}" ]]; then
        echo "Error: Worktree not found: ${worktree}" >&2
        echo "The worktree may have been removed." >&2
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
}

# mg_resolve_path_to_worktree <path>
# Resolve a path to worktree
# Sets: MG_WORKTREE, MG_TREE_DIR
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
