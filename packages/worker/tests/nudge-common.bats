#!/usr/bin/env bats
# Tests for nudge-common.sh - Nudge worker functions

load '../../test-support/helpers/test_helper'

# ============================================================================
# Setup/Teardown
# ============================================================================

setup() {
    _base_setup
    setup_v0_env
    # nudge-common needs claude projects directory
    mkdir -p "$HOME/.claude/projects"
    export DISABLE_NOTIFICATIONS=1
}

# ============================================================================
# get_file_mtime() tests
# ============================================================================

@test "get_file_mtime returns timestamp for existing file" {
    source_lib "nudge-common.sh"
    local tmp
    tmp=$(mktemp)

    run get_file_mtime "${tmp}"
    assert_success
    # Output should be a number (timestamp)
    [[ "${output}" =~ ^[0-9]+$ ]]

    rm "${tmp}"
}

@test "get_file_mtime fails for non-existent file" {
    source_lib "nudge-common.sh"

    run get_file_mtime "/nonexistent/path/file.txt"
    assert_failure
}

# ============================================================================
# is_file_stale() tests
# ============================================================================

@test "is_file_stale returns 0 for old files" {
    source_lib "nudge-common.sh"
    local tmp
    tmp=$(mktemp)

    # Touch with old timestamp (1 hour ago)
    if [[ "$(uname)" = "Darwin" ]]; then
        touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "${tmp}"
    else
        touch -d "1 hour ago" "${tmp}"
    fi

    run is_file_stale "${tmp}" 30
    assert_success

    rm "${tmp}"
}

@test "is_file_stale returns 1 for fresh files" {
    source_lib "nudge-common.sh"
    local tmp
    tmp=$(mktemp)

    # File was just created, should be fresh
    run is_file_stale "${tmp}" 30
    assert_failure

    rm "${tmp}"
}

@test "is_file_stale uses default threshold of 30 seconds" {
    source_lib "nudge-common.sh"
    local tmp
    tmp=$(mktemp)

    # Fresh file, should not be stale
    run is_file_stale "${tmp}"
    assert_failure

    rm "${tmp}"
}

# ============================================================================
# get_claude_project_dir() tests
# ============================================================================

@test "get_claude_project_dir encodes path correctly" {
    source_lib "nudge-common.sh"

    run get_claude_project_dir "/Users/test/projects/myapp"
    assert_success
    assert_output "$HOME/.claude/projects/-Users-test-projects-myapp"
}

@test "get_claude_project_dir handles root paths" {
    source_lib "nudge-common.sh"

    run get_claude_project_dir "/foo"
    assert_success
    assert_output "$HOME/.claude/projects/-foo"
}

@test "get_claude_project_dir handles deep paths" {
    source_lib "nudge-common.sh"

    run get_claude_project_dir "/a/b/c/d/e/f"
    assert_success
    assert_output "$HOME/.claude/projects/-a-b-c-d-e-f"
}

# ============================================================================
# get_latest_session_file() tests
# ============================================================================

@test "get_latest_session_file returns most recent jsonl file" {
    source_lib "nudge-common.sh"

    local project_dir="$TEST_TEMP_DIR/claude-project"
    mkdir -p "$project_dir"

    # Create two session files with different timestamps
    echo '{"test": 1}' > "$project_dir/old-session.jsonl"
    sleep 0.1
    echo '{"test": 2}' > "$project_dir/new-session.jsonl"

    run get_latest_session_file "$project_dir"
    assert_success
    assert_output "$project_dir/new-session.jsonl"
}

@test "get_latest_session_file returns empty for no jsonl files" {
    source_lib "nudge-common.sh"

    local project_dir="$TEST_TEMP_DIR/empty-project"
    mkdir -p "$project_dir"

    run get_latest_session_file "$project_dir"
    # Returns success but with empty output when no files found
    assert_success
    assert_output ""
}

@test "get_latest_session_file fails for non-existent directory" {
    source_lib "nudge-common.sh"

    run get_latest_session_file "/nonexistent/path"
    assert_failure
}

# ============================================================================
# get_session_state() tests
# ============================================================================

