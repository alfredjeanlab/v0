#!/usr/bin/env bats
# Tests for lib/state-machine.sh - Centralized state machine functions

load '../helpers/test_helper'

# Setup for state machine tests
setup() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/mergeq"
    mkdir -p "${TEST_TEMP_DIR}/state"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"

    export V0_TEST_MODE=1

    cd "${TEST_TEMP_DIR}/project" || return 1
    export ORIGINAL_PATH="${PATH}"

    create_v0rc "testproject" "testp"

    export V0_ROOT="${TEST_TEMP_DIR}/project"
    export PROJECT="testproject"
    export ISSUE_PREFIX="testp"
    export BUILD_DIR="${TEST_TEMP_DIR}/project/.v0/build"
    export V0_DIR="${PROJECT_ROOT}"

    # Source the state machine library
    source "${PROJECT_ROOT}/lib/state-machine.sh"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"

    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# Helper to create an operation state file
create_test_state() {
    local op="$1"
    local phase="$2"
    local extra="${3:-}"
    local op_dir="${BUILD_DIR}/operations/${op}"
    mkdir -p "${op_dir}/logs"

    if [[ -n "${extra}" ]]; then
        echo "{\"name\": \"${op}\", \"phase\": \"${phase}\", ${extra}}" > "${op_dir}/state.json"
    else
        echo "{\"name\": \"${op}\", \"phase\": \"${phase}\"}" > "${op_dir}/state.json"
    fi
}

# ============================================================================
# State File Operations Tests
# ============================================================================

@test "sm_get_state_file returns correct path" {
    run sm_get_state_file "my-feature"
    assert_success
    assert_output "${BUILD_DIR}/operations/my-feature/state.json"
}

@test "sm_state_exists returns true for existing state" {
    create_test_state "test-op" "init"

    run sm_state_exists "test-op"
    assert_success
}

@test "sm_state_exists returns false for missing state" {
    run sm_state_exists "nonexistent"
    assert_failure
}

@test "sm_read_state retrieves existing field" {
    create_test_state "test-op" "executing"

    run sm_read_state "test-op" "phase"
    assert_success
    assert_output "executing"
}

@test "sm_read_state returns empty for missing field" {
    create_test_state "test-op" "init"

    run sm_read_state "test-op" "nonexistent"
    assert_success
    assert_output ""
}

@test "sm_read_state returns failure for missing state file" {
    run sm_read_state "nonexistent" "phase"
    assert_failure
}

@test "sm_update_state modifies single field" {
    create_test_state "test-op" "init"

    sm_update_state "test-op" "phase" '"planned"'

    run sm_read_state "test-op" "phase"
    assert_output "planned"
}

@test "sm_update_state preserves other fields" {
    create_test_state "test-op" "init" '"prompt": "Build feature"'

    sm_update_state "test-op" "phase" '"planned"'

    run sm_read_state "test-op" "prompt"
    assert_output "Build feature"
}

@test "sm_update_state can set null values" {
    create_test_state "test-op" "init" '"worktree": "/some/path"'

    sm_update_state "test-op" "worktree" 'null'

    run jq -r '.worktree' "${BUILD_DIR}/operations/test-op/state.json"
    assert_output "null"
}

@test "sm_bulk_update_state updates multiple fields atomically" {
    create_test_state "test-op" "init"

    sm_bulk_update_state "test-op" \
        "phase" '"planned"' \
        "plan_file" '"plans/test.md"' \
        "updated_at" '"2026-01-15T10:00:00Z"'

    run sm_read_state "test-op" "phase"
    assert_output "planned"

    run sm_read_state "test-op" "plan_file"
    assert_output "plans/test.md"

    run sm_read_state "test-op" "updated_at"
    assert_output "2026-01-15T10:00:00Z"
}

@test "sm_get_phase returns current phase" {
    create_test_state "test-op" "executing"

    run sm_get_phase "test-op"
    assert_success
    assert_output "executing"
}

# ============================================================================
# Event Logging Tests
# ============================================================================

