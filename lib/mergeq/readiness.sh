#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/readiness.sh - Merge readiness checks
#
# Depends on: rules.sh, io.sh
# IMPURE: Uses git, jq, state machine functions (sm_*)

# Expected environment variables:
# V0_ROOT - Path to project root
# V0_GIT_REMOTE - Git remote name (e.g., "origin")
# BUILD_DIR - Path to build directory
# QUEUE_FILE - Path to queue.json file

# mq_is_branch_merge <operation>
# Check if operation is actually a branch on remote
# Uses git to verify, not just pattern matching
# Returns 0 if branch exists on remote, 1 if not
mq_is_branch_merge() {
    local op="$1"
    # Check if it exists as a branch on remote
    git ls-remote --heads "${V0_GIT_REMOTE}" "${op}" 2>/dev/null | grep -q .
}

# mq_is_branch_ready <branch>
# Check if a bare branch is ready to merge
# Returns 0 if ready (branch exists on remote), 1 if not
mq_is_branch_ready() {
    local branch="$1"

    # Check if branch exists on remote (already verified by mq_is_branch_merge)
    if ! git ls-remote --heads "${V0_GIT_REMOTE}" "${branch}" 2>/dev/null | grep -q .; then
        echo "Branch '${V0_GIT_REMOTE}/${branch}' does not exist" >&2
        return 1
    fi

    return 0
}

# mq_is_stale <operation>
# Check if a queue entry is stale and should be auto-cleaned
# Returns 0 if stale, 1 if not stale
# Outputs reason on stdout if stale
mq_is_stale() {
    local op="$1"
    local state_file="${BUILD_DIR}/operations/${op}/state.json"

    # Check for build operation state
    if [[ -f "${state_file}" ]]; then
        # Check for merged_at - indicates operation claims to be merged
        local merged_at
        merged_at=$(jq -r '.merged_at // empty' "${state_file}")
        if [[ -n "${merged_at}" ]]; then
            # Verify the merge is real using merge_commit
            if v0_verify_merge_by_op "${op}"; then
                echo "already merged at ${merged_at}"
                return 0
            else
                # Claims merged but verification failed - still stale, needs attention
                echo "claims merged but verification failed"
                return 0
            fi
        fi

        # Check if operation was recreated (queue entry older than state)
        # This catches stale queue entries from previously merged operations with same name
        local queue_time state_time
        queue_time=$(jq -r ".entries[] | select(.operation == \"${op}\") | .enqueued_at // empty" "${QUEUE_FILE}" 2>/dev/null)
        state_time=$(jq -r '.created_at // empty' "${state_file}")
        if [[ -n "${queue_time}" ]] && [[ -n "${state_time}" ]]; then
            # String comparison works for ISO 8601 timestamps
            if [[ "${state_time}" > "${queue_time}" ]]; then
                echo "stale queue entry (operation recreated)"
                return 0
            fi
        fi

        return 1
    fi

    # No state file - check if it looks like a branch
    if mq_is_branch_pattern "${op}"; then
        # Branch name pattern - check if branch exists on remote
        # IMPORTANT: Must distinguish between "branch doesn't exist" and "git command failed"
        local ls_output ls_exit
        ls_output=$(git -C "${V0_ROOT}" ls-remote --heads "${V0_GIT_REMOTE}" "${op}" 2>&1)
        ls_exit=$?

        if [[ ${ls_exit} -ne 0 ]]; then
            # git command failed - don't assume stale, could be network/directory issue
            echo "git ls-remote failed (exit ${ls_exit}): ${ls_output}" >&2
            return 1
        fi

        if [[ -z "${ls_output}" ]]; then
            echo "branch no longer exists on remote"
            return 0
        fi
    else
        # Not a branch pattern and no state file = stale
        echo "no state file and not a branch"
        return 0
    fi

    return 1
}

# mq_is_merge_ready <operation>
# Check if an operation is ready to be merged
# Returns 0 if ready, 1 if not ready
# Outputs reason on stderr if not ready
mq_is_merge_ready() {
    local op="$1"
    local state_file="${BUILD_DIR}/operations/${op}/state.json"

    # Check for build operation state
    if [[ -f "${state_file}" ]]; then
        # Must have merge_queued set (not checked by sm_is_merge_ready)
        if [[ "$(jq -r '.merge_queued // false' "${state_file}")" != "true" ]]; then
            echo "merge_queued not set for '${op}'" >&2
            return 1
        fi

        # Use state machine function for remaining checks
        if ! sm_is_merge_ready "${op}"; then
            local reason
            reason=$(sm_merge_ready_reason "${op}")
            echo "${reason}" >&2
            return 1
        fi

        return 0
    fi

    # No state file - check if it's a bare branch merge
    if mq_is_branch_merge "${op}"; then
        mq_is_branch_ready "${op}"
        return $?
    fi

    echo "No state file for '${op}' and not a branch name" >&2
    return 1
}

# mq_dequeue_merge
# Get the next pending merge (by priority, then by enqueue time)
# Outputs the operation name if found, empty if queue is empty
# Returns 0 if found, 1 if not
mq_dequeue_merge() {
    mq_ensure_queue_exists

    local next
    next=$(mq_get_next_pending)

    if [[ -z "${next}" ]]; then
        return 1
    fi

    echo "${next}"
}

# mq_get_all_pending
# Get all pending operations sorted by priority, then enqueue time
# Outputs: One operation name per line
mq_get_all_pending() {
    mq_ensure_queue_exists
    mq_get_pending_operations
}

# mq_get_all_conflicts
# Get all conflict operations
# Outputs: One operation name per line
mq_get_all_conflicts() {
    mq_ensure_queue_exists
    mq_get_operations_by_status "${MQ_STATUS_CONFLICT}"
}