@test "get_session_state returns state for end_turn without tool_use" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}
{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
EOF

    run get_session_state "$session_file"
    assert_success

    # Parse the JSON output
    local stop_reason
    stop_reason=$(echo "$output" | jq -r '.stop_reason')
    assert_equal "$stop_reason" "end_turn"

    local has_tool_use
    has_tool_use=$(echo "$output" | jq -r '.has_tool_use')
    assert_equal "$has_tool_use" "false"
}

@test "get_session_state returns state for tool_use" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read"}]}}
EOF

    run get_session_state "$session_file"
    assert_success

    local stop_reason
    stop_reason=$(echo "$output" | jq -r '.stop_reason')
    assert_equal "$stop_reason" "tool_use"

    local has_tool_use
    has_tool_use=$(echo "$output" | jq -r '.has_tool_use')
    assert_equal "$has_tool_use" "true"
}

@test "get_session_state returns empty for no assistant messages" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}
EOF

    run get_session_state "$session_file"
    # Should return empty output (no assistant message with stop_reason)
    assert_output ""
}

# ============================================================================
# is_session_done() tests
# ============================================================================

@test "is_session_done returns 0 for end_turn without tool_use" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
EOF

    run is_session_done "$session_file"
    assert_success
}

@test "is_session_done returns 1 for tool_use" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read"}]}}
EOF

    run is_session_done "$session_file"
    assert_failure  # Returns 1 for active session
}

@test "is_session_done returns 1 for end_turn with tool_use" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"tool_use","name":"Read"}]}}
EOF

    run is_session_done "$session_file"
    assert_failure  # Returns 1 because tool_use is present
}

@test "is_session_done returns 2 for max_tokens" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    cat > "$session_file" <<'EOF'
{"type":"assistant","message":{"stop_reason":"max_tokens","content":[{"type":"text","text":"truncated"}]}}
EOF

    run is_session_done "$session_file"
    assert_equal "$status" 2
}

@test "is_session_done returns 1 for empty file" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    touch "$session_file"

    run is_session_done "$session_file"
    assert_failure  # Returns 1 for no state
}

# ============================================================================
# check_for_api_error() tests
# ============================================================================

@test "check_for_api_error detects 429 rate limit" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    echo '{"error": true, "status": 429}' > "$session_file"

    run check_for_api_error "$session_file"
    assert_success
}

@test "check_for_api_error detects 500 server error" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    echo '{"status": 500}' > "$session_file"

    run check_for_api_error "$session_file"
    assert_success
}

@test "check_for_api_error returns 1 for no error" {
    source_lib "nudge-common.sh"

    local session_file="$TEST_TEMP_DIR/session.jsonl"
    echo '{"type":"assistant","message":{"stop_reason":"end_turn"}}' > "$session_file"

    run check_for_api_error "$session_file"
    assert_failure
}

# ============================================================================
# write_session_marker() / find_session_worktree() tests
# ============================================================================

@test "write_session_marker creates .tmux-session file" {
    source_lib "nudge-common.sh"

    local tree_dir="$TEST_TEMP_DIR/tree"
    mkdir -p "$tree_dir"

    write_session_marker "$tree_dir" "v0-test-session"

    assert_file_exists "$tree_dir/.tmux-session"
    run cat "$tree_dir/.tmux-session"
    assert_output "v0-test-session"
}

@test "write_session_marker fails for non-existent directory" {
    source_lib "nudge-common.sh"

    run write_session_marker "/nonexistent/path" "v0-test-session"
    assert_failure
}

@test "find_session_worktree finds session by marker" {
    source_lib "nudge-common.sh"

    # Set up tree directory with session marker
    local tree_dir="$HOME/.local/state/v0/testproj/tree/v0-test-feature"
    mkdir -p "$tree_dir"
    echo "v0-test-session" > "$tree_dir/.tmux-session"

    run find_session_worktree "v0-test-session"
    assert_success
    assert_output "$tree_dir"
}

@test "find_session_worktree returns 1 for unknown session" {
    source_lib "nudge-common.sh"

    run find_session_worktree "v0-nonexistent-session"
    assert_failure
}

# ============================================================================
# get_v0_sessions() tests
# ============================================================================

