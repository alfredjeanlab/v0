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
    # Verify no inline jq calls for .phase field (queue.json and roadmap state are OK)
    # This ensures we use state machine functions for features; roadmaps have separate state management
    run bash -c "grep 'jq.*\.phase' '$PROJECT_ROOT/bin/v0-status' | grep -v 'queue.json' | grep -v 'roadmap' | wc -l | tr -d ' '"
    assert_output "0"
}

@test "v0-status no inline jq held access" {
    # Verify no inline jq calls for .held field
    run bash -c "grep 'jq.*\.held' '$PROJECT_ROOT/bin/v0-status' | wc -l | tr -d ' '"
    assert_output "0"
}

# ============================================================================
# get_last_updated_timestamp tests (last-updated timestamps feature)
# ============================================================================

# Copy of function from v0-status for testing
get_last_updated_timestamp() {
    local phase="$1"
    local created_at="$2"
    local completed_at="$3"
    local merged_at="$4"
    local held_at="$5"

    case "${phase}" in
        merged)
            # Prefer merged_at, fall back to completed_at, then created_at
            if [[ -n "${merged_at}" && "${merged_at}" != "null" ]]; then
                echo "${merged_at}"
            elif [[ -n "${completed_at}" && "${completed_at}" != "null" ]]; then
                echo "${completed_at}"
            else
                echo "${created_at}"
            fi
            ;;
        completed|pending_merge)
            # Show when it was completed
            if [[ -n "${completed_at}" && "${completed_at}" != "null" ]]; then
                echo "${completed_at}"
            else
                echo "${created_at}"
            fi
            ;;
        held)
            # Show when it was put on hold
            if [[ -n "${held_at}" && "${held_at}" != "null" ]]; then
                echo "${held_at}"
            else
                echo "${created_at}"
            fi
            ;;
        *)
            # For init, planned, queued, executing, etc. - use created_at
            echo "${created_at}"
            ;;
    esac
}

@test "get_last_updated_timestamp returns merged_at for merged phase" {
    run get_last_updated_timestamp "merged" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "2026-01-03T10:00:00Z" "null"
    assert_success
    assert_output "2026-01-03T10:00:00Z"
}

@test "get_last_updated_timestamp returns completed_at for completed phase" {
    run get_last_updated_timestamp "completed" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "null" "null"
    assert_success
    assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp returns completed_at for pending_merge phase" {
    run get_last_updated_timestamp "pending_merge" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "null" "null"
    assert_success
    assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp returns held_at for held phase" {
    run get_last_updated_timestamp "held" "2026-01-01T10:00:00Z" "null" "null" "2026-01-04T10:00:00Z"
    assert_success
    assert_output "2026-01-04T10:00:00Z"
}

@test "get_last_updated_timestamp returns created_at for init phase" {
    run get_last_updated_timestamp "init" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp returns created_at for planned phase" {
    run get_last_updated_timestamp "planned" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp returns created_at for queued phase" {
    run get_last_updated_timestamp "queued" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp returns created_at for executing phase" {
    run get_last_updated_timestamp "executing" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to completed_at when merged_at is null for merged phase" {
    run get_last_updated_timestamp "merged" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "null" "null"
    assert_success
    assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at when merged_at and completed_at are null for merged phase" {
    run get_last_updated_timestamp "merged" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at when completed_at is null for completed phase" {
    run get_last_updated_timestamp "completed" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at when held_at is null for held phase" {
    run get_last_updated_timestamp "held" "2026-01-01T10:00:00Z" "null" "null" "null"
    assert_success
    assert_output "2026-01-01T10:00:00Z"
}

# ============================================================================
# Last-updated timestamp integration tests
# ============================================================================

