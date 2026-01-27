#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/processing.sh - Merge execution logic
#
# Depends on: rules.sh, io.sh, locking.sh, display.sh, readiness.sh, resolution.sh
# IMPURE: Uses git, jq, state machine functions, v0-merge

# Expected environment variables:
# V0_DIR - Path to v0 installation
# V0_ROOT - Path to project root
# V0_WORKSPACE_DIR - Path to workspace directory for merge operations
# V0_GIT_REMOTE - Git remote name
# V0_DEVELOP_BRANCH - Main development branch name
# BUILD_DIR - Path to build directory
# MERGEQ_DIR - Directory for merge queue state

# mq_enqueue <operation> [priority] [issue_id]
# Add an operation to the merge queue
# Returns 0 on success, 1 on failure
mq_enqueue() {
    local operation="$1"
    local priority="${2:-0}"
    local issue_id="${3:-}"

    if [[ -z "${operation}" ]]; then
        echo "Error: Operation name required" >&2
        return 1
    fi

    v0_trace "mergeq:enqueue" "Enqueueing ${operation} (priority: ${priority}, issue: ${issue_id:-none})"
    mq_ensure_queue_exists

    # Retry lock acquisition with backoff to handle contention
    if ! mq_acquire_lock_with_retry 5 1; then
        return 1
    fi

    # Check if already in queue
    local existing_status
    existing_status=$(mq_get_entry_status "${operation}")
    if mq_is_active_status "${existing_status}"; then
        echo "Operation '${operation}' already in queue" >&2
        mq_release_lock
        mq_ensure_daemon_running
        return 0
    fi

    # If there's an existing entry with inactive status, re-enqueue it
    if [[ -n "${existing_status}" ]]; then
        mq_reenqueue_entry "${operation}" "${priority}"
        mq_release_lock

        mq_log_event "re-enqueue: ${operation} (was ${existing_status}, priority: ${priority})"
        mq_emit_event "merge:queued" "${operation}"
        echo "Re-enqueued: ${operation} (was ${existing_status})"

        ensure_nudge_running 2>/dev/null || true
        mq_ensure_daemon_running
        return 0
    fi

    # Get worktree path and detect merge type
    local worktree=""
    local merge_type
    merge_type=$(mq_default_merge_type "${operation}")

    # Check for build operation
    local state_file="${BUILD_DIR}/operations/${operation}/state.json"
    if [[ -f "${state_file}" ]]; then
        worktree=$(jq -r '.worktree // empty' "${state_file}")
        merge_type="operation"
    fi

    # Add to queue
    mq_add_entry "${operation}" "${worktree}" "${priority}" "${merge_type}" "${issue_id}"
    mq_release_lock

    # Log the event
    mq_log_event "enqueue: ${operation} (priority: ${priority}, type: ${merge_type})"
    mq_emit_event "merge:queued" "${operation}"
    echo "Enqueued: ${operation}"

    # Ensure nudge worker is running to monitor sessions
    ensure_nudge_running 2>/dev/null || true

    # Auto-start daemon if not running
    mq_ensure_daemon_running
}