@test "get_v0_sessions returns empty when no tmux server" {
    source_lib "nudge-common.sh"

    # This test may fail if tmux is running with v0 sessions
    # In test mode, tmux server is likely not running
    run get_v0_sessions
    # Should succeed but may return empty output
    assert_success
}

# ============================================================================
# find_operation_for_session() tests
# ============================================================================

@test "find_operation_for_session finds operation by tmux_session" {
    source_lib "nudge-common.sh"

    # Set up a mock state directory with a tree that has project root reference
    local state_dir="$HOME/.local/state/v0/testproj"
    local project_root="$BATS_TEST_TMPDIR/mock-project"
    local tree_dir="$state_dir/tree/my-worker"
    local build_dir="$project_root/.v0/build"
    mkdir -p "$tree_dir"
    mkdir -p "$build_dir/operations/my-feature"

    # Create the project root reference
    echo "$project_root" > "$tree_dir/.worker-project-root"

    cat > "$build_dir/operations/my-feature/state.json" <<'EOF'
{
  "name": "my-feature",
  "tmux_session": "v0-testproj-my-feature",
  "phase": "executing"
}
EOF

    run find_operation_for_session "v0-testproj-my-feature"
    assert_success

    # Output should be "op_name<tab>build_dir"
    local op_name build_dir_out
    IFS=$'\t' read -r op_name build_dir_out <<< "$output"
    assert_equal "$op_name" "my-feature"
    # build_dir should be the normalized path
    [[ -n "$build_dir_out" ]]
}

@test "find_operation_for_session returns 1 for unknown session" {
    source_lib "nudge-common.sh"

    run find_operation_for_session "v0-nonexistent-session"
    assert_failure
}

@test "find_operation_for_session ignores operations without tmux_session" {
    source_lib "nudge-common.sh"

    # Set up a mock state directory with a tree that has project root reference
    local state_dir="$HOME/.local/state/v0/testproj"
    local project_root="$BATS_TEST_TMPDIR/mock-project"
    local tree_dir="$state_dir/tree/my-worker"
    local build_dir="$project_root/.v0/build"
    mkdir -p "$tree_dir"
    mkdir -p "$build_dir/operations/no-session"

    # Create the project root reference
    echo "$project_root" > "$tree_dir/.worker-project-root"

    cat > "$build_dir/operations/no-session/state.json" <<'EOF'
{
  "name": "no-session",
  "phase": "planned"
}
EOF

    run find_operation_for_session "v0-testproj-no-session"
    assert_failure
}

# ============================================================================
# nudge_emit_operation_event() tests
# ============================================================================

@test "nudge_emit_operation_event creates events.log file" {
    source_lib "nudge-common.sh"

    local build_dir="$TEST_TEMP_DIR/project/.v0/build"
    mkdir -p "$build_dir/operations/test-op"

    nudge_emit_operation_event "$build_dir" "test-op" "nudge:completed" "Session terminated"

    assert_file_exists "$build_dir/operations/test-op/logs/events.log"
    run cat "$build_dir/operations/test-op/logs/events.log"
    [[ "$output" =~ "nudge:completed: Session terminated" ]]
}

@test "nudge_emit_operation_event appends to existing log" {
    source_lib "nudge-common.sh"

    local build_dir="$TEST_TEMP_DIR/project/.v0/build"
    mkdir -p "$build_dir/operations/test-op/logs"
    echo "[2026-01-01T00:00:00Z] existing:event: Previous entry" > "$build_dir/operations/test-op/logs/events.log"

    nudge_emit_operation_event "$build_dir" "test-op" "nudge:error" "Error occurred"

    run cat "$build_dir/operations/test-op/logs/events.log"
    # Should have both entries
    [[ "$output" =~ "existing:event" ]]
    [[ "$output" =~ "nudge:error: Error occurred" ]]
}

@test "nudge_emit_operation_event includes ISO timestamp" {
    source_lib "nudge-common.sh"

    local build_dir="$TEST_TEMP_DIR/project/.v0/build"
    mkdir -p "$build_dir/operations/test-op"

    nudge_emit_operation_event "$build_dir" "test-op" "test:event" "Details"

    run cat "$build_dir/operations/test-op/logs/events.log"
    # Should have ISO 8601 timestamp format
    [[ "$output" =~ \[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\] ]]
}
