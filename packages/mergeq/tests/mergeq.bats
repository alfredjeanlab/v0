#!/usr/bin/env bats
# Tests for v0-mergeq - Queue Operations

load '../../test-support/helpers/test_helper'

# Setup for mergeq tests - uses base setup + v0 env + queue file
setup() {
    _base_setup
    setup_v0_env
    # Create empty queue for mergeq tests
    echo '{"version":1,"entries":[]}' > "${QUEUE_FILE}"
}

# Helper to source mergeq functions
source_mergeq() {
    # Source v0-common first
    source "${PROJECT_ROOT}/packages/cli/lib/v0-common.sh"

    # Source the new modular mergeq libraries
    source "${PROJECT_ROOT}/packages/mergeq/lib/rules.sh"
    source "${PROJECT_ROOT}/packages/mergeq/lib/io.sh"
    source "${PROJECT_ROOT}/packages/mergeq/lib/locking.sh"
    source "${PROJECT_ROOT}/packages/mergeq/lib/daemon.sh"
    source "${PROJECT_ROOT}/packages/mergeq/lib/display.sh"

    dequeue_merge() {
        local next
        next=$(mq_get_next_pending)
        if [ -z "${next}" ]; then
            return 1
        fi
        echo "${next}"
    }

    update_entry() { mq_update_entry_status "$@"; }

    # is_stale - Check if a queue entry is stale and should be auto-cleaned
    # Returns 0 if stale, 1 if not stale
    # NOTE: This function uses git and state files - will be moved to readiness.sh in Phase 4
    is_stale() {
        local op="$1"
        local state_file="${BUILD_DIR}/operations/${op}/state.json"

        # Check for build operation state
        if [ -f "${state_file}" ]; then
            # Already merged = stale
            local merged_at
            merged_at=$(jq -r '.merged_at // empty' "${state_file}")
            if [ -n "${merged_at}" ]; then
                echo "already merged at ${merged_at}"
                return 0
            fi
            return 1
        fi

        # No state file - check if it looks like a branch
        if mq_is_branch_pattern "${op}"; then
            # Branch name pattern - check if branch exists on remote
            # IMPORTANT: Must distinguish between "branch doesn't exist" and "git command failed"
            local ls_output ls_exit
            ls_output=$(git -C "${V0_ROOT}" ls-remote --heads origin "${op}" 2>&1)
            ls_exit=$?

            if [ ${ls_exit} -ne 0 ]; then
                # git command failed - don't assume stale, could be network/directory issue
                echo "git ls-remote failed (exit ${ls_exit}): ${ls_output}" >&2
                return 1
            fi

            if [ -z "${ls_output}" ]; then
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

    # Compatibility alias for daemon function
    daemon_running() { mq_daemon_running "$@"; }
}

# ============================================================================
# mq_atomic_queue_update() tests
# ============================================================================

@test "mq_atomic_queue_update modifies queue file" {
    source_mergeq

    # Add an entry using atomic update
    mq_atomic_queue_update '.entries += [{"operation": "test-op", "priority": 0, "status": "pending"}]'

    run jq -r '.entries[0].operation' "${QUEUE_FILE}"
    assert_success
    assert_output "test-op"
}

@test "mq_atomic_queue_update preserves existing data" {
    source_mergeq

    # Add first entry
    mq_atomic_queue_update '.entries += [{"operation": "op1", "priority": 0, "status": "pending"}]'

    # Add second entry
    mq_atomic_queue_update '.entries += [{"operation": "op2", "priority": 1, "status": "pending"}]'

    run jq '.entries | length' "${QUEUE_FILE}"
    assert_success
    assert_output "2"
}

@test "mq_atomic_queue_update handles invalid jq filter" {
    source_mergeq

    run mq_atomic_queue_update 'invalid jq filter {'
    assert_failure
    assert_output --partial "Error"
}

@test "mq_atomic_queue_update is atomic - temp file pattern" {
    source_mergeq

    # Start with known state
    echo '{"version":1,"entries":[{"operation":"existing"}]}' > "${QUEUE_FILE}"

    # Update should preserve version and add entry
    mq_atomic_queue_update '.entries += [{"operation": "new"}]'

    run jq '.version' "${QUEUE_FILE}"
    assert_output "1"

    run jq '.entries | length' "${QUEUE_FILE}"
    assert_output "2"
}

# ============================================================================
# mq_acquire_lock() / mq_release_lock() tests
# ============================================================================

@test "mq_acquire_lock creates lock file" {
    source_mergeq

    mq_acquire_lock

    assert_file_exists "${QUEUE_LOCK}"
}

@test "mq_acquire_lock writes PID to lock file" {
    source_mergeq

    mq_acquire_lock

    run cat "${QUEUE_LOCK}"
    assert_output --partial "pid $$"
}

@test "mq_acquire_lock fails when lock held by running process" {
    source_mergeq

    # Create lock with current PID (simulating another holder)
    echo "other-process (pid $$)" > "${QUEUE_LOCK}"

    run mq_acquire_lock
    assert_failure
    assert_output --partial "lock held by"
}

@test "mq_acquire_lock removes stale lock from dead process" {
    source_mergeq

    # Create lock with non-existent PID
    echo "dead-process (pid 99999999)" > "${QUEUE_LOCK}"

    run mq_acquire_lock
    assert_success
}

@test "mq_release_lock removes lock file" {
    source_mergeq

    mq_acquire_lock
    assert_file_exists "${QUEUE_LOCK}"

    mq_release_lock
    assert_file_not_exists "${QUEUE_LOCK}"
}

# ============================================================================
# dequeue_merge() tests
# ============================================================================

@test "dequeue_merge returns operation from single entry queue" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/single-entry.json" "${QUEUE_FILE}"

    run dequeue_merge
    assert_success
    assert_output "feat-1"
}

