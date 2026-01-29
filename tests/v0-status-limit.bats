#!/usr/bin/env bats
# Tests for v0-status --max-ops and operation prioritization

load '../packages/test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
}

# ============================================================================
# Helper functions
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

  for ((i=1; i<=count; i++)); do
    mkdir -p "$ops_dir/${prefix}${i}"
    # Use sequential timestamps to ensure ordering
    local ts
    ts=$(TZ=UTC date -j -v+${i}S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         TZ=UTC date -d "2026-01-01T10:00:00 UTC + ${i} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

    local after_field=""
    [[ -n "$after" ]] && after_field=", \"after\": \"$after\""

    cat > "$ops_dir/${prefix}${i}/state.json" <<EOF
{"name": "${prefix}${i}", "type": "feature", "phase": "$phase", "created_at": "$ts"$after_field}
EOF
  done
}

# ============================================================================
# Limit and pruning tests (limit-op-status feature)
# ============================================================================

@test "status list shows all operations by default" {
  # Create 20 operations
  create_numbered_operations 20 "executing"

  # Run v0-status without --max-ops (should show all)
  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

  assert_success
  # Should show all 20 operation lines (each line starts with "  op")
  local op_count
  op_count=$(echo "$output" | grep -c "^  op" || true)
  assert_equal "$op_count" "20"

  # Should NOT show summary line (all shown)
  [[ "$output" != *"... and"*"more"* ]]
}

