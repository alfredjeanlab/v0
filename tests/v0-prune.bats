#!/usr/bin/env bats
# Tests for v0-prune - Remove operation state

load '../packages/test-support/helpers/test_helper'

# Setup for prune tests
setup() {
    _base_setup
    setup_v0_env
}

# ============================================================================
# Help and Usage tests
# ============================================================================

@test "prune --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0-prune" --help
    # Help exits with code 1 (usage)
    assert_failure
    [[ "${output}" == *"v0 prune"* ]]
    [[ "${output}" == *"Remove operation state"* ]]
}

@test "prune -h shows usage" {
    run "${PROJECT_ROOT}/bin/v0-prune" -h
    # Help exits with code 1 (usage)
    assert_failure
    [[ "${output}" == *"v0 prune"* ]]
}

# ============================================================================
# Prune completed/cancelled operations (default behavior)
# ============================================================================

@test "prune removes merged operations" {
    mkdir -p "${BUILD_DIR}/operations/test-op"
    echo '{"phase": "merged", "name": "test-op"}' > "${BUILD_DIR}/operations/test-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/test-op" ]
    [[ "${output}" == *"Pruned: test-op"* ]]
}

@test "prune removes cancelled operations" {
    mkdir -p "${BUILD_DIR}/operations/cancelled-op"
    echo '{"phase": "cancelled", "name": "cancelled-op"}' > "${BUILD_DIR}/operations/cancelled-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/cancelled-op" ]
    [[ "${output}" == *"Pruned: cancelled-op"* ]]
}

@test "prune removes completed operations with merged status" {
    mkdir -p "${BUILD_DIR}/operations/completed-op"
    echo '{"phase": "completed", "name": "completed-op", "merge_status": "merged"}' > "${BUILD_DIR}/operations/completed-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/completed-op" ]
}

@test "prune removes pending_merge operations with merged status" {
    mkdir -p "${BUILD_DIR}/operations/pending-op"
    echo '{"phase": "pending_merge", "name": "pending-op", "merge_status": "merged"}' > "${BUILD_DIR}/operations/pending-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/pending-op" ]
}

@test "prune skips executing operations" {
    mkdir -p "${BUILD_DIR}/operations/active-op"
    echo '{"phase": "executing", "name": "active-op"}' > "${BUILD_DIR}/operations/active-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ -d "${BUILD_DIR}/operations/active-op" ]
}

@test "prune skips init phase operations" {
    mkdir -p "${BUILD_DIR}/operations/init-op"
    echo '{"phase": "init", "name": "init-op"}' > "${BUILD_DIR}/operations/init-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ -d "${BUILD_DIR}/operations/init-op" ]
}

@test "prune skips completed operations without merged status" {
    mkdir -p "${BUILD_DIR}/operations/unmerged-op"
    echo '{"phase": "completed", "name": "unmerged-op"}' > "${BUILD_DIR}/operations/unmerged-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ -d "${BUILD_DIR}/operations/unmerged-op" ]
}

@test "prune reports no operations when empty" {
    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"No completed or cancelled operations to prune"* ]]
}

@test "prune reports no operations when directory missing" {
    rmdir "${BUILD_DIR}/operations"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"No operations to prune"* ]]
}

@test "prune counts pruned operations" {
    mkdir -p "${BUILD_DIR}/operations/op1" "${BUILD_DIR}/operations/op2" "${BUILD_DIR}/operations/op3"
    echo '{"phase": "merged", "name": "op1"}' > "${BUILD_DIR}/operations/op1/state.json"
    echo '{"phase": "cancelled", "name": "op2"}' > "${BUILD_DIR}/operations/op2/state.json"
    echo '{"phase": "executing", "name": "op3"}' > "${BUILD_DIR}/operations/op3/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"Pruned 2 operation(s)"* ]]
    [ ! -d "${BUILD_DIR}/operations/op1" ]
    [ ! -d "${BUILD_DIR}/operations/op2" ]
    [ -d "${BUILD_DIR}/operations/op3" ]
}

# ============================================================================
# Prune specific operation by name
# ============================================================================

@test "prune specific operation by name" {
    mkdir -p "${BUILD_DIR}/operations/specific-op"
    echo '{"phase": "executing", "name": "specific-op"}' > "${BUILD_DIR}/operations/specific-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --force specific-op
    assert_success
    [ ! -d "${BUILD_DIR}/operations/specific-op" ]
    [[ "${output}" == *"Pruned operation 'specific-op'"* ]]
}