@test "dequeue_merge returns empty and fails on empty queue" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/empty-queue.json" "${QUEUE_FILE}"

    run dequeue_merge
    assert_failure
    assert_output ""
}

@test "dequeue_merge returns highest priority entry first" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/multi-priority.json" "${QUEUE_FILE}"

    run dequeue_merge
    assert_success
    assert_output "feat-high"  # priority 0 comes first
}

@test "dequeue_merge uses FIFO for same priority" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/same-priority.json" "${QUEUE_FILE}"

    run dequeue_merge
    assert_success
    assert_output "feat-1"  # Earlier enqueued_at wins
}

@test "dequeue_merge only returns pending entries" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/mixed-status.json" "${QUEUE_FILE}"

    run dequeue_merge
    assert_success
    assert_output "feat-pending"  # Only pending entry
}

@test "dequeue_merge with all non-pending entries returns failure" {
    source_mergeq

    # Create queue with only completed entries
    cat > "${QUEUE_FILE}" <<'EOF'
{"version": 1, "entries": [
  {"operation": "op1", "priority": 0, "status": "completed"},
  {"operation": "op2", "priority": 0, "status": "failed"}
]}
EOF

    run dequeue_merge
    assert_failure
}

# ============================================================================
# update_entry() tests
# ============================================================================

@test "update_entry changes status of existing entry" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/single-entry.json" "${QUEUE_FILE}"

    update_entry "feat-1" "processing"

    run jq -r '.entries[0].status' "${QUEUE_FILE}"
    assert_success
    assert_output "processing"
}

@test "update_entry fails for non-existent operation" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/single-entry.json" "${QUEUE_FILE}"

    run update_entry "nonexistent-op" "processing"
    assert_failure
    assert_output --partial "not found"
}

@test "update_entry adds updated_at timestamp" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/single-entry.json" "${QUEUE_FILE}"

    update_entry "feat-1" "completed"

    run jq -r '.entries[0].updated_at' "${QUEUE_FILE}"
    assert_success
    # Should have a timestamp (not null/empty)
    refute_output "null"
    refute_output ""
}

@test "update_entry requires operation argument" {
    source_mergeq

    run update_entry "" "processing"
    assert_failure
    assert_output --partial "required"
}

@test "update_entry requires status argument" {
    source_mergeq

    run update_entry "feat-1" ""
    assert_failure
    assert_output --partial "required"
}

@test "update_entry preserves other entry fields" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/single-entry.json" "${QUEUE_FILE}"

    update_entry "feat-1" "completed"

    # Original fields should be preserved
    run jq -r '.entries[0].priority' "${QUEUE_FILE}"
    assert_output "0"

    run jq -r '.entries[0].enqueued_at' "${QUEUE_FILE}"
    assert_output "2026-01-15T10:00:00Z"
}

# ============================================================================
# Queue ordering integration tests
# ============================================================================

@test "queue ordering: priority then timestamp" {
    source_mergeq

    # Create queue with specific ordering
    cat > "${QUEUE_FILE}" <<'EOF'
{"version": 1, "entries": [
  {"operation": "low-old", "priority": 10, "status": "pending", "enqueued_at": "2026-01-15T09:00:00Z"},
  {"operation": "high-new", "priority": 0, "status": "pending", "enqueued_at": "2026-01-15T11:00:00Z"},
  {"operation": "high-old", "priority": 0, "status": "pending", "enqueued_at": "2026-01-15T09:00:00Z"},
  {"operation": "mid-old", "priority": 5, "status": "pending", "enqueued_at": "2026-01-15T09:00:00Z"}
]}
EOF

    # First should be high-old (priority 0, oldest timestamp)
    run dequeue_merge
    assert_output "high-old"
}

@test "multiple dequeues return operations in priority order" {
    source_mergeq

    cp "${TESTS_DIR}/fixtures/queues/multi-priority.json" "${QUEUE_FILE}"

    # Get first (highest priority)
    local first
    first=$(dequeue_merge)
    assert_equal "${first}" "feat-high"

    # Mark it as processing so it's not returned again
    update_entry "feat-high" "processing"

    # Get second
    local second
    second=$(dequeue_merge)
    assert_equal "${second}" "feat-mid"

    # Mark it as processing
    update_entry "feat-mid" "processing"

    # Get third
    local third
    third=$(dequeue_merge)
    assert_equal "${third}" "feat-low"
}