# mq_process_branch_merge <branch>
# Process a simple branch merge (no state file, just merge from remote)
# Returns 0 on success, 1 on failure
mq_process_branch_merge() {
    local branch="$1"

    local issue_id
    issue_id=$(mq_get_issue_id "${branch}")

    v0_trace "mergeq:branch" "Processing branch merge: ${branch} (issue: ${issue_id:-none})"
    echo "[$(date +%H:%M:%S)] Processing branch merge: ${branch}"
    if [[ -n "${issue_id}" ]]; then
        echo "[$(date +%H:%M:%S)] Associated issue: ${issue_id}"
    fi
    mq_log_event "merge:started: ${branch} (branch)"
    mq_emit_event "merge:started" "${branch}"

    # Ensure workspace exists
    if ! ws_ensure_workspace; then
        echo "[$(date +%H:%M:%S)] Failed to create workspace" >&2
        mq_update_entry_status "${branch}" "${MQ_STATUS_FAILED}"
        mq_log_event "merge:failed: ${branch} (workspace creation failed)"
        mq_emit_event "merge:failed" "${branch}"
        return 1
    fi

    # Use explicit -C flag for all git operations to ensure we're in the workspace
    # This avoids issues with cwd being in the wrong directory
    local ws="${V0_WORKSPACE_DIR}"

    # Ensure we're on the develop branch
    local current_branch
    current_branch=$(git -C "${ws}" rev-parse --abbrev-ref HEAD)
    if [[ "${current_branch}" != "${V0_DEVELOP_BRANCH}" ]]; then
        echo "[$(date +%H:%M:%S)] Switching to ${V0_DEVELOP_BRANCH} (was on ${current_branch})"
        if ! git -C "${ws}" checkout "${V0_DEVELOP_BRANCH}" 2>&1 | tee -a "${MERGEQ_DIR}/logs/merges.log"; then
            echo "[$(date +%H:%M:%S)] Failed to checkout ${V0_DEVELOP_BRANCH}" >&2
            mq_update_entry_status "${branch}" "${MQ_STATUS_FAILED}"
            mq_log_event "merge:failed: ${branch} (checkout failed)"
            mq_emit_event "merge:failed" "${branch}"
            return 1
        fi
    fi

    # Pull latest develop branch to stay current
    git -C "${ws}" pull --ff-only "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>&1 | tee -a "${MERGEQ_DIR}/logs/merges.log" || true

    # Clean up any incomplete merge/rebase state from previous failed attempts
    ws_abort_incomplete_operations "${ws}"

    # Fetch latest
    if ! git -C "${ws}" fetch "${V0_GIT_REMOTE}" "${branch}" 2>&1 | tee -a "${MERGEQ_DIR}/logs/merges.log"; then
        echo "[$(date +%H:%M:%S)] Failed to fetch ${branch}" >&2
        mq_update_entry_status "${branch}" "${MQ_STATUS_FAILED}"
        mq_log_event "merge:failed: ${branch} (fetch failed)"
        mq_emit_event "merge:failed" "${branch}"
        return 1
    fi

    # Try to merge
    # OK: Capture exit code without aborting script
    set +e
    local merge_output
    merge_output=$(git -C "${ws}" merge --no-edit "${V0_GIT_REMOTE}/${branch}" 2>&1)
    local merge_exit=$?
    set -e

    echo "${merge_output}" | tee -a "${MERGEQ_DIR}/logs/merges.log"

    if [[ ${merge_exit} -eq 0 ]]; then
        # Success - push to remote
        v0_trace "mergeq:branch:push" "Pushing merged changes for ${branch}"
        echo "Pushing merged changes..."
        if ! git -C "${ws}" push "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>&1 | tee -a "${MERGEQ_DIR}/logs/merges.log"; then
            v0_trace "mergeq:branch:failed" "Push failed for ${branch}"
            echo "[$(date +%H:%M:%S)] Push failed for ${branch}" >&2
            mq_update_entry_status "${branch}" "${MQ_STATUS_FAILED}"
            mq_log_event "merge:failed: ${branch} (push failed)"
            mq_emit_event "merge:failed" "${branch}"
            return 1
        fi

        # Delete the merged branch
        echo "Deleting merged branch ${V0_GIT_REMOTE}/${branch}..."
        git -C "${ws}" push "${V0_GIT_REMOTE}" --delete "${branch}" 2>&1 | tee -a "${MERGEQ_DIR}/logs/merges.log" || true

        v0_trace "mergeq:branch:success" "Branch merge completed: ${branch}"
        mq_update_entry_status "${branch}" "${MQ_STATUS_COMPLETED}"
        mq_log_event "merge:completed: ${branch} (branch)"
        mq_emit_event "merge:completed" "${branch}"
        echo "[$(date +%H:%M:%S)] Merge completed: ${branch}"

        # Trigger dependent operations now that this issue is merged
        if [[ -n "${issue_id}" ]]; then
            v0_trace "mergeq:dependents" "Triggering dependents for issue ${issue_id}"
            mq_trigger_dependents_by_issue "${issue_id}"
        fi

        return 0
    else
        # Conflict detected - attempt automatic resolution with AI
        v0_trace "mergeq:branch:conflict" "Conflicts detected for ${branch}, attempting resolution"
        echo "[$(date +%H:%M:%S)] Merge has conflicts, attempting automatic resolution..."
        mq_log_event "merge:resolving: ${branch} (branch)"
        mq_emit_event "merge:resolving" "${branch}"

        local resolve_session
        resolve_session=$(mq_launch_branch_conflict_resolution "${branch}")

        if mq_wait_for_resolution "${branch}" "${resolve_session}" 300; then
            v0_trace "mergeq:branch:resolved" "Conflict resolution succeeded for ${branch}"
            mq_update_entry_status "${branch}" "${MQ_STATUS_COMPLETED}"
            mq_log_event "merge:completed: ${branch} (branch, after resolution)"
            mq_emit_event "merge:completed" "${branch}"
            echo "[$(date +%H:%M:%S)] Merge completed (after automatic resolution): ${branch}"

            # Trigger dependent operations now that this issue is merged
            if [[ -n "${issue_id}" ]]; then
                v0_trace "mergeq:dependents" "Triggering dependents for issue ${issue_id}"
                mq_trigger_dependents_by_issue "${issue_id}"
            fi

            return 0
        fi

        # Resolution failed or timed out
        v0_trace "mergeq:branch:conflict:failed" "Resolution failed for ${branch}"
        mq_update_entry_status "${branch}" "${MQ_STATUS_CONFLICT}"
        mq_log_event "merge:conflict: ${branch} (branch, resolution failed)"
        mq_emit_event "merge:conflict" "${branch}"
        echo "[$(date +%H:%M:%S)] Automatic resolution failed: ${branch}"
        echo "  To resolve manually:"
        echo "    git fetch ${V0_GIT_REMOTE} ${branch}"
        echo "    git merge ${V0_GIT_REMOTE}/${branch}"
        echo "    # resolve conflicts"
        echo "    git push ${V0_GIT_REMOTE} HEAD:${V0_DEVELOP_BRANCH}"
        return 1
    fi
}

