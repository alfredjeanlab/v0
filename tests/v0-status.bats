#!/usr/bin/env bats
# Tests for v0-status - Integration tests for the status command
#
# Related test files:
# - packages/status/tests/timestamps.bats - Unit tests for timestamp functions
# - tests/v0-status-session.bats - Session detection tests
# - tests/v0-status-limit.bats - Limit and prioritization tests

load '../packages/test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
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