@test "sm_emit_event creates log entry" {
    create_test_state "test-op" "init"

    sm_emit_event "test-op" "test:event" "Test details"

    run cat "${BUILD_DIR}/operations/test-op/logs/events.log"
    assert_success
    assert_output --partial "test:event"
    assert_output --partial "Test details"
}

@test "sm_emit_event creates log directory if missing" {
    local op_dir="${BUILD_DIR}/operations/new-op"
    mkdir -p "${op_dir}"
    echo '{"name": "new-op", "phase": "init"}' > "${op_dir}/state.json"

    sm_emit_event "new-op" "test:event" "Details"

    assert_file_exists "${op_dir}/logs/events.log"
}

# ============================================================================
# Transition Guards Tests
# ============================================================================

@test "sm_allowed_transitions returns valid transitions for init" {
    run sm_allowed_transitions "init"
    assert_success
    assert_output "planned blocked failed"
}

@test "sm_allowed_transitions returns valid transitions for planned" {
    run sm_allowed_transitions "planned"
    assert_success
    assert_output "queued blocked failed"
}

@test "sm_allowed_transitions returns valid transitions for queued" {
    run sm_allowed_transitions "queued"
    assert_success
    assert_output "executing blocked failed"
}

@test "sm_allowed_transitions returns valid transitions for executing" {
    run sm_allowed_transitions "executing"
    assert_success
    assert_output "completed failed interrupted"
}

@test "sm_allowed_transitions returns valid transitions for completed" {
    run sm_allowed_transitions "completed"
    assert_success
    assert_output "pending_merge merged failed"
}

@test "sm_allowed_transitions returns empty for merged (terminal)" {
    run sm_allowed_transitions "merged"
    assert_success
    assert_output ""
}

@test "sm_allowed_transitions returns empty for cancelled (terminal)" {
    run sm_allowed_transitions "cancelled"
    assert_success
    assert_output ""
}

@test "sm_can_transition allows valid init->planned transition" {
    create_test_state "test-op" "init"

    run sm_can_transition "test-op" "planned"
    assert_success
}

@test "sm_can_transition allows valid planned->queued transition" {
    create_test_state "test-op" "planned"

    run sm_can_transition "test-op" "queued"
    assert_success
}

@test "sm_can_transition rejects invalid init->merged transition" {
    create_test_state "test-op" "init"

    run sm_can_transition "test-op" "merged"
    assert_failure
}

@test "sm_can_transition rejects invalid init->executing transition" {
    create_test_state "test-op" "init"

    run sm_can_transition "test-op" "executing"
    assert_failure
}

@test "sm_can_transition rejects transition from terminal state" {
    create_test_state "test-op" "merged"

    run sm_can_transition "test-op" "init"
    assert_failure
}

@test "sm_is_terminal_phase returns true for merged" {
    run sm_is_terminal_phase "merged"
    assert_success
}

@test "sm_is_terminal_phase returns true for cancelled" {
    run sm_is_terminal_phase "cancelled"
    assert_success
}

@test "sm_is_terminal_phase returns false for executing" {
    run sm_is_terminal_phase "executing"
    assert_failure
}

# ============================================================================
# Phase Transition Tests
# ============================================================================

@test "sm_transition_to_planned updates phase and plan_file" {
    create_test_state "test-op" "init"

    sm_transition_to_planned "test-op" "plans/test.md"

    run sm_read_state "test-op" "phase"
    assert_output "planned"

    run sm_read_state "test-op" "plan_file"
    assert_output "plans/test.md"
}

@test "sm_transition_to_planned fails from invalid phase" {
    create_test_state "test-op" "executing"

    run sm_transition_to_planned "test-op" "plans/test.md"
    assert_failure
    assert_output --partial "Cannot transition"
}

@test "sm_transition_to_queued updates phase" {
    create_test_state "test-op" "planned"

    sm_transition_to_queued "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "queued"
}

@test "sm_transition_to_queued sets epic_id when provided" {
    create_test_state "test-op" "planned"

    sm_transition_to_queued "test-op" "testp-abc123"

    run sm_read_state "test-op" "epic_id"
    assert_output "testp-abc123"
}