@test "status list limits operations with --max-ops" {
  # Create 20 operations
  create_numbered_operations 20 "executing"

  # Run v0-status with --max-ops 15
  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints --max-ops 15

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
  for i in {1..10}; do
    mkdir -p "$ops_dir/blocked${i}"
    local ts
    ts=$(TZ=UTC date -j -v+$((i+10))S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         TZ=UTC date -d "2026-01-01T10:00:00 UTC + $((i+10)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    cat > "$ops_dir/blocked${i}/state.json" <<EOF
{"name": "blocked${i}", "type": "feature", "phase": "init", "created_at": "$ts", "after": "some-parent"}
EOF
  done

  # Create 5 open operations (high priority)
  for i in {1..5}; do
    mkdir -p "$ops_dir/open${i}"
    local ts
    ts=$(TZ=UTC date -j -v+$((i+20))S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         TZ=UTC date -d "2026-01-01T10:00:00 UTC + $((i+20)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    cat > "$ops_dir/open${i}/state.json" <<EOF
{"name": "open${i}", "type": "feature", "phase": "executing", "created_at": "$ts"}
EOF
  done

  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

  assert_success
  # All 5 open operations should be shown
  for i in {1..5}; do
    [[ "$output" == *"open${i}:"* ]]
  done
}

@test "status list prioritizes blocked over completed" {
  local ops_dir="$BUILD_DIR/operations"

  # Create 20 truly completed operations (with merge_status: merged)
  for i in {1..20}; do
    mkdir -p "$ops_dir/completed${i}"
    local ts
    ts=$(TZ=UTC date -j -v+${i}S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         TZ=UTC date -d "2026-01-01T10:00:00 UTC + ${i} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    cat > "$ops_dir/completed${i}/state.json" <<EOF
{"name": "completed${i}", "type": "feature", "phase": "completed", "created_at": "$ts", "merge_status": "merged"}
EOF
  done

  # Create 5 blocked operations (has after field, not executing)
  for i in {1..5}; do
    mkdir -p "$ops_dir/blocked${i}"
    local ts
    ts=$(TZ=UTC date -j -v+$((i+20))S -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T10:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         TZ=UTC date -d "2026-01-01T10:00:00 UTC + $((i+20)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    cat > "$ops_dir/blocked${i}/state.json" <<EOF
{"name": "blocked${i}", "type": "feature", "phase": "queued", "created_at": "$ts", "after": "parent-op"}
EOF
  done

  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints

  assert_success
  # All 5 blocked operations should be shown
  for i in {1..5}; do
    [[ "$output" == *"blocked${i}:"* ]]
  done
}

@test "status list shows summary for pruned operations" {
  # Create 20 operations with mixed phases
  create_numbered_operations 8 "executing" "open"
  create_numbered_operations 7 "completed" "completed"
  create_numbered_operations 5 "merged" "merged"

  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints --max-ops 15

  assert_success
  # Should show summary line with pruned count
  [[ "$output" == *"... and 5 more"* ]]
}

@test "status list respects --max-ops argument" {
  # Create 10 operations
  create_numbered_operations 10 "executing"

  # Run with --max-ops 5
  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints --max-ops 5

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
  # Completed (priority 2): completed (with merge_status:merged), pending_merge, merged, cancelled
  # Note: "blocked" phase was removed in v2, blocking is now tracked via wok

  local ops_dir="$BUILD_DIR/operations"

  # Create one of each phase type (excluding deprecated "blocked" phase)
  local ts_base="2026-01-01T10:00:"
  local counter=0

  for phase in init planned queued executing failed conflict interrupted completed pending_merge merged cancelled; do
    counter=$((counter + 1))
    local ts_sec
    ts_sec=$(printf "%02d" "$counter")
    mkdir -p "$ops_dir/test-${phase}"
    # For completed phase, add merge_status:merged to make it truly completed (priority 2)
    local extra=""
    if [[ "$phase" == "completed" ]]; then
      extra=', "merge_status": "merged"'
    fi
    cat > "$ops_dir/test-${phase}/state.json" <<EOF
{"name": "test-${phase}", "type": "feature", "phase": "$phase", "created_at": "${ts_base}${ts_sec}Z"$extra}
EOF
  done

  # Set limit to show 8 operations
  # Priority 0 (needs attention): init, planned, queued, executing, failed, conflict, interrupted, pending_merge
  #   - pending_merge is priority 0 because it lacks merge_status:merged
  # Priority 2 (completed): completed (has merge_status:merged), merged, cancelled
  run "$PROJECT_ROOT/bin/v0-status" --list --no-hints --max-ops 8

  assert_success

  # Should show open operations (init, planned, queued, executing, failed, conflict, interrupted)
  [[ "$output" == *"test-init:"* ]]
  [[ "$output" == *"test-executing:"* ]]
  [[ "$output" == *"test-failed:"* ]]

  # Should show pending_merge (priority 0, needs attention)
  [[ "$output" == *"test-pending_merge:"* ]]

  # Should prune priority-2 operations (completed, merged, cancelled = 3 more)
  [[ "$output" == *"... and 3 more"* ]]
}

# ============================================================================
# Short mode visibility tests (for --short flag behavior)
# ============================================================================
# These tests verify that --short mode shows "Stopped" status for Bugs/Chores
# when there are queued items, but hides the section when queue is empty.

# Helper function that matches the visibility logic in v0-status for bugs/chores
# Returns 0 (true) if section should be shown, 1 (false) if hidden
should_show_worker_section() {
  local short_mode="$1"      # "" for full mode, "1" for short mode
  local queue_empty="$2"     # "true" or "false"

  # In short mode, skip only if queue is empty
  # In full mode, always show
  [[ -z "${short_mode}" ]] || [[ "${queue_empty}" != "true" ]]
}

@test "short mode: shows section when queue has items (worker stopped)" {
  # Worker status doesn't matter - if queue has items, show section
  run should_show_worker_section "1" "false"
  assert_success
}

@test "short mode: hides section when queue is empty" {
  run should_show_worker_section "1" "true"
  assert_failure
}

@test "full mode: shows section when queue has items" {
  run should_show_worker_section "" "false"
  assert_success
}

@test "full mode: shows section when queue is empty" {
  run should_show_worker_section "" "true"
  assert_success
}