@test "prune nonexistent operation fails" {
    run "${PROJECT_ROOT}/bin/v0-prune" nonexistent
    assert_failure
    [[ "${output}" == *"not found"* ]]
}

# ============================================================================
# Dry-run mode
# ============================================================================

@test "prune --dry-run shows preview without removing" {
    mkdir -p "${BUILD_DIR}/operations/dry-run-op"
    echo '{"phase": "merged", "name": "dry-run-op"}' > "${BUILD_DIR}/operations/dry-run-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --dry-run
    assert_success
    [ -d "${BUILD_DIR}/operations/dry-run-op" ]  # Still exists
    [[ "${output}" == *"Would prune"* ]]
}

@test "prune -n is alias for --dry-run" {
    mkdir -p "${BUILD_DIR}/operations/dry-run-op"
    echo '{"phase": "merged", "name": "dry-run-op"}' > "${BUILD_DIR}/operations/dry-run-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" -n
    assert_success
    [ -d "${BUILD_DIR}/operations/dry-run-op" ]
    [[ "${output}" == *"Would prune"* ]]
}

@test "prune --dry-run with specific operation" {
    mkdir -p "${BUILD_DIR}/operations/specific-dry"
    echo '{"phase": "executing", "name": "specific-dry"}' > "${BUILD_DIR}/operations/specific-dry/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --dry-run specific-dry
    assert_success
    [ -d "${BUILD_DIR}/operations/specific-dry" ]
    [[ "${output}" == *"Would prune: specific-dry"* ]]
}

# ============================================================================
# Prune all operations
# ============================================================================

@test "prune --all --force removes everything" {
    mkdir -p "${BUILD_DIR}/operations/op1"
    mkdir -p "${BUILD_DIR}/operations/op2"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/op1/state.json"
    echo '{"phase": "init"}' > "${BUILD_DIR}/operations/op2/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --all --force
    assert_success
    [ ! -d "${BUILD_DIR}/operations" ]
    [[ "${output}" == *"Pruned all operations"* ]]
}

@test "prune -a -f removes everything" {
    mkdir -p "${BUILD_DIR}/operations/op1"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/op1/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" -a -f
    assert_success
    [ ! -d "${BUILD_DIR}/operations" ]
}

@test "prune --all reports no operations when empty" {
    rmdir "${BUILD_DIR}/operations"

    run "${PROJECT_ROOT}/bin/v0-prune" --all --force
    assert_success
    [[ "${output}" == *"No operations to prune"* ]]
}

@test "prune --all --dry-run shows preview" {
    mkdir -p "${BUILD_DIR}/operations/op1"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/op1/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --all --dry-run
    assert_success
    [ -d "${BUILD_DIR}/operations" ]
    [[ "${output}" == *"Would remove"* ]]
}

# ============================================================================
# Error handling
# ============================================================================

@test "prune unknown option shows usage" {
    run "${PROJECT_ROOT}/bin/v0-prune" --unknown
    assert_failure
    [[ "${output}" == *"Unknown option"* ]]
}

@test "prune accepts multiple operation names" {
    mkdir -p "${BUILD_DIR}/operations/op1" "${BUILD_DIR}/operations/op2" "${BUILD_DIR}/operations/op3"
    echo '{"phase": "executing", "name": "op1"}' > "${BUILD_DIR}/operations/op1/state.json"
    echo '{"phase": "executing", "name": "op2"}' > "${BUILD_DIR}/operations/op2/state.json"
    echo '{"phase": "executing", "name": "op3"}' > "${BUILD_DIR}/operations/op3/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --force op1 op2
    assert_success
    [ ! -d "${BUILD_DIR}/operations/op1" ]
    [ ! -d "${BUILD_DIR}/operations/op2" ]
    [ -d "${BUILD_DIR}/operations/op3" ]  # op3 should still exist
    [[ "${output}" == *"Pruned operation 'op1'"* ]]
    [[ "${output}" == *"Pruned operation 'op2'"* ]]
}

# ============================================================================
# v0_prune_mergeq tests
# ============================================================================

# Helper to source v0-common.sh for direct function testing
source_common() {
    source "${PROJECT_ROOT}/packages/cli/lib/v0-common.sh"
}