# mq_process_merge <operation>
# Process a single merge operation
# Returns 0 on success, 1 on failure
mq_process_merge() {
    local op="$1"
    local state_file="${BUILD_DIR}/operations/${op}/state.json"

    v0_trace "mergeq:process" "Processing merge for operation: ${op}"

    # Check if it's a bare branch merge (no state file)
    if [[ ! -f "${state_file}" ]]; then
        if mq_is_branch_merge "${op}"; then
            v0_trace "mergeq:process" "Delegating to branch merge for ${op}"
            mq_process_branch_merge "${op}"
            return $?
        else
            v0_trace "mergeq:process:failed" "No state file and not a branch: ${op}"
            echo "Error: No state file for '${op}' and not a branch name" >&2
            mq_update_entry_status "${op}" "${MQ_STATUS_FAILED}"
            return 1
        fi
    fi

    v0_trace "mergeq:operation" "Processing operation merge: ${op}"
    echo "[$(date +%H:%M:%S)] Processing merge: ${op}"
    mq_log_event "merge:started: ${op}"
    mq_emit_event "merge:started" "${op}"

    # Get worktree path and branch
    local worktree branch
    worktree=$(jq -r '.worktree // empty' "${state_file}")
    branch=$(jq -r '.branch // empty' "${state_file}")

    # Determine merge target - worktree if exists, otherwise operation name (v0-merge handles branch-only)
    local merge_target=""
    if [[ -n "${worktree}" ]] && [[ -d "${worktree}" ]]; then
        merge_target="${worktree}"
    elif [[ -n "${branch}" ]]; then
        # No worktree but have branch - check if branch exists
        if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null || \
           git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
            echo "[$(date +%H:%M:%S)] Merging without worktree (branch: ${branch})"
            merge_target="${op}"
        fi
    fi

    if [[ -z "${merge_target}" ]]; then
        echo "Error: Worktree not found and branch doesn't exist: ${branch}" >&2
        mq_update_entry_status "${op}" "${MQ_STATUS_FAILED}"
        sm_update_state "${op}" "merge_status" '"failed"'
        sm_update_state "${op}" "merge_error" '"Worktree not found and branch does not exist"'
        mq_log_event "merge:failed: ${op} (worktree not found, branch missing)"
        mq_emit_event "merge:failed" "${op}"
        return 1
    fi

    # Update state to show merge in progress
    sm_update_state "${op}" "merge_status" '"merging"'

    # Try to merge using v0 merge --resolve
    # OK: Capture exit code without aborting script
    set +e
    local merge_output
    merge_output=$(V0_MERGEQ_CALLER=1 "${V0_DIR}/bin/v0-merge" "${merge_target}" --resolve 2>&1)
    local merge_exit=$?
    set -e

    echo "${merge_output}" | tee -a "${MERGEQ_DIR}/logs/merges.log"

    if [[ ${merge_exit} -eq 0 ]]; then
        # Verify the merge actually happened with retry logic
        v0_trace "mergeq:operation:verify" "Verifying merge for ${op}"

        local verify_attempts=0
        local verified=false
        while [[ ${verify_attempts} -lt 3 ]] && [[ "${verified}" = false ]]; do
            sleep $((1 + verify_attempts))  # Increasing delay: 1s, 2s, 3s

            if v0_verify_merge_by_op "${op}" "true"; then
                verified=true
            else
                verify_attempts=$((verify_attempts + 1))
                v0_trace "mergeq:operation:verify" "Verification attempt ${verify_attempts} failed, fetching and retrying..."
                git -C "${V0_WORKSPACE_DIR}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
            fi
        done

        if [[ "${verified}" = false ]]; then
            local merge_commit
            merge_commit=$(sm_read_state "${op}" "merge_commit")

            if [[ -z "${merge_commit}" ]] || [[ "${merge_commit}" = "null" ]]; then
                v0_trace "mergeq:operation:verify:failed" "No merge_commit recorded for ${op}"
                echo "[$(date +%H:%M:%S)] Warning: v0-merge exited 0 but no merge_commit recorded"
                sm_update_state "${op}" "merge_error" '"No merge_commit in state - possible v0-merge bug"'
            else
                v0_trace "mergeq:operation:verify:failed" "Commit ${merge_commit:0:8} not on ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH} after ${verify_attempts} attempts"
                echo "[$(date +%H:%M:%S)] Warning: v0-merge exited 0 but commit ${merge_commit:0:8} not on ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}"
                sm_update_state "${op}" "merge_error" "\"Commit ${merge_commit} not found on ${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}\""
            fi

            sm_update_state "${op}" "merge_status" '"verification_failed"'
            mq_update_entry_status "${op}" "${MQ_STATUS_FAILED}"
            mq_log_event "merge:verification_failed: ${op}"
            mq_emit_event "merge:verification_failed" "${op}"
            return 1
        fi

        # Verified - mark as merged (this also marks wok epic as done to unblock dependents)
        v0_trace "mergeq:operation:success" "Merge verified and completed: ${op}"
        sm_transition_to_merged "${op}"
        mq_update_entry_status "${op}" "${MQ_STATUS_COMPLETED}"
        mq_log_event "merge:completed: ${op}"
        mq_emit_event "merge:completed" "${op}"
        echo "[$(date +%H:%M:%S)] Merge completed: ${op}"

        # Archive the plan file
        local plan_file
        plan_file=$(jq -r '.plan_file // empty' "${state_file}")
        if [[ -n "${plan_file}" ]]; then
            if archive_plan "${plan_file}" 2>/dev/null; then
                local archive_date plan_name
                archive_date=$(date +%Y-%m-%d)
                plan_name=$(basename "${plan_file}")
                sm_update_state "${op}" "archived_plan" "\"${V0_PLANS_DIR}/archive/${archive_date}/${plan_name}\""
                echo "[$(date +%H:%M:%S)] Archived plan: ${plan_file}"
            fi
        fi

        # Trigger dependent operations (wok epic already marked done above)
        local dep_op
        for dep_op in $(sm_find_dependents "${op}" 2>/dev/null); do
            echo "[$(date +%H:%M:%S)] Unblocking dependent operation: ${dep_op}"
            mq_resume_waiting_operation "${dep_op}"
        done

        return 0
    else
        # Merge with --resolve failed - mark as conflict
        v0_trace "mergeq:operation:conflict" "Merge failed for ${op}, automatic resolution failed"
        mq_update_entry_status "${op}" "${MQ_STATUS_CONFLICT}"
        sm_update_state "${op}" "merge_status" '"conflict"'
        sm_update_state "${op}" "merge_error" '"Automatic resolution failed"'
        mq_log_event "merge:conflict: ${op} (resolution failed)"
        mq_emit_event "merge:conflict" "${op}"
        echo "[$(date +%H:%M:%S)] Automatic resolution failed: ${op}"
        echo "  Manual resolution needed: v0 merge ${worktree} --resolve"
        return 1
    fi
}

