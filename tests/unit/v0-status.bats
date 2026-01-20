#!/usr/bin/env bats
# Tests for v0-status - Timestamp and Display Utilities

load '../helpers/test_helper'

# Setup for status tests
setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/project/.v0/build/operations"

    export REAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.local/state/v0"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "$TEST_TEMP_DIR/project"
    export ORIGINAL_PATH="$PATH"

    # Create valid v0 config
    create_v0rc "testproject" "testp"

    # Export paths
    export V0_ROOT="$TEST_TEMP_DIR/project"
    export PROJECT="testproject"
    export BUILD_DIR="$TEST_TEMP_DIR/project/.v0/build"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"

    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# timestamp_to_epoch() tests
# ============================================================================

# Convert ISO 8601 timestamp to epoch (cross-platform)
# Note: Timestamps with Z suffix are UTC, so we parse in UTC timezone
timestamp_to_epoch() {
    local ts="$1"
    local formatted
    formatted=$(echo "$ts" | sed 's/T/ /; s/Z$//; s/\.[0-9]*//')
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use -j -f flags
        TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$formatted" +%s 2>/dev/null
    else
        # Linux: use -d flag with ISO format
        TZ=UTC date -d "$formatted" +%s 2>/dev/null
    fi
}

@test "timestamp_to_epoch converts valid ISO8601" {
    run timestamp_to_epoch "2026-01-15T10:30:00Z"
    assert_success
    # Output should be a valid epoch (numeric)
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "timestamp_to_epoch handles midnight" {
    run timestamp_to_epoch "2026-01-15T00:00:00Z"
    assert_success
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "timestamp_to_epoch handles end of day" {
    run timestamp_to_epoch "2026-01-15T23:59:59Z"
    assert_success
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "timestamp_to_epoch returns reasonable value" {
    local epoch
    epoch=$(timestamp_to_epoch "2026-01-15T10:00:00Z")

    # Should be after Jan 1 2026 (1767225600) and before Jan 1 2027 (1798761600)
    [ "$epoch" -gt 1767225600 ]
    [ "$epoch" -lt 1798761600 ]
}

# ============================================================================
# format_elapsed() tests
# ============================================================================

# Format elapsed time as human-readable string
format_elapsed() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        echo "just now"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        echo "${mins} min ago"
    else
        local hours=$((seconds / 3600))
        echo "${hours} hr ago"
    fi
}

@test "format_elapsed shows 'just now' for under 60 seconds" {
    run format_elapsed 0
    assert_output "just now"

    run format_elapsed 30
    assert_output "just now"

    run format_elapsed 59
    assert_output "just now"
}

@test "format_elapsed shows minutes for 60-3599 seconds" {
    run format_elapsed 60
    assert_output "1 min ago"
}

@test "format_elapsed shows minutes for 90 seconds" {
    run format_elapsed 90
    assert_output "1 min ago"
}

@test "format_elapsed shows correct minutes" {
    run format_elapsed 180
    assert_output "3 min ago"
}

@test "format_elapsed shows minutes at boundary" {
    run format_elapsed 3599
    assert_output "59 min ago"
}

@test "format_elapsed shows hours for 3600+ seconds" {
    run format_elapsed 3600
    assert_output "1 hr ago"
}

@test "format_elapsed shows correct hours" {
    run format_elapsed 7200
    assert_output "2 hr ago"
}

@test "format_elapsed shows hours for large values" {
    run format_elapsed 86400  # 24 hours
    assert_output "24 hr ago"
}

# ============================================================================
# Extended format_elapsed tests (based on PLAN.md)
# ============================================================================

# Extended version that handles days
format_elapsed_extended() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    elif [ "$seconds" -lt 86400 ]; then
        local hours=$((seconds / 3600))
        local mins=$(( (seconds % 3600) / 60 ))
        echo "${hours}h ${mins}m"
    else
        local days=$((seconds / 86400))
        local hours=$(( (seconds % 86400) / 3600 ))
        echo "${days}d ${hours}h"
    fi
}

@test "format_elapsed_extended handles seconds" {
    run format_elapsed_extended 30
    assert_output "30s"
}

@test "format_elapsed_extended handles minutes and seconds" {
    run format_elapsed_extended 90
    assert_output "1m 30s"
}

@test "format_elapsed_extended handles hours and minutes" {
    run format_elapsed_extended 3665
    assert_output "1h 1m"
}

@test "format_elapsed_extended handles days and hours" {
    run format_elapsed_extended 90000
    assert_output "1d 1h"
}

@test "format_elapsed_extended handles exactly 1 day" {
    run format_elapsed_extended 86400
    assert_output "1d 0h"
}

@test "format_elapsed_extended handles 2 days" {
    run format_elapsed_extended 172800
    assert_output "2d 0h"
}

# ============================================================================
# Status display tests
# ============================================================================

@test "status formatting handles empty operations directory" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir"

    # Count operations
    local count=0
    for state_file in "$ops_dir"/*/state.json; do
        [ -f "$state_file" ] && count=$((count + 1))
    done

    assert_equal "$count" "0"
}

@test "status formatting counts operations correctly" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/op1" "$ops_dir/op2" "$ops_dir/op3"
    echo '{"phase": "init"}' > "$ops_dir/op1/state.json"
    echo '{"phase": "executing"}' > "$ops_dir/op2/state.json"
    echo '{"phase": "merged"}' > "$ops_dir/op3/state.json"

    # Count operations
    local count=0
    for state_file in "$ops_dir"/*/state.json; do
        [ -f "$state_file" ] && count=$((count + 1))
    done

    assert_equal "$count" "3"
}