# Helper to get timestamp from N hours ago in ISO 8601 format
get_timestamp_hours_ago() {
    local hours="$1"
    # macOS date syntax
    date -u -v-"${hours}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    # GNU date syntax
    date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

@test "v0_prune_mergeq removes completed entries older than 6 hours" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    local old_ts
    old_ts=$(get_timestamp_hours_ago 7)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "old-completed", "status": "completed", "enqueued_at": "${old_ts}", "updated_at": "${old_ts}"},
  {"operation": "old-pending", "status": "pending", "enqueued_at": "${old_ts}"}
]}
EOF

    run v0_prune_mergeq
    assert_success
    [[ "${output}" == *"Pruned 1 mergeq entries"* ]]

    # Verify old-completed was removed, old-pending was kept
    run jq '.entries | length' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "1"

    run jq -r '.entries[0].operation' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "old-pending"
}

@test "v0_prune_mergeq keeps completed entries newer than 6 hours" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    local new_ts
    new_ts=$(get_timestamp_hours_ago 1)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "new-completed", "status": "completed", "enqueued_at": "${new_ts}", "updated_at": "${new_ts}"}
]}
EOF

    run v0_prune_mergeq
    assert_success

    # Entry should still exist
    run jq '.entries | length' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "1"
}

@test "v0_prune_mergeq removes failed and conflict entries older than 6 hours" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    local old_ts
    old_ts=$(get_timestamp_hours_ago 8)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "old-failed", "status": "failed", "enqueued_at": "${old_ts}", "updated_at": "${old_ts}"},
  {"operation": "old-conflict", "status": "conflict", "enqueued_at": "${old_ts}", "updated_at": "${old_ts}"}
]}
EOF

    run v0_prune_mergeq
    assert_success
    [[ "${output}" == *"Pruned 2 mergeq entries"* ]]

    run jq '.entries | length' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "0"
}

@test "v0_prune_mergeq keeps pending and processing entries regardless of age" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    local old_ts
    old_ts=$(get_timestamp_hours_ago 24)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "old-pending", "status": "pending", "enqueued_at": "${old_ts}"},
  {"operation": "old-processing", "status": "processing", "enqueued_at": "${old_ts}"}
]}
EOF

    run v0_prune_mergeq
    assert_success

    # Both entries should remain
    run jq '.entries | length' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "2"
}

@test "v0_prune_mergeq dry-run shows preview without removing" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    local old_ts
    old_ts=$(get_timestamp_hours_ago 10)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "old-completed", "status": "completed", "enqueued_at": "${old_ts}", "updated_at": "${old_ts}"}
]}
EOF

    run v0_prune_mergeq --dry-run
    assert_success
    [[ "${output}" == *"Would prune 1 mergeq entries"* ]]

    # Entry should still exist
    run jq '.entries | length' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "1"
}

@test "v0_prune_mergeq handles empty queue" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    echo '{"version": 1, "entries": []}' > "${BUILD_DIR}/mergeq/queue.json"

    run v0_prune_mergeq
    assert_success
    # No output when nothing to prune
}

@test "v0_prune_mergeq handles missing queue file" {
    source_common

    # Don't create queue file
    rm -f "${BUILD_DIR}/mergeq/queue.json"

    run v0_prune_mergeq
    assert_success
    # No output when file doesn't exist
}

@test "v0_prune_mergeq uses updated_at over enqueued_at for age" {
    source_common

    mkdir -p "${BUILD_DIR}/mergeq"
    local old_enqueue new_update
    old_enqueue=$(get_timestamp_hours_ago 10)
    new_update=$(get_timestamp_hours_ago 1)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "old-enqueue-new-update", "status": "completed", "enqueued_at": "${old_enqueue}", "updated_at": "${new_update}"}
]}
EOF

    run v0_prune_mergeq
    assert_success

    # Entry should still exist because updated_at is recent
    run jq '.entries | length' "${BUILD_DIR}/mergeq/queue.json"
    assert_output "1"
}

@test "v0_prune_mergeq called by v0 prune command" {
    mkdir -p "${BUILD_DIR}/mergeq"
    local old_ts
    old_ts=$(get_timestamp_hours_ago 8)

    cat > "${BUILD_DIR}/mergeq/queue.json" <<EOF
{"version": 1, "entries": [
  {"operation": "old-completed", "status": "completed", "enqueued_at": "${old_ts}", "updated_at": "${old_ts}"}
]}
EOF

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"Pruning old mergeq entries"* ]]
    [[ "${output}" == *"Pruned 1 mergeq entries"* ]]
}