@test "sm_transition_to_blocked sets blocked state" {
    create_test_state "test-op" "planned"

    sm_transition_to_blocked "test-op" "parent-op" "planned"

    run sm_read_state "test-op" "phase"
    assert_output "blocked"

    run sm_read_state "test-op" "after"
    assert_output "parent-op"

    run sm_read_state "test-op" "blocked_phase"
    assert_output "planned"
}

@test "sm_transition_to_executing updates phase and session" {
    create_test_state "test-op" "queued"

    sm_transition_to_executing "test-op" "v0-test-session"

    run sm_read_state "test-op" "phase"
    assert_output "executing"

    run sm_read_state "test-op" "tmux_session"
    assert_output "v0-test-session"
}

@test "sm_transition_to_completed sets phase and timestamp" {
    create_test_state "test-op" "executing"

    sm_transition_to_completed "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "completed"

    # Should have a completed_at timestamp
    completed_at=$(sm_read_state "test-op" "completed_at")
    [[ "${completed_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "sm_transition_to_pending_merge updates phase" {
    create_test_state "test-op" "completed"

    sm_transition_to_pending_merge "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "pending_merge"
}

@test "sm_transition_to_merged sets phase and timestamp" {
    create_test_state "test-op" "pending_merge"

    sm_transition_to_merged "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "merged"

    run sm_read_state "test-op" "merge_status"
    assert_output "merged"
}

@test "sm_transition_to_failed sets error message" {
    create_test_state "test-op" "executing"

    sm_transition_to_failed "test-op" "Build failed with exit code 1"

    run sm_read_state "test-op" "phase"
    assert_output "failed"

    run sm_read_state "test-op" "error"
    assert_output "Build failed with exit code 1"
}

@test "sm_transition_to_conflict sets merge status" {
    create_test_state "test-op" "pending_merge"

    sm_transition_to_conflict "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "conflict"

    run sm_read_state "test-op" "merge_status"
    assert_output "conflict"
}

@test "sm_transition_to_interrupted updates phase" {
    create_test_state "test-op" "executing"

    sm_transition_to_interrupted "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "interrupted"
}

# ============================================================================
# Resume/Recovery Tests
# ============================================================================

@test "sm_get_resume_phase returns queued when epic_id exists" {
    create_test_state "test-op" "failed" '"epic_id": "testp-abc123"'

    run sm_get_resume_phase "test-op"
    assert_output "queued"
}

@test "sm_get_resume_phase returns planned when plan_file exists" {
    create_test_state "test-op" "failed" '"plan_file": "plans/test.md"'

    run sm_get_resume_phase "test-op"
    assert_output "planned"
}

@test "sm_get_resume_phase returns init when nothing exists" {
    create_test_state "test-op" "failed"

    run sm_get_resume_phase "test-op"
    assert_output "init"
}

@test "sm_get_resume_phase returns blocked_phase for blocked operations" {
    create_test_state "test-op" "blocked" '"blocked_phase": "queued", "after": "parent"'

    run sm_get_resume_phase "test-op"
    assert_output "queued"
}

@test "sm_clear_error_state resets phase and clears error" {
    create_test_state "test-op" "failed" '"error": "Some error", "plan_file": "plans/test.md"'

    sm_clear_error_state "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "planned"

    run jq -r '.error' "${BUILD_DIR}/operations/test-op/state.json"
    assert_output "null"
}

# ============================================================================
# Blocking/Dependency Tests
# ============================================================================

@test "sm_is_blocked returns true for blocked phase" {
    create_test_state "test-op" "blocked" '"after": "parent-op"'

    run sm_is_blocked "test-op"
    assert_success
}

@test "sm_is_blocked returns true when after is set" {
    create_test_state "test-op" "init" '"after": "parent-op"'

    run sm_is_blocked "test-op"
    assert_success
}

@test "sm_is_blocked returns false when not blocked" {
    create_test_state "test-op" "init"

    run sm_is_blocked "test-op"
    assert_failure
}

@test "sm_get_blocker returns blocking operation" {
    create_test_state "test-op" "blocked" '"after": "parent-op"'

    run sm_get_blocker "test-op"
    assert_output "parent-op"
}

@test "sm_get_blocker_status returns phase of blocker" {
    create_test_state "parent-op" "executing"

    run sm_get_blocker_status "parent-op"
    assert_output "executing"
}

@test "sm_get_blocker_status returns unknown for missing operation" {
    run sm_get_blocker_status "nonexistent"
    assert_failure
    assert_output "unknown"
}

@test "sm_is_blocker_merged returns true when blocker is merged" {
    create_test_state "child-op" "blocked" '"after": "parent-op"'
    create_test_state "parent-op" "merged"

    run sm_is_blocker_merged "child-op"
    assert_success
}

@test "sm_is_blocker_merged returns false when blocker not merged" {
    create_test_state "child-op" "blocked" '"after": "parent-op"'
    create_test_state "parent-op" "executing"

    run sm_is_blocker_merged "child-op"
    assert_failure
}

@test "sm_is_blocker_merged returns true when no blocker" {
    create_test_state "test-op" "init"

    run sm_is_blocker_merged "test-op"
    assert_success
}

@test "sm_unblock_operation clears blocked state" {
    create_test_state "test-op" "blocked" '"after": "parent-op", "blocked_phase": "queued"'

    sm_unblock_operation "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "queued"

    run jq -r '.after' "${BUILD_DIR}/operations/test-op/state.json"
    assert_output "null"
}

@test "sm_unblock_operation defaults to init if no blocked_phase" {
    create_test_state "test-op" "blocked" '"after": "parent-op"'

    sm_unblock_operation "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "init"
}

@test "sm_find_dependents finds operations waiting for merged op" {
    create_test_state "parent-op" "merged"
    create_test_state "child1" "blocked" '"after": "parent-op"'
    create_test_state "child2" "blocked" '"after": "parent-op"'
    create_test_state "unrelated" "blocked" '"after": "other-op"'

    run sm_find_dependents "parent-op"
    assert_success
    assert_output --partial "child1"
    assert_output --partial "child2"
    refute_output --partial "unrelated"
}

# ============================================================================
# Hold Helpers Tests
# ============================================================================

@test "sm_is_held returns true when held" {
    create_test_state "test-op" "init" '"held": true'

    run sm_is_held "test-op"
    assert_success
}

@test "sm_is_held returns false when not held" {
    create_test_state "test-op" "init" '"held": false'

    run sm_is_held "test-op"
    assert_failure
}

@test "sm_is_held returns false when held field missing" {
    create_test_state "test-op" "init"

    run sm_is_held "test-op"
    assert_failure
}

@test "sm_set_hold sets held flag and timestamp" {
    create_test_state "test-op" "init"

    sm_set_hold "test-op"

    run sm_read_state "test-op" "held"
    assert_output "true"

    held_at=$(sm_read_state "test-op" "held_at")
    [[ "${held_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "sm_clear_hold clears held flag" {
    create_test_state "test-op" "init" '"held": true, "held_at": "2026-01-15T10:00:00Z"'

    sm_clear_hold "test-op"

    # held becomes false, which jq -r with // empty returns as empty
    run jq -r '.held' "${BUILD_DIR}/operations/test-op/state.json"
    assert_output "false"

    run jq -r '.held_at' "${BUILD_DIR}/operations/test-op/state.json"
    assert_output "null"
}

# ============================================================================
# Merge Readiness Tests
# ============================================================================

@test "sm_is_merge_ready returns false for wrong phase" {
    create_test_state "test-op" "executing"

    run sm_is_merge_ready "test-op"
    assert_failure
}

@test "sm_is_merge_ready returns false for missing worktree" {
    create_test_state "test-op" "completed"

    run sm_is_merge_ready "test-op"
    assert_failure
}

@test "sm_merge_ready_reason returns phase when not in merge-ready phase" {
    create_test_state "test-op" "executing"

    run sm_merge_ready_reason "test-op"
    assert_output "phase:executing"
}

@test "sm_merge_ready_reason returns worktree:missing when no worktree" {
    create_test_state "test-op" "completed"

    run sm_merge_ready_reason "test-op"
    assert_output "worktree:missing"
}

@test "sm_should_auto_merge returns true when merge_queued is true" {
    create_test_state "test-op" "completed" '"merge_queued": true'

    run sm_should_auto_merge "test-op"
    assert_success
}

@test "sm_should_auto_merge returns false when merge_queued is false" {
    create_test_state "test-op" "completed" '"merge_queued": false'

    run sm_should_auto_merge "test-op"
    assert_failure
}

# ============================================================================
# Status Display Tests
# ============================================================================

@test "sm_get_display_status returns hold status when held" {
    create_test_state "test-op" "init" '"held": true'

    run sm_get_display_status "test-op"
    assert_output "held|yellow|[hold]"
}

@test "sm_get_display_status returns new for init phase" {
    create_test_state "test-op" "init"

    run sm_get_display_status "test-op"
    assert_output "new||"
}

@test "sm_get_display_status returns blocked with blocker name" {
    create_test_state "test-op" "blocked" '"after": "parent-op"'

    run sm_get_display_status "test-op"
    assert_output "blocked|yellow|[waiting: parent-op]"
}

@test "sm_get_display_status returns merged for merged phase" {
    create_test_state "test-op" "merged"

    run sm_get_display_status "test-op"
    assert_output "merged|green|[merged]"
}

@test "sm_get_display_status returns conflict for conflict phase" {
    create_test_state "test-op" "conflict"

    run sm_get_display_status "test-op"
    assert_output "conflict|red|== CONFLICT =="
}

@test "sm_get_display_status returns failed for failed phase" {
    create_test_state "test-op" "failed"

    run sm_get_display_status "test-op"
    assert_output "failed|red|[error]"
}

@test "sm_get_status_color returns correct ANSI codes" {
    # printf outputs the actual escape sequence, not the literal string
    result=$(sm_get_status_color "green")
    [[ "${result}" == $'\033[32m' ]]

    result=$(sm_get_status_color "yellow")
    [[ "${result}" == $'\033[33m' ]]

    result=$(sm_get_status_color "red")
    [[ "${result}" == $'\033[31m' ]]
}

@test "sm_is_active_operation returns true for executing" {
    create_test_state "test-op" "executing"

    run sm_is_active_operation "test-op"
    assert_success
}

@test "sm_is_active_operation returns false for merged" {
    create_test_state "test-op" "merged"

    run sm_is_active_operation "test-op"
    assert_failure
}

@test "sm_is_active_operation returns false for cancelled" {
    create_test_state "test-op" "cancelled"

    run sm_is_active_operation "test-op"
    assert_failure
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "full lifecycle: init -> planned -> queued -> executing -> completed -> merged" {
    create_test_state "lifecycle-test" "init"

    sm_transition_to_planned "lifecycle-test" "plans/test.md"
    run sm_get_phase "lifecycle-test"
    assert_output "planned"

    sm_transition_to_queued "lifecycle-test" "testp-abc123"
    run sm_get_phase "lifecycle-test"
    assert_output "queued"

    sm_transition_to_executing "lifecycle-test" "v0-test-session"
    run sm_get_phase "lifecycle-test"
    assert_output "executing"

    sm_transition_to_completed "lifecycle-test"
    run sm_get_phase "lifecycle-test"
    assert_output "completed"

    sm_transition_to_pending_merge "lifecycle-test"
    run sm_get_phase "lifecycle-test"
    assert_output "pending_merge"

    sm_transition_to_merged "lifecycle-test"
    run sm_get_phase "lifecycle-test"
    assert_output "merged"
}

@test "blocked operation can unblock and continue" {
    create_test_state "parent-op" "init"
    create_test_state "child-op" "init"

    # Block child on parent
    sm_transition_to_blocked "child-op" "parent-op" "init"
    run sm_get_phase "child-op"
    assert_output "blocked"

    # Parent completes
    sm_transition_to_planned "parent-op" "plans/parent.md"
    sm_transition_to_queued "parent-op"
    sm_transition_to_executing "parent-op" "v0-parent-session"
    sm_transition_to_completed "parent-op"
    sm_transition_to_pending_merge "parent-op"
    sm_transition_to_merged "parent-op"

    # Unblock child
    run sm_is_blocker_merged "child-op"
    assert_success

    sm_unblock_operation "child-op"
    run sm_get_phase "child-op"
    assert_output "init"
}

# ============================================================================
# Schema Versioning Tests
# ============================================================================

@test "sm_get_state_version returns 0 for legacy state files" {
    create_test_state "test-op" "init"

    run sm_get_state_version "test-op"
    assert_success
    assert_output "0"
}

@test "sm_get_state_version returns version from state file" {
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    echo '{"name": "test-op", "phase": "init", "_schema_version": 1}' > "${op_dir}/state.json"

    run sm_get_state_version "test-op"
    assert_success
    assert_output "1"
}

@test "sm_get_state_version fails for missing state file" {
    run sm_get_state_version "nonexistent"
    assert_failure
}

@test "sm_migrate_state migrates v0 to v1" {
    create_test_state "test-op" "init"

    sm_migrate_state "test-op"

    run sm_get_state_version "test-op"
    assert_output "1"

    # Should have _migrated_at field
    migrated_at=$(sm_read_state "test-op" "_migrated_at")
    [[ "${migrated_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]

    # Should have logged the migration event
    run cat "${BUILD_DIR}/operations/test-op/logs/events.log"
    assert_output --partial "schema:migrated"
}

@test "sm_migrate_state skips already current schema" {
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    echo '{"name": "test-op", "phase": "init", "_schema_version": 1}' > "${op_dir}/state.json"

    sm_migrate_state "test-op"

    # Should not have _migrated_at field (no migration occurred)
    run sm_read_state "test-op" "_migrated_at"
    assert_output ""
}

@test "sm_ensure_current_schema auto-migrates on access" {
    create_test_state "test-op" "init"

    # Reading phase triggers auto-migration
    run sm_get_phase "test-op"
    assert_output "init"

    # Should now have schema version 1
    run sm_get_state_version "test-op"
    assert_output "1"
}

@test "new state files should include _schema_version when created with transitions" {
    # Create a minimal state file
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    echo '{"name": "test-op", "phase": "init"}' > "${op_dir}/state.json"

    # Transition should trigger migration
    sm_transition_to_planned "test-op" "plans/test.md"

    run sm_get_state_version "test-op"
    assert_output "1"
}

# ============================================================================
# Batch State Reads Tests
# ============================================================================

@test "sm_read_state_fields reads multiple fields" {
    create_test_state "test-op" "executing" '"tmux_session": "v0-test", "worktree": "/path/to/worktree"'

    run sm_read_state_fields "test-op" phase tmux_session worktree
    assert_success
    # Output is tab-separated
    assert_output "executing	v0-test	/path/to/worktree"
}

@test "sm_read_state_fields returns empty for missing fields" {
    create_test_state "test-op" "init"

    run sm_read_state_fields "test-op" phase nonexistent another_missing
    assert_success
    # Only phase should have a value, missing fields are empty
    # Output contains init followed by tab-separated empty values
    assert_output --partial "init"
}

@test "sm_read_state_fields fails for missing state file" {
    run sm_read_state_fields "nonexistent" phase
    assert_failure
}

# bats test_tags=skip:bash3
@test "sm_read_all_state reads entire state" {
    # Skip on bash < 4 (no associative arrays)
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        skip "Requires bash 4+ for associative arrays"
    fi

    create_test_state "test-op" "executing" '"tmux_session": "v0-test", "prompt": "Build feature"'

    declare -A state
    sm_read_all_state "test-op" state

    [[ "${state[name]}" == "test-op" ]]
    [[ "${state[phase]}" == "executing" ]]
    [[ "${state[tmux_session]}" == "v0-test" ]]
    [[ "${state[prompt]}" == "Build feature" ]]
}

# bats test_tags=skip:bash3
@test "sm_read_all_state fails for missing state file" {
    # Skip on bash < 4 (no associative arrays)
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        skip "Requires bash 4+ for associative arrays"
    fi

    declare -A state
    run sm_read_all_state "nonexistent" state
    assert_failure
}

# ============================================================================
# Log Rotation Tests
# ============================================================================

@test "sm_rotate_log rotates log files" {
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    echo "log content 1" > "${op_dir}/logs/events.log"

    sm_rotate_log "${op_dir}/logs/events.log"

    # Original should be gone
    assert_file_not_exists "${op_dir}/logs/events.log"
    # Should be rotated to .1
    assert_file_exists "${op_dir}/logs/events.log.1"
    run cat "${op_dir}/logs/events.log.1"
    assert_output "log content 1"
}

@test "sm_rotate_log shifts existing rotated logs" {
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    echo "current" > "${op_dir}/logs/events.log"
    echo "previous" > "${op_dir}/logs/events.log.1"
    echo "older" > "${op_dir}/logs/events.log.2"

    sm_rotate_log "${op_dir}/logs/events.log"

    # Current should be gone, .1 should have current content
    assert_file_not_exists "${op_dir}/logs/events.log"
    run cat "${op_dir}/logs/events.log.1"
    assert_output "current"
    run cat "${op_dir}/logs/events.log.2"
    assert_output "previous"
    run cat "${op_dir}/logs/events.log.3"
    assert_output "older"
}

@test "sm_rotate_log removes oldest log when at limit" {
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    echo "current" > "${op_dir}/logs/events.log"
    echo "log1" > "${op_dir}/logs/events.log.1"
    echo "log2" > "${op_dir}/logs/events.log.2"
    echo "log3" > "${op_dir}/logs/events.log.3"  # This is the limit

    sm_rotate_log "${op_dir}/logs/events.log"

    # .3 should now have log2 content (shifted), original .3 deleted
    run cat "${op_dir}/logs/events.log.3"
    assert_output "log2"
    # There should be no .4
    assert_file_not_exists "${op_dir}/logs/events.log.4"
}

@test "sm_emit_event triggers rotation when log exceeds size limit" {
    local op_dir="${BUILD_DIR}/operations/test-op"
    mkdir -p "${op_dir}/logs"
    # Create a file larger than SM_LOG_MAX_SIZE (100KB)
    dd if=/dev/zero bs=1024 count=101 2>/dev/null | tr '\0' 'x' > "${op_dir}/logs/events.log"

    sm_emit_event "test-op" "test:event" "After rotation"

    # Old log should be rotated
    assert_file_exists "${op_dir}/logs/events.log.1"
    # New log should exist with our event
    assert_file_exists "${op_dir}/logs/events.log"
    run cat "${op_dir}/logs/events.log"
    assert_output --partial "test:event"
    assert_output --partial "After rotation"
}

# ============================================================================
# Cancel Transition Tests
# ============================================================================

@test "sm_transition_to_cancelled transitions from init" {
    create_test_state "test-op" "init"

    sm_transition_to_cancelled "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "cancelled"

    # Should have cancelled_at timestamp
    cancelled_at=$(sm_read_state "test-op" "cancelled_at")
    [[ "${cancelled_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "sm_transition_to_cancelled transitions from executing" {
    create_test_state "test-op" "executing"

    sm_transition_to_cancelled "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "cancelled"
}

@test "sm_transition_to_cancelled transitions from blocked" {
    create_test_state "test-op" "blocked" '"after": "parent-op"'

    sm_transition_to_cancelled "test-op"

    run sm_read_state "test-op" "phase"
    assert_output "cancelled"
}

@test "sm_transition_to_cancelled fails from merged (terminal)" {
    create_test_state "test-op" "merged"

    run sm_transition_to_cancelled "test-op"
    assert_failure
    assert_output --partial "terminal state"
}

@test "sm_transition_to_cancelled fails from cancelled (terminal)" {
    create_test_state "test-op" "cancelled"

    run sm_transition_to_cancelled "test-op"
    assert_failure
    assert_output --partial "terminal state"
}

@test "sm_transition_to_cancelled emits event" {
    create_test_state "test-op" "init"

    sm_transition_to_cancelled "test-op"

    run cat "${BUILD_DIR}/operations/test-op/logs/events.log"
    assert_output --partial "operation:cancelled"
}
