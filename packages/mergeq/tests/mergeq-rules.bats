#!/usr/bin/env bats
# Tests for lib/mergeq/rules.sh - Pure business logic for merge queue

load '../../test-support/helpers/test_helper'

setup() {
    # Source the rules module
    source "${PROJECT_ROOT}/packages/mergeq/lib/rules.sh"
}

# ============================================================================
# Status constants tests
# ============================================================================

@test "MQ_STATUS_PENDING is defined" {
    assert_equal "${MQ_STATUS_PENDING}" "pending"
}

@test "MQ_STATUS_PROCESSING is defined" {
    assert_equal "${MQ_STATUS_PROCESSING}" "processing"
}

@test "MQ_STATUS_COMPLETED is defined" {
    assert_equal "${MQ_STATUS_COMPLETED}" "completed"
}

@test "MQ_STATUS_FAILED is defined" {
    assert_equal "${MQ_STATUS_FAILED}" "failed"
}

@test "MQ_STATUS_CONFLICT is defined" {
    assert_equal "${MQ_STATUS_CONFLICT}" "conflict"
}

@test "MQ_STATUS_RESUMED is defined" {
    assert_equal "${MQ_STATUS_RESUMED}" "resumed"
}

# ============================================================================
# mq_is_active_status tests
# ============================================================================

@test "mq_is_active_status returns true for pending" {
    run mq_is_active_status "pending"
    assert_success
}

@test "mq_is_active_status returns true for processing" {
    run mq_is_active_status "processing"
    assert_success
}

@test "mq_is_active_status returns false for completed" {
    run mq_is_active_status "completed"
    assert_failure
}

@test "mq_is_active_status returns false for failed" {
    run mq_is_active_status "failed"
    assert_failure
}

@test "mq_is_active_status returns false for conflict" {
    run mq_is_active_status "conflict"
    assert_failure
}

@test "mq_is_active_status returns false for resumed" {
    run mq_is_active_status "resumed"
    assert_failure
}

# ============================================================================
# mq_is_terminal_status tests
# ============================================================================

@test "mq_is_terminal_status returns true for completed" {
    run mq_is_terminal_status "completed"
    assert_success
}

@test "mq_is_terminal_status returns true for failed" {
    run mq_is_terminal_status "failed"
    assert_success
}

@test "mq_is_terminal_status returns true for conflict" {
    run mq_is_terminal_status "conflict"
    assert_success
}

@test "mq_is_terminal_status returns false for pending" {
    run mq_is_terminal_status "pending"
    assert_failure
}

@test "mq_is_terminal_status returns false for processing" {
    run mq_is_terminal_status "processing"
    assert_failure
}

@test "mq_is_terminal_status returns false for resumed" {
    run mq_is_terminal_status "resumed"
    assert_failure
}

# ============================================================================
# mq_is_pending_status tests
# ============================================================================

@test "mq_is_pending_status returns true for pending" {
    run mq_is_pending_status "pending"
    assert_success
}

@test "mq_is_pending_status returns false for processing" {
    run mq_is_pending_status "processing"
    assert_failure
}

@test "mq_is_pending_status returns false for completed" {
    run mq_is_pending_status "completed"
    assert_failure
}

# ============================================================================
# mq_is_retriable_status tests
# ============================================================================

@test "mq_is_retriable_status returns true for resumed" {
    run mq_is_retriable_status "resumed"
    assert_success
}

@test "mq_is_retriable_status returns true for completed" {
    run mq_is_retriable_status "completed"
    assert_success
}

@test "mq_is_retriable_status returns true for failed" {
    run mq_is_retriable_status "failed"
    assert_success
}

@test "mq_is_retriable_status returns true for conflict" {
    run mq_is_retriable_status "conflict"
    assert_success
}

@test "mq_is_retriable_status returns false for pending" {
    run mq_is_retriable_status "pending"
    assert_failure
}

@test "mq_is_retriable_status returns false for processing" {
    run mq_is_retriable_status "processing"
    assert_failure
}

# ============================================================================
# mq_compare_priority tests
# ============================================================================

@test "mq_compare_priority: lower priority number wins" {
    run mq_compare_priority 0 "2026-01-15T10:00:00Z" 5 "2026-01-15T10:00:00Z"
    assert_success
    assert_output "-1"
}

@test "mq_compare_priority: higher priority number loses" {
    run mq_compare_priority 5 "2026-01-15T10:00:00Z" 0 "2026-01-15T10:00:00Z"
    assert_success
    assert_output "1"
}

@test "mq_compare_priority: same priority - earlier time wins" {
    run mq_compare_priority 0 "2026-01-15T09:00:00Z" 0 "2026-01-15T10:00:00Z"
    assert_success
    assert_output "-1"
}

@test "mq_compare_priority: same priority - later time loses" {
    run mq_compare_priority 0 "2026-01-15T10:00:00Z" 0 "2026-01-15T09:00:00Z"
    assert_success
    assert_output "1"
}

@test "mq_compare_priority: identical entries return 0" {
    run mq_compare_priority 0 "2026-01-15T10:00:00Z" 0 "2026-01-15T10:00:00Z"
    assert_success
    assert_output "0"
}

@test "mq_compare_priority: priority takes precedence over time" {
    # Even though entry2 has earlier time, entry1 wins on priority
    run mq_compare_priority 0 "2026-01-15T12:00:00Z" 5 "2026-01-15T08:00:00Z"
    assert_success
    assert_output "-1"
}

# ============================================================================
# mq_is_branch_pattern tests
# ============================================================================

@test "mq_is_branch_pattern returns true for feature/name" {
    run mq_is_branch_pattern "feature/my-feature"
    assert_success
}

@test "mq_is_branch_pattern returns true for fix/name" {
    run mq_is_branch_pattern "fix/bug-123"
    assert_success
}

@test "mq_is_branch_pattern returns true for chore/name" {
    run mq_is_branch_pattern "chore/cleanup"
    assert_success
}

@test "mq_is_branch_pattern returns true for nested paths" {
    run mq_is_branch_pattern "feature/auth/login"
    assert_success
}

@test "mq_is_branch_pattern returns false for simple names" {
    run mq_is_branch_pattern "my-feature"
    assert_failure
}

@test "mq_is_branch_pattern returns false for empty string" {
    run mq_is_branch_pattern ""
    assert_failure
}

# ============================================================================
# mq_default_merge_type tests
# ============================================================================

@test "mq_default_merge_type returns branch for branch pattern" {
    run mq_default_merge_type "feature/auth"
    assert_success
    assert_output "branch"
}

@test "mq_default_merge_type returns operation for simple name" {
    run mq_default_merge_type "auth"
    assert_success
    assert_output "operation"
}

@test "mq_default_merge_type returns operation for empty string" {
    run mq_default_merge_type ""
    assert_success
    assert_output "operation"
}