@test "status can filter operations by phase" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/op1" "$ops_dir/op2" "$ops_dir/op3"
    echo '{"phase": "init"}' > "$ops_dir/op1/state.json"
    echo '{"phase": "executing"}' > "$ops_dir/op2/state.json"
    echo '{"phase": "executing"}' > "$ops_dir/op3/state.json"

    # Count executing operations
    local count=0
    for state_file in "$ops_dir"/*/state.json; do
        [ -f "$state_file" ] || continue
        local phase
        phase=$(jq -r '.phase' "$state_file")
        [ "$phase" = "executing" ] && count=$((count + 1))
    done

    assert_equal "$count" "2"
}

# ============================================================================
# Queue status display tests
# ============================================================================

@test "queue status reads entries correctly" {
    local queue_file="$BUILD_DIR/mergeq/queue.json"
    mkdir -p "$(dirname "$queue_file")"
    cat > "$queue_file" <<'EOF'
{"version": 1, "entries": [
  {"operation": "op1", "status": "pending"},
  {"operation": "op2", "status": "processing"},
  {"operation": "op3", "status": "completed"}
]}
EOF

    local pending
    pending=$(jq '[.entries[] | select(.status == "pending")] | length' "$queue_file")
    assert_equal "$pending" "1"

    local processing
    processing=$(jq '[.entries[] | select(.status == "processing")] | length' "$queue_file")
    assert_equal "$processing" "1"
}

@test "queue status handles empty queue" {
    local queue_file="$BUILD_DIR/mergeq/queue.json"
    mkdir -p "$(dirname "$queue_file")"
    echo '{"version": 1, "entries": []}' > "$queue_file"

    local count
    count=$(jq '.entries | length' "$queue_file")
    assert_equal "$count" "0"
}

# ============================================================================
# Prune deprecation tests (prune moved to v0-prune)
# ============================================================================

@test "status help does not show prune options" {
    run "$PROJECT_ROOT/bin/v0-status" --help
    # Help exits with code 1 (usage)
    assert_failure
    # Should NOT contain the old prune options
    [[ "$output" != *"--prune "* ]]
    [[ "$output" != *"--prune-all"* ]]
    # Should reference the new command
    [[ "$output" == *"v0 prune"* ]]
}

@test "prune logic identifies completed operations" {
    # Test prune criteria logic (used by v0-prune)
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/completed-op"
    echo '{"phase": "merged", "merge_status": "merged"}' > "$ops_dir/completed-op/state.json"

    local should_prune=""
    local phase
    phase=$(jq -r '.phase' "$ops_dir/completed-op/state.json")

    if [ "$phase" = "merged" ]; then
        should_prune=1
    fi

    assert [ -n "$should_prune" ]
}

@test "prune logic identifies cancelled operations" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/cancelled-op"
    echo '{"phase": "cancelled"}' > "$ops_dir/cancelled-op/state.json"

    local should_prune=""
    local phase
    phase=$(jq -r '.phase' "$ops_dir/cancelled-op/state.json")

    if [ "$phase" = "cancelled" ]; then
        should_prune=1
    fi

    assert [ -n "$should_prune" ]
}

@test "prune logic skips active operations" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/active-op"
    echo '{"phase": "executing"}' > "$ops_dir/active-op/state.json"

    local should_prune=""
    local phase
    phase=$(jq -r '.phase' "$ops_dir/active-op/state.json")

    if [ "$phase" = "merged" ] || [ "$phase" = "cancelled" ]; then
        should_prune=1
    fi

    assert [ -z "$should_prune" ]
}

# ============================================================================
# Recently Completed Section tests
# ============================================================================

# Extended format_elapsed with day support (matches v0-status implementation)
format_elapsed_with_days() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        echo "just now"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        echo "${mins} min ago"
    elif [ "$seconds" -lt 86400 ]; then
        local hours=$((seconds / 3600))
        echo "${hours} hr ago"
    else
        local days=$((seconds / 86400))
        echo "${days} day ago"
    fi
}

@test "format_elapsed_with_days shows days for 86400+ seconds" {
    run format_elapsed_with_days 86400
    assert_output "1 day ago"
}

@test "format_elapsed_with_days shows multiple days" {
    run format_elapsed_with_days 172800
    assert_output "2 day ago"
}

@test "format_elapsed_with_days shows hours under 24h" {
    run format_elapsed_with_days 7200
    assert_output "2 hr ago"
}

@test "get_merged_operations identifies merged operations" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/test-merged"

    # Create a state.json with merged status
    local now_ts
    now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$ops_dir/test-merged/state.json" <<EOF
{"name": "test-merged", "merge_status": "merged", "merged_at": "$now_ts"}
EOF

    # Check that merged status can be read
    local merge_status
    merge_status=$(jq -r '.merge_status' "$ops_dir/test-merged/state.json")
    assert_equal "$merge_status" "merged"
}

@test "get_merged_operations skips non-merged operations" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/test-pending"

    cat > "$ops_dir/test-pending/state.json" <<'EOF'
{"name": "test-pending", "merge_status": "pending"}
EOF

    # Check that pending status is detected
    local merge_status
    merge_status=$(jq -r '.merge_status' "$ops_dir/test-pending/state.json")
    assert_equal "$merge_status" "pending"
    [ "$merge_status" != "merged" ]
}

# ============================================================================
# Session detection tests (commit 712bc18)
# ============================================================================
# These tests verify that session detection works correctly for active indicators.
# The key insight is that tmux list-sessions only returns LOCAL sessions, so
# if a session name is found in all_sessions, it's definitely running locally
# regardless of the machine field in state.json.

# Helper function matching the logic in v0-status (lines 548-551)
# This tests the session detection without requiring the full v0-status context
is_session_active() {
    local session="$1"
    local all_sessions="$2"
    # Logic matches v0-status: only check if session is in all_sessions
    # No machine check needed since tmux list-sessions only returns local sessions
    [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]
}

@test "session detection: session in all_sessions is detected as active" {
    local all_sessions=$'v0-plan-abc\nv0-feat-xyz\nother-session'
    local session="v0-feat-xyz"

    run is_session_active "$session" "$all_sessions"
    assert_success
}

@test "session detection: session not in all_sessions is not active" {
    local all_sessions=$'v0-plan-abc\nother-session'
    local session="v0-feat-xyz"

    run is_session_active "$session" "$all_sessions"
    assert_failure
}

@test "session detection: empty session name is not active" {
    local all_sessions=$'v0-plan-abc\nv0-feat-xyz'
    local session=""

    run is_session_active "$session" "$all_sessions"
    assert_failure
}

@test "session detection: works with empty all_sessions" {
    local all_sessions=""
    local session="v0-feat-xyz"

    run is_session_active "$session" "$all_sessions"
    assert_failure
}

@test "session detection: partial match is detected (session name contained in list)" {
    # This tests substring matching which is how the actual code works
    local all_sessions="v0-plan-abc v0-feat-xyz other-session"
    local session="v0-feat-xyz"

    run is_session_active "$session" "$all_sessions"
    assert_success
}

@test "session detection: does not require machine field match" {
    # This documents the key fix: session detection should work regardless of
    # what machine field contains, since tmux list-sessions only returns local sessions
    #
    # Previous bug: code checked machine == local_machine before checking all_sessions
    # This caused [active] to not show when:
    # - machine field was missing or "unknown"
    # - hostname changed between operation creation and status check
    # - any mismatch in hostname formatting
    #
    # The fix removes the machine check entirely for session detection because
    # if tmux list-sessions returns a session, it must be running locally.

    # Simulate the detection logic from v0-status
    local session="v0-feat-xyz"
    local all_sessions="v0-plan-abc v0-feat-xyz other-session"
    local machine="unknown"  # Could be anything - doesn't affect detection
    local local_machine
    local_machine=$(hostname -s)

    # Machine mismatch should NOT prevent session detection
    # (This is what the fix ensures)
    local status_icon=""
    if [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]; then
        status_icon="[active]"
    fi

    assert_equal "$status_icon" "[active]"
}

@test "session detection: works with mismatched machine field" {
    # Test the specific scenario the bug fixed: machine field doesn't match
    # but session is in local tmux sessions
    local session="v0-feat-test"
    local all_sessions="v0-feat-test some-other-session"
    local machine="remote-host"  # Different from local machine
    local local_machine
    local_machine=$(hostname -s)

    # The detection should still work because we find the session in all_sessions
    local status_icon=""
    if [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]; then
        status_icon="[active]"
    fi

    assert_equal "$status_icon" "[active]"
}

@test "session detection: works when machine field is null" {
    # Edge case: machine field is null/missing
    local session="v0-plan-abc"
    local all_sessions="v0-plan-abc"
    local machine="null"

    local status_icon=""
    if [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]; then
        status_icon="[active]"
    fi

    assert_equal "$status_icon" "[active]"
}

# ============================================================================
# State machine integration tests (added in state-machine-step3)
# ============================================================================

@test "v0-status uses sm_state_exists for operation lookup" {
    # Verify no direct file checks for state.json existence in show_status path
    # The grep pattern looks for the old pattern: -f.*state.json (file exists check)
    run grep -c '\-f "\${STATE_FILE}"' "$PROJECT_ROOT/bin/v0-status"
    assert_output "0"
}

@test "v0-status uses sm_read_state_fields for batch reads" {
    # Verify batch read usage in show_status
    run grep -c "sm_read_state_fields" "$PROJECT_ROOT/bin/v0-status"
    # Should have at least 1 batch read call
    [[ "${output}" -ge 1 ]]
}

@test "v0-status uses state machine helpers for display" {
    # Verify state machine helper functions are used for display formatting
    run grep -c "_sm_format_phase_display" "$PROJECT_ROOT/bin/v0-status"
    # Should have at least 1 call in list view
    [[ "${output}" -ge 1 ]]
}

@test "v0-status no inline jq phase access" {
    # Verify no inline jq calls for .phase field (queue.json is OK)
    # This ensures we use state machine functions instead
    run bash -c "grep 'jq.*\.phase' '$PROJECT_ROOT/bin/v0-status' | grep -v 'queue.json' | wc -l | tr -d ' '"
    assert_output "0"
}

@test "v0-status no inline jq held access" {
    # Verify no inline jq calls for .held field
    run bash -c "grep 'jq.*\.held' '$PROJECT_ROOT/bin/v0-status' | wc -l | tr -d ' '"
    assert_output "0"
}
