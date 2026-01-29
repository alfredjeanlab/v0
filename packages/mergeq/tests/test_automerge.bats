#!/usr/bin/env bats
# Tests for automerge functionality

load '../../test-support/helpers/test_helper'

# ============================================================================
# Setup/Teardown
# ============================================================================

setup() {
    # Call common setup
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/project/.v0/build/operations"
    mkdir -p "$TEST_TEMP_DIR/project/.v0/build/mergeq/logs"
    mkdir -p "$TEST_TEMP_DIR/project/plans"
    mkdir -p "$TEST_TEMP_DIR/state"

    export REAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.local/state/v0"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "$TEST_TEMP_DIR/project"
    export ORIGINAL_PATH="$PATH"

    # Create mock binaries for CI environment (claude/tmux not installed)
    setup_mock_binaries claude tmux

    # Set V0_PLAN_EXEC to use our mock (created per-test as needed)
    MOCK_BIN="$TEST_TEMP_DIR/mock-bin"
    export V0_PLAN_EXEC="$MOCK_BIN/v0-plan-exec"

    # Set V0_ROOT to prevent walking up to parent .v0.rc
    export V0_ROOT="$TEST_TEMP_DIR/project"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"
    unset V0_PLAN_EXEC
    unset V0_ROOT

    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Clean up tmux sessions once at end of file (not per-test)
teardown_file() {
    local sessions
    if sessions=$(timeout 2 tmux list-sessions -F '#{session_name}' 2>/dev/null); then
        for session in $sessions; do
            if [[ "$session" == v0-testproj-* ]]; then
                timeout 1 tmux kill-session -t "$session" 2>/dev/null || true
            fi
        done
    fi
}

# ============================================================================
# Phase 1: v0 plan creates state with merge_queued: false
# ============================================================================

@test "v0-plan creates state.json with merge_queued: false" {
    create_v0rc "testproj" "tp"

    # Create mock v0-plan-exec that creates plan file
    cat > "$V0_PLAN_EXEC" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Test Plan" > plans/automerge-plan.md
exit 0
EOF
    chmod +x "$V0_PLAN_EXEC"

    # Run v0-plan with --direct to avoid tmux complexity in test
    run "$PROJECT_ROOT/bin/v0-plan" "automerge-plan" "Create a test plan" --direct
    assert_success

    # Check state.json was created with merge_queued: false
    STATE_FILE="$TEST_TEMP_DIR/project/.v0/build/operations/automerge-plan/state.json"
    assert_file_exists "$STATE_FILE"

    merge_queued=$(jq -r '.merge_queued' "$STATE_FILE")
    assert_equal "$merge_queued" "false"
}

@test "v0-plan state.json has type: plan" {
    create_v0rc "testproj" "tp"

    cat > "$V0_PLAN_EXEC" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Test Plan" > plans/type-test.md
exit 0
EOF
    chmod +x "$V0_PLAN_EXEC"

    run "$PROJECT_ROOT/bin/v0-plan" "type-test" "Create a test plan" --direct
    assert_success

    STATE_FILE="$TEST_TEMP_DIR/project/.v0/build/operations/type-test/state.json"
    op_type=$(jq -r '.type' "$STATE_FILE")
    assert_equal "$op_type" "plan"
}

# ============================================================================
# Phase 2: v0 status shows "plan completed" for plan operations
# ============================================================================

@test "v0-status shows plan completed for completed plan operations" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create a completed plan operation
    create_operation_state "plan-status-test" '{
        "name": "plan-status-test",
        "type": "plan",
        "phase": "completed",
        "merge_queued": false,
        "created_at": "2026-01-15T10:00:00Z"
    }'

    # Run status - may fail due to wk not being available, but output should still be correct
    run "$PROJECT_ROOT/bin/v0-status"
    # Don't assert_success since wk commands may fail in test env
    assert_output --partial "plan completed"
    refute_output --partial "NEEDS MERGE"
}

@test "v0-status shows NEEDS MERGE for completed feature operations without merge_queued" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create a completed feature operation without merge_queued
    create_operation_state "feature-needs-merge" '{
        "name": "feature-needs-merge",
        "type": "feature",
        "phase": "completed",
        "merge_queued": false,
        "created_at": "2026-01-15T10:00:00Z"
    }'

    # Run status - may fail due to wk not being available, but output should still be correct
    run "$PROJECT_ROOT/bin/v0-status"
    # Don't assert_success since wk commands may fail in test env
    assert_output --partial "NEEDS MERGE"
}

@test "v0-status detailed view shows plan completed status" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create a completed plan operation
    create_operation_state "plan-detail-test" '{
        "name": "plan-detail-test",
        "type": "plan",
        "phase": "completed",
        "merge_queued": false,
        "created_at": "2026-01-15T10:00:00Z"
    }'

    run "$PROJECT_ROOT/bin/v0-status" "plan-detail-test"
    assert_success
    assert_output --partial "plan completed"
    refute_output --partial "NEEDS MERGE"
}

# ============================================================================
# Phase 3: v0 feature --resume adds merge_queued if missing
# ============================================================================

@test "v0-feature --resume adds merge_queued: true to state missing the field" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create an operation without merge_queued (simulating old state from v0 plan)
    create_operation_state "resume-test" '{
        "name": "resume-test",
        "type": "plan",
        "phase": "completed",
        "created_at": "2026-01-15T10:00:00Z",
        "labels": []
    }'

    # Run resume with --dry-run to avoid actually launching workers
    run "$PROJECT_ROOT/bin/v0-feature" "resume-test" --resume --dry-run

    # Check that merge_queued was added
    STATE_FILE="$TEST_TEMP_DIR/project/.v0/build/operations/resume-test/state.json"
    merge_queued=$(jq -r '.merge_queued' "$STATE_FILE")
    assert_equal "$merge_queued" "true"
}