# mq_resume_waiting_operation <operation>
# Resume an operation that was waiting and is now unblocked
mq_resume_waiting_operation() {
    local op="$1"

    if ! sm_state_exists "${op}"; then
        echo "Warning: No state file for dependent operation '${op}'" >&2
        return 1
    fi

    # Check if held before resuming
    if sm_is_held "${op}" 2>/dev/null; then
        sm_emit_event "${op}" "unblock:held" "Dependency merged but operation held" 2>/dev/null || true
        echo "[$(date +%H:%M:%S)] Operation '${op}' remains held"
        return 0
    fi

    # Note: Blocking is tracked in wok, not state.json
    # When the blocker's epic is marked done, wok automatically unblocks dependents

    echo "[$(date +%H:%M:%S)] Resuming operation: ${op}"
    mq_log_event "unblock:resumed: ${op}"
    mq_emit_event "unblock:triggered" "${op}"

    # Resume the operation in background
    "${V0_DIR}/bin/v0-feature" "${op}" --resume &
}

# mq_trigger_dependents_by_issue <issue_id>
# Find and resume operations blocked by the given issue
# Used for branch merges where we have the issue_id but no operation state
mq_trigger_dependents_by_issue() {
    local issue_id="$1"
    [[ -z "${issue_id}" ]] && return 0

    # Query wok for issues that this one blocks
    local blocking_ids
    blocking_ids=$(wk show "${issue_id}" -o json 2>/dev/null | jq -r '.blocking // [] | .[]')
    [[ -z "${blocking_ids}" ]] && return 0

    local blocked_id
    for blocked_id in ${blocking_ids}; do
        # Resolve to operation name
        local op_name
        op_name=$(v0_blocker_to_op_name "${blocked_id}")

        # Check if this is a known operation with a state file
        if [[ -f "${BUILD_DIR}/operations/${op_name}/state.json" ]]; then
            echo "[$(date +%H:%M:%S)] Unblocking dependent operation: ${op_name}"
            mq_resume_waiting_operation "${op_name}"
        fi
    done
}