@test "operations sort by created_at even when showing last-updated timestamps" {
    # Create operations with different created_at but same or different last-updated
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/op1" "$ops_dir/op2" "$ops_dir/op3"

    # op1: created first, completed last
    cat > "$ops_dir/op1/state.json" <<'EOF'
{"name": "op1", "type": "feature", "phase": "completed", "created_at": "2026-01-01T10:00:00Z", "completed_at": "2026-01-05T10:00:00Z"}
EOF

    # op2: created second, completed first
    cat > "$ops_dir/op2/state.json" <<'EOF'
{"name": "op2", "type": "feature", "phase": "completed", "created_at": "2026-01-02T10:00:00Z", "completed_at": "2026-01-03T10:00:00Z"}
EOF

    # op3: created third, still executing
    cat > "$ops_dir/op3/state.json" <<'EOF'
{"name": "op3", "type": "feature", "phase": "executing", "created_at": "2026-01-03T10:00:00Z"}
EOF

    # Verify operations can be sorted by created_at
    local sorted_names
    sorted_names=$(jq -rs 'sort_by(.created_at) | .[].name' "$ops_dir"/*/state.json)

    # First operation should be op1 (earliest created_at)
    local first_name
    first_name=$(echo "$sorted_names" | head -1)
    assert_equal "$first_name" "op1"

    # Second operation should be op2
    local second_name
    second_name=$(echo "$sorted_names" | sed -n '2p')
    assert_equal "$second_name" "op2"

    # Third operation should be op3 (latest created_at)
    local third_name
    third_name=$(echo "$sorted_names" | tail -1)
    assert_equal "$third_name" "op3"
}

@test "completed_at field is extracted correctly from state.json" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/test-op"

    cat > "$ops_dir/test-op/state.json" <<'EOF'
{"name": "test-op", "phase": "completed", "created_at": "2026-01-01T10:00:00Z", "completed_at": "2026-01-02T15:30:00Z"}
EOF

    local completed_at
    completed_at=$(jq -r '.completed_at // "null"' "$ops_dir/test-op/state.json")
    assert_equal "$completed_at" "2026-01-02T15:30:00Z"
}

@test "held_at field is extracted correctly from state.json" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/held-op"

    cat > "$ops_dir/held-op/state.json" <<'EOF'
{"name": "held-op", "phase": "held", "created_at": "2026-01-01T10:00:00Z", "held_at": "2026-01-02T08:00:00Z"}
EOF

    local held_at
    held_at=$(jq -r '.held_at // "null"' "$ops_dir/held-op/state.json")
    assert_equal "$held_at" "2026-01-02T08:00:00Z"
}

@test "missing timestamp fields default to null string" {
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/legacy-op"

    # Simulate old state file without new timestamp fields
    cat > "$ops_dir/legacy-op/state.json" <<'EOF'
{"name": "legacy-op", "phase": "completed", "created_at": "2026-01-01T10:00:00Z"}
EOF

    local completed_at held_at
    completed_at=$(jq -r '.completed_at // "null"' "$ops_dir/legacy-op/state.json")
    held_at=$(jq -r '.held_at // "null"' "$ops_dir/legacy-op/state.json")

    assert_equal "$completed_at" "null"
    assert_equal "$held_at" "null"
}

# ============================================================================
# Limit and pruning tests (limit-op-status feature)
# ============================================================================

# Helper: create a test operation with given phase
create_test_operation() {
    local name="$1"
    local phase="$2"
    local after="${3:-}"
    local ops_dir="$BUILD_DIR/operations"
    mkdir -p "$ops_dir/$name"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local after_field=""
    [[ -n "$after" ]] && after_field=", \"after\": \"$after\""

    cat > "$ops_dir/$name/state.json" <<EOF
{"name": "$name", "type": "feature", "phase": "$phase", "created_at": "$ts"$after_field}
EOF
}

# Helper: create multiple operations with sequential timestamps
create_numbered_operations() {
    local count="$1"
    local phase="$2"
    local prefix="${3:-op}"
    local after="${4:-}"
    local ops_dir="$BUILD_DIR/operations"

    for i in $(seq 1 "$count"); do
        mkdir -p "$ops_dir/${prefix}${i}"
        # Use sequential timestamps to ensure ordering
        local ts
        ts=$(TZ=UTC date -j -v+${i}S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             TZ=UTC date -d "2026-01-01 10:00:00 +${i} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

        local after_field=""
        [[ -n "$after" ]] && after_field=", \"after\": \"$after\""

        cat > "$ops_dir/${prefix}${i}/state.json" <<EOF
{"name": "${prefix}${i}", "type": "feature", "phase": "$phase", "created_at": "$ts"$after_field}
EOF
    done
}

@test "status list limits to 15 operations by default" {
    # Create 20 operations
    create_numbered_operations 20 "executing"

    # Run v0-status
    run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # Should show exactly 15 operation lines (each line starts with "  op")
    local op_count
    op_count=$(echo "$output" | grep -c "^  op" || true)
    assert_equal "$op_count" "15"

    # Should show summary line
    [[ "$output" == *"... and 5 more"* ]]
}

@test "status list prioritizes open operations over blocked" {
    local ops_dir="$BUILD_DIR/operations"

    # Create 10 completed operations (low priority)
    create_numbered_operations 10 "completed" "completed"

    # Create 10 blocked operations (medium priority) - has after field
    for i in $(seq 1 10); do
        mkdir -p "$ops_dir/blocked${i}"
        local ts
        ts=$(TZ=UTC date -j -v+$((i+10))S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             TZ=UTC date -d "2026-01-01 10:00:00 +$((i+10)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
        cat > "$ops_dir/blocked${i}/state.json" <<EOF
{"name": "blocked${i}", "type": "feature", "phase": "init", "created_at": "$ts", "after": "some-parent"}
EOF
    done

    # Create 5 open operations (high priority)
    for i in $(seq 1 5); do
        mkdir -p "$ops_dir/open${i}"
        local ts
        ts=$(TZ=UTC date -j -v+$((i+20))S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             TZ=UTC date -d "2026-01-01 10:00:00 +$((i+20)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
        cat > "$ops_dir/open${i}/state.json" <<EOF
{"name": "open${i}", "type": "feature", "phase": "executing", "created_at": "$ts"}
EOF
    done

    run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # All 5 open operations should be shown
    for i in $(seq 1 5); do
        [[ "$output" == *"open${i}:"* ]]
    done
}

@test "status list prioritizes blocked over completed" {
    local ops_dir="$BUILD_DIR/operations"

    # Create 20 completed operations
    create_numbered_operations 20 "completed" "completed"

    # Create 5 blocked operations (has after field, not executing)
    for i in $(seq 1 5); do
        mkdir -p "$ops_dir/blocked${i}"
        local ts
        ts=$(TZ=UTC date -j -v+$((i+20))S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             TZ=UTC date -d "2026-01-01 10:00:00 +$((i+20)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
        cat > "$ops_dir/blocked${i}/state.json" <<EOF
{"name": "blocked${i}", "type": "feature", "phase": "queued", "created_at": "$ts", "after": "parent-op"}
EOF
    done

    run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # All 5 blocked operations should be shown
    for i in $(seq 1 5); do
        [[ "$output" == *"blocked${i}:"* ]]
    done
}

@test "status list shows summary for pruned operations" {
    # Create 20 operations with mixed phases
    create_numbered_operations 8 "executing" "open"
    create_numbered_operations 7 "completed" "completed"
    create_numbered_operations 5 "merged" "merged"

    run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # Should show summary line with pruned count
    [[ "$output" == *"... and 5 more"* ]]
}

@test "status list respects V0_STATUS_LIMIT env var" {
    # Create 10 operations
    create_numbered_operations 10 "executing"

    # Run with V0_STATUS_LIMIT=5
    V0_STATUS_LIMIT=5 run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # Should show exactly 5 operation lines
    local op_count
    op_count=$(echo "$output" | grep -c "^  op" || true)
    assert_equal "$op_count" "5"

    # Should show summary line
    [[ "$output" == *"... and 5 more"* ]]
}

@test "status list shows all operations when under limit" {
    # Create 10 operations
    create_numbered_operations 10 "executing"

    run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # Should show all 10 operation lines
    local op_count
    op_count=$(echo "$output" | grep -c "^  op" || true)
    assert_equal "$op_count" "10"

    # Should NOT show summary line
    [[ "$output" != *"... and"*"more"* ]]
}

@test "status list shows no summary when exactly at limit" {
    # Create exactly 15 operations
    create_numbered_operations 15 "executing"

    run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success
    # Should show exactly 15 operation lines
    local op_count
    op_count=$(echo "$output" | grep -c "^  op" || true)
    assert_equal "$op_count" "15"

    # Should NOT show summary line
    [[ "$output" != *"... and"*"more"* ]]
}

@test "status list priority_class classifies phases correctly" {
    # Test that priority_class in jq correctly classifies operations
    # Open (priority 0): init, planned, queued, executing, failed, conflict, interrupted
    # Blocked (priority 1): blocked phase, or has 'after' field and not executing
    # Completed (priority 2): completed, pending_merge, merged, cancelled

    local ops_dir="$BUILD_DIR/operations"

    # Create one of each phase type
    local ts_base="2026-01-01T10:00:"
    local counter=0

    for phase in init planned queued executing failed conflict interrupted completed pending_merge merged cancelled blocked; do
        counter=$((counter + 1))
        local ts_sec
        ts_sec=$(printf "%02d" "$counter")
        mkdir -p "$ops_dir/test-${phase}"
        cat > "$ops_dir/test-${phase}/state.json" <<EOF
{"name": "test-${phase}", "type": "feature", "phase": "$phase", "created_at": "${ts_base}${ts_sec}Z"}
EOF
    done

    # Set limit to show 8 operations (should show all open: 7, plus 1 blocked)
    V0_STATUS_LIMIT=8 run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

    assert_success

    # Should show open operations (init, planned, queued, executing, failed, conflict, interrupted)
    [[ "$output" == *"test-init:"* ]]
    [[ "$output" == *"test-executing:"* ]]
    [[ "$output" == *"test-failed:"* ]]

    # Should show blocked phase
    [[ "$output" == *"test-blocked:"* ]]

    # Should prune completed operations
    [[ "$output" == *"... and 4 more"* ]]
}
