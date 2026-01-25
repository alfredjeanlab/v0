#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/state-update.sh - Operation state and queue updates
#
# Depends on: v0-common.sh (for sm_* functions)
# IMPURE: Uses state machine functions, v0-mergeq

# Expected environment variables:
# V0_DIR - Path to v0 installation

# mg_update_queue_entry <op_name> <branch>
# Update merge queue entry to reflect successful merge
# Tries both operation name (if available) and branch name
mg_update_queue_entry() {
    local op_name="${1:-}"
    local branch="$2"

    # Try to update by operation name first (if we have one)
    if [[ -n "${op_name}" ]]; then
        "${V0_DIR}/bin/v0-mergeq" --update "${op_name}" "completed" 2>/dev/null || true
    fi
    # Also try by branch name (handles branch merges like fix/xxx)
    "${V0_DIR}/bin/v0-mergeq" --update "${branch}" "completed" 2>/dev/null || true
}

# mg_update_operation_state <branch>
# Update operation state to reflect successful merge
mg_update_operation_state() {
    local branch="$1"

    # Try full branch name first
    local op_name="${branch}"
    if ! sm_state_exists "${op_name}"; then
        # Branch may have prefix like "feature/my-feature" - try just the basename
        op_name=$(basename "${branch}")
        if ! sm_state_exists "${op_name}"; then
            return 0  # No operation state to update
        fi
    fi

    # Use state machine transition to merged state
    sm_transition_to_merged "${op_name}"
}

# mg_record_merge_commit <op_name> <merge_commit>
# Record the merge commit in operation state
mg_record_merge_commit() {
    local op_name="$1"
    local merge_commit="$2"

    if sm_state_exists "${op_name}"; then
        sm_update_state "${op_name}" "merge_commit" "\"${merge_commit}\""
    fi
}

# mg_trigger_dependents <branch>
# Trigger dependent operations after successful merge
mg_trigger_dependents() {
    local branch="$1"
    sm_trigger_dependents "$(basename "${branch}")"
}

# mg_notify_merge <project> <branch> [suffix]
# Send notification about merge completion
mg_notify_merge() {
    local project="$1"
    local branch="$2"
    local suffix="${3:-}"

    if [[ -n "${suffix}" ]]; then
        v0_notify "${project}: merged" "${branch} ${suffix}"
    else
        v0_notify "${project}: merged" "${branch}"
    fi
}

# mg_resolve_op_name <op_name> <branch>
# Resolve operation name from either explicit op_name or branch basename
mg_resolve_op_name() {
    local op_name="${1:-}"
    local branch="$2"

    if [[ -z "${op_name}" ]]; then
        op_name=$(basename "${branch}")
    fi

    if sm_state_exists "${op_name}"; then
        echo "${op_name}"
    fi
}

# mg_finalize_merge <merge_commit> <op_name> <branch> <project> [suffix]
# Execute all post-merge steps: push, record, update state, notify, cleanup
# Returns 0 on success, 1 if push/verify fails
mg_finalize_merge() {
    local merge_commit="$1"
    local op_name="$2"
    local branch="$3"
    local project="$4"
    local suffix="${5:-}"

    if ! mg_push_and_verify "${merge_commit}"; then
        return 1
    fi

    # Record merge commit in operation state
    local op_to_update
    op_to_update=$(mg_resolve_op_name "${op_name}" "${branch}")
    if [[ -n "${op_to_update}" ]]; then
        mg_record_merge_commit "${op_to_update}" "${merge_commit}"
    fi

    # Update operation and queue state
    mg_update_operation_state "${branch}"
    if [[ -z "${V0_MERGEQ_CALLER:-}" ]]; then
        mg_update_queue_entry "${op_name}" "${branch}"
    fi

    # Notify and cleanup
    mg_trigger_dependents "${branch}"
    mg_notify_merge "${project}" "${branch}" "${suffix}"
    mg_delete_remote_branch "${branch}"

    return 0
}