# mq_process_once
# Process a single pending merge and exit
mq_process_once() {
    mq_ensure_queue_exists

    local op
    op=$(mq_dequeue_merge) || {
        echo "No pending merges in queue"
        return 0
    }

    echo "Found pending merge: ${op}"

    if ! mq_is_merge_ready "${op}"; then
        echo "Operation '${op}' is not ready to merge"
        return 1
    fi

    mq_update_entry_status "${op}" "${MQ_STATUS_PROCESSING}"
    mq_process_merge "${op}"
}

# mq_recover_stuck_processing
# Reset any PROCESSING entries to PENDING
# Called at daemon startup to recover from crashes
mq_recover_stuck_processing() {
    local processing_ops
    processing_ops=$(mq_get_operations_by_status "${MQ_STATUS_PROCESSING}")

    if [[ -n "${processing_ops}" ]]; then
        for op in ${processing_ops}; do
            echo "[$(date +%H:%M:%S)] Recovering stuck entry: ${op} (was processing, now pending)"
            mq_update_entry_status "${op}" "${MQ_STATUS_PENDING}"
            mq_log_event "recovery:stuck: ${op} (processing -> pending)"
        done
    fi
}

# mq_process_watch
# Continuous mode - poll for ready operations
mq_process_watch() {
    mq_ensure_queue_exists

    local poll_interval=30

    v0_trace "mergeq:watch" "Starting merge queue watch loop (poll: ${poll_interval}s)"
    echo "[$(date +%H:%M:%S)] Starting merge queue daemon (poll interval: ${poll_interval}s)"
    mq_log_event "daemon:started"

    # Recover any entries stuck in PROCESSING from previous crashed runs
    mq_recover_stuck_processing

    # Log clean exit on termination
    _mq_cleanup_daemon() {
        echo "[$(date +%H:%M:%S)] Stopping daemon"
        exit 0
    }
    trap _mq_cleanup_daemon INT TERM

    while true; do
        # Validate workspace health at start of each poll cycle
        if ! ws_validate 2>/dev/null; then
            v0_trace "mergeq:daemon" "Workspace invalid, attempting recovery"
            echo "[$(date +%H:%M:%S)] Warning: workspace invalid, attempting recovery"
            if ! ws_ensure_workspace 2>/dev/null; then
                echo "[$(date +%H:%M:%S)] Error: workspace recovery failed, sleeping"
                v0_trace "mergeq:daemon" "Workspace recovery failed, sleeping 60s"
                sleep 60
                continue
            fi
            v0_trace "mergeq:daemon" "Workspace recovered successfully"
        fi

        # Check for conflict entries that can be retried
        local conflict_ops
        conflict_ops=$(mq_get_all_conflicts)
        for op in ${conflict_ops}; do
            local state_file="${BUILD_DIR}/operations/${op}/state.json"
            if [[ -f "${state_file}" ]]; then
                local conflict_retried
                conflict_retried=$(jq -r '.conflict_retried // false' "${state_file}" 2>/dev/null)
                if [[ "${conflict_retried}" != "true" ]]; then
                    echo "[$(date +%H:%M:%S)] Auto-retrying conflict resolution: ${op}"
                    sm_update_state "${op}" "conflict_retried" "true"
                    sm_update_state "${op}" "merge_status" "null"
                    mq_update_entry_status "${op}" "${MQ_STATUS_PENDING}"
                    mq_log_event "conflict:retry: ${op}"
                fi
            fi
        done

        # Get all pending operations and find the first ready one
        local found_ready=false
        local pending_ops
        pending_ops=$(mq_get_all_pending)
        local pending_count
        if [[ -z "${pending_ops}" ]]; then
            pending_count=0
        else
            pending_count=$(echo "${pending_ops}" | wc -l | tr -d ' \n')
        fi

        if [[ "${pending_count}" -eq 0 ]]; then
            echo "[$(date +%H:%M:%S)] Waiting... (no pending merges)"
            sleep "${poll_interval}"
            continue
        fi

        # Fetch remote refs before checking readiness to ensure branch existence
        # checks in _sm_resolve_merge_branch are accurate. Without this, operations
        # may appear unready because their remote tracking refs are stale.
        v0_trace "mergeq:fetch" "Fetching from ${V0_GIT_REMOTE} in ${V0_WORKSPACE_DIR}"
        local fetch_attempts=0
        while ! git -C "${V0_WORKSPACE_DIR}" fetch "${V0_GIT_REMOTE}" --prune 2>&1; do
            fetch_attempts=$((fetch_attempts + 1))
            if [[ ${fetch_attempts} -ge 3 ]]; then
                echo "[$(date +%H:%M:%S)] Warning: fetch failed after 3 attempts, refs may be stale"
                v0_trace "mergeq:fetch" "Fetch failed after 3 attempts"
                break
            fi
            v0_trace "mergeq:fetch" "Fetch attempt ${fetch_attempts} failed, retrying..."
            sleep 2
        done

        local not_ready_reasons=""
        for op in ${pending_ops}; do
            # Check if entry is stale
            local stale_reason
            if stale_reason=$(mq_is_stale "${op}"); then
                echo "[$(date +%H:%M:%S)] Cleaning stale entry: ${op} (${stale_reason})"
                mq_update_entry_status "${op}" "${MQ_STATUS_COMPLETED}"
                mq_log_event "stale:cleaned: ${op} (${stale_reason})"
                continue
            fi

            # Check if it's ready
            local ready_check
            if ready_check=$(mq_is_merge_ready "${op}" 2>&1); then
                echo "[$(date +%H:%M:%S)] Processing: ${op}"
                found_ready=true

                mq_update_entry_status "${op}" "${MQ_STATUS_PROCESSING}"

                if mq_process_merge "${op}"; then
                    echo "[$(date +%H:%M:%S)] Successfully merged: ${op}"
                else
                    echo "[$(date +%H:%M:%S)] Failed to merge: ${op}"
                fi

                sleep 2
                break
            else
                # Handle special cases for not-ready operations
                if [[ "${ready_check}" == open_issues:* ]]; then
                    local state_file="${BUILD_DIR}/operations/${op}/state.json"
                    local already_resumed
                    already_resumed=$(jq -r '.merge_resumed // false' "${state_file}" 2>/dev/null)

                    local open_count in_progress_count
                    open_count=$(echo "${ready_check}" | cut -d: -f2)
                    in_progress_count=$(echo "${ready_check}" | cut -d: -f3)

                    if [[ "${already_resumed}" != "true" ]]; then
                        echo "[$(date +%H:%M:%S)] Auto-resuming ${op} (${open_count} open, ${in_progress_count} in progress)"
                        sm_update_state "${op}" "merge_resumed" "true"
                        sm_update_state "${op}" "merge_queued" "false"
                        mq_update_entry_status "${op}" "${MQ_STATUS_RESUMED}"
                        mq_log_event "auto-resume: ${op} (${open_count} open)"
                        nohup "${V0_DIR}/bin/v0-feature" "${op}" --resume queued >> "${BUILD_DIR}/operations/${op}/logs/resume.log" 2>&1 &
                        found_ready=true
                        continue
                    else
                        ready_check="open issues (${open_count} open, ${in_progress_count} in progress) - already resumed once"
                    fi
                elif [[ "${ready_check}" == "worktree:missing" ]] || [[ "${ready_check}" == "branch:missing" ]]; then
                    local state_file="${BUILD_DIR}/operations/${op}/state.json"
                    local already_marked
                    already_marked=$(jq -r '.worktree_missing // false' "${state_file}" 2>/dev/null)

                    if [[ "${already_marked}" != "true" ]]; then
                        echo "[$(date +%H:%M:%S)] Skipping ${op}: ${ready_check} - needs manual recovery"
                        mq_log_event "skip-no-worktree: ${op} (${ready_check})"
                        sm_update_state "${op}" "worktree_missing" "true"
                    fi
                    ready_check="${ready_check} - needs manual recovery"
                fi

                not_ready_reasons="${not_ready_reasons}  - ${op}: ${ready_check}"$'\n'
            fi
        done

        if [[ "${found_ready}" = false ]]; then
            echo "[$(date +%H:%M:%S)] Waiting... (${pending_count} pending, none ready)"
            if [[ -n "${not_ready_reasons}" ]]; then
                echo "${not_ready_reasons}" | head -5
                if [[ "${pending_count}" -gt 5 ]]; then
                    echo "  ... and $((pending_count - 5)) more"
                fi
            fi
            sleep "${poll_interval}"
        fi
    done
}