@test "v0-feature --resume --no-merge adds merge_queued: false" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create an operation without merge_queued
    create_operation_state "no-merge-resume" '{
        "name": "no-merge-resume",
        "type": "plan",
        "phase": "completed",
        "created_at": "2026-01-15T10:00:00Z",
        "labels": []
    }'

    # Run resume with --no-merge
    run "$PROJECT_ROOT/bin/v0-feature" "no-merge-resume" --resume --no-merge --dry-run

    STATE_FILE="$TEST_TEMP_DIR/project/.v0/build/operations/no-merge-resume/state.json"
    merge_queued=$(jq -r '.merge_queued' "$STATE_FILE")
    assert_equal "$merge_queued" "false"
}

@test "v0-feature --resume preserves existing merge_queued value when set to true" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create an operation with merge_queued already set to true
    create_operation_state "preserve-merge" '{
        "name": "preserve-merge",
        "type": "feature",
        "phase": "completed",
        "merge_queued": true,
        "created_at": "2026-01-15T10:00:00Z",
        "labels": []
    }'

    # Run resume
    run "$PROJECT_ROOT/bin/v0-feature" "preserve-merge" --resume --dry-run

    STATE_FILE="$TEST_TEMP_DIR/project/.v0/build/operations/preserve-merge/state.json"
    merge_queued=$(jq -r '.merge_queued' "$STATE_FILE")
    # Should preserve the existing true value
    assert_equal "$merge_queued" "true"
}

# ============================================================================
# Phase 4: Merge daemon auto-starts on enqueue
# ============================================================================

@test "v0-mergeq enqueue_merge function exists and calls ensure_daemon_running" {
    create_v0rc "testproj" "tp"

    # mq_enqueue in processing.sh calls mq_ensure_daemon_running
    run grep -q "mq_ensure_daemon_running" "$PROJECT_ROOT/packages/mergeq/lib/processing.sh"
    assert_success
}

@test "v0-mergeq has ensure_daemon_running function" {
    create_v0rc "testproj" "tp"

    # mq_ensure_daemon_running is defined in daemon.sh
    run grep -q "mq_ensure_daemon_running()" "$PROJECT_ROOT/packages/mergeq/lib/daemon.sh"
    assert_success
}

@test "v0-mergeq enqueue calls ensure_daemon_running after adding to queue" {
    create_v0rc "testproj" "tp"

    # Verify mq_enqueue calls mq_ensure_daemon_running after queue operations
    run grep -A 2 "# Auto-start daemon" "$PROJECT_ROOT/packages/mergeq/lib/processing.sh"
    assert_success
    assert_output --partial "mq_ensure_daemon_running"
}

# ============================================================================
# Phase 5: On-complete warning improvements
# ============================================================================

@test "v0-feature on-complete.sh template has proper error handling" {
    create_v0rc "testproj" "tp"

    # Check that the on-complete template has if/else for mergeq --enqueue
    run grep -A 5 'v0-mergeq.*--enqueue' "$PROJECT_ROOT/bin/v0-feature"
    assert_success
    assert_output --partial "if"
    assert_output --partial "Warning: Failed to enqueue"
}

@test "v0-feature-worker on-complete.sh template has proper error handling" {
    create_v0rc "testproj" "tp"

    # Check that the on-complete template has if/else for mergeq --enqueue
    run grep -A 5 'v0-mergeq.*--enqueue' "$PROJECT_ROOT/bin/v0-feature-worker"
    assert_success
    assert_output --partial "if"
    assert_output --partial "Warning: Failed to enqueue"
}

# ============================================================================
# Feature state creation tests
# ============================================================================

@test "v0-feature creates state with merge_queued: true by default" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Check the init_state function in v0-feature sets merge_queued
    run grep -A 30 "init_state()" "$PROJECT_ROOT/bin/v0-feature"
    assert_success
    assert_output --partial 'merge_queued'

    # Check that default is true (NO_MERGE not set means true)
    run grep 'merge_queued="true"' "$PROJECT_ROOT/bin/v0-feature"
    assert_success
}

@test "v0-feature --no-merge creates state with merge_queued: false" {
    create_v0rc "testproj" "tp"

    # Check that --no-merge sets merge_queued to false
    run grep -A 3 'NO_MERGE' "$PROJECT_ROOT/bin/v0-feature"
    assert_success
    assert_output --partial 'merge_queued="false"'
}

# ============================================================================
# Integration tests - verify all components work together
# ============================================================================

@test "complete plan workflow has merge_queued: false throughout" {
    # This test runs both v0-plan and v0-status, so needs more time
    # Set to 15s for CI safety margin
    BATS_TEST_TIMEOUT=15

    create_v0rc "testproj" "tp"

    cat > "$V0_PLAN_EXEC" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Integration Test Plan" > plans/integration-plan.md
exit 0
EOF
    chmod +x "$V0_PLAN_EXEC"

    # Create plan
    run "$PROJECT_ROOT/bin/v0-plan" "integration-plan" "Test integration" --direct
    assert_success

    # Verify state has merge_queued: false
    STATE_FILE="$TEST_TEMP_DIR/project/.v0/build/operations/integration-plan/state.json"
    merge_queued=$(jq -r '.merge_queued' "$STATE_FILE")
    assert_equal "$merge_queued" "false"

    # Simulate completion
    tmp=$(mktemp)
    jq '.phase = "completed"' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    # Verify status shows "plan completed" not "NEEDS MERGE"
    # (may fail due to wk not being available, but output should still be correct)
    run "$PROJECT_ROOT/bin/v0-status"
    assert_output --partial "plan completed"
    refute_output --partial "NEEDS MERGE"
}