# ============================================================================
# is_stale() tests - Regression tests for git command failure handling
# ============================================================================

@test "is_stale returns not-stale for operation with state file (no merged_at)" {
    source_mergeq

    # Create operation state without merged_at
    create_operation_state "test-op" '{"name": "test-op", "phase": "building"}'

    run is_stale "test-op"
    assert_failure  # Return 1 = not stale
}

@test "is_stale returns stale for operation with merged_at in state" {
    source_mergeq

    # Create operation state with merged_at
    create_operation_state "test-op" '{"name": "test-op", "phase": "merged", "merged_at": "2026-01-15T10:00:00Z"}'

    run is_stale "test-op"
    assert_success  # Return 0 = stale
    assert_output --partial "already merged"
}

@test "is_stale returns stale for non-branch operation without state file" {
    source_mergeq

    # No state file, not a branch pattern (no slash)
    run is_stale "simple-op"
    assert_success  # Return 0 = stale
    assert_output --partial "no state file"
}

@test "is_stale does NOT mark branch as stale when git command fails" {
    source_mergeq

    # Set V0_ROOT to a non-existent directory so git commands fail
    export V0_ROOT="/nonexistent/path"

    # Branch pattern but git will fail
    run is_stale "fix/test-branch"
    assert_failure  # Return 1 = NOT stale (git failed, don't assume stale)
}

@test "is_stale does NOT mark branch as stale when not in git repo" {
    source_mergeq

    # V0_ROOT is TEST_TEMP_DIR/project which is not a git repo
    # git ls-remote will fail

    run is_stale "fix/test-branch"
    assert_failure  # Return 1 = NOT stale
}

@test "is_stale marks branch as stale when branch genuinely doesn't exist" {
    source_mergeq

    # Initialize a real git repo with a remote
    init_mock_git_repo "${V0_ROOT}"

    # Add a fake remote (local bare repo)
    local remote_dir="${TEST_TEMP_DIR}/remote.git"
    mkdir -p "${remote_dir}"
    (git init --bare "${remote_dir}" || true) >/dev/null 2>&1
    (cd "${V0_ROOT}" && git remote add origin "${remote_dir}" && git push -u origin main) >/dev/null 2>&1 || true

    # Branch doesn't exist on remote - should be stale
    run is_stale "fix/nonexistent-branch"
    assert_success  # Return 0 = stale
    assert_output --partial "branch no longer exists"
}

@test "is_stale does NOT mark branch as stale when branch exists on remote" {
    source_mergeq

    # Initialize a real git repo with a remote
    init_mock_git_repo "${V0_ROOT}"

    # Add a fake remote (local bare repo)
    local remote_dir="${TEST_TEMP_DIR}/remote.git"
    mkdir -p "${remote_dir}"
    (git init --bare "${remote_dir}" || true) >/dev/null 2>&1
    (
        cd "${V0_ROOT}" || exit 1
        git remote add origin "${remote_dir}"
        git push -u origin main
        # Create and push a fix branch
        git checkout -b fix/existing-branch
        echo "fix" > fix.txt
        git add fix.txt
        git commit -m "Fix"
        git push origin fix/existing-branch
        git checkout main
    ) >/dev/null 2>&1 || true

    # Branch exists on remote - should NOT be stale
    run is_stale "fix/existing-branch"
    assert_failure  # Return 1 = NOT stale
}

# ============================================================================
# Daemon locking tests - Regression tests for multiple daemon prevention
# ============================================================================

@test "daemon_running returns false when no PID file exists" {
    source_mergeq

    export DAEMON_PID_FILE="${MERGEQ_DIR}/.daemon.pid"
    rm -f "${DAEMON_PID_FILE}"

    run daemon_running
    assert_failure
}

@test "daemon_running returns false when PID file is empty" {
    source_mergeq

    export DAEMON_PID_FILE="${MERGEQ_DIR}/.daemon.pid"
    echo "" > "${DAEMON_PID_FILE}"

    run daemon_running
    assert_failure
}

@test "daemon_running returns false when PID process doesn't exist" {
    source_mergeq

    export DAEMON_PID_FILE="${MERGEQ_DIR}/.daemon.pid"
    # Use a PID that definitely doesn't exist
    echo "99999999" > "${DAEMON_PID_FILE}"

    run daemon_running
    assert_failure
}

@test "daemon_running returns true when PID process exists" {
    source_mergeq

    export DAEMON_PID_FILE="${MERGEQ_DIR}/.daemon.pid"
    # Use current shell's PID (definitely exists)
    echo "$$" > "${DAEMON_PID_FILE}"

    run daemon_running
    assert_success
}
