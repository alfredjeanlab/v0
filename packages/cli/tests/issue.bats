#!/usr/bin/env bats
# Tests for packages/cli/lib/build/issue.sh - Issue filing utilities

load '../../test-support/helpers/test_helper'

setup() {
    _base_setup

    # Add mock-bin to PATH for mock wk command
    export PATH="${TESTS_DIR}/helpers/mock-bin:${PATH}"

    # Source the issue.sh library directly
    source "${PROJECT_ROOT}/packages/cli/lib/build/issue.sh"
}

# ============================================================================
# create_feature_issue() tests
# ============================================================================

@test "create_feature_issue returns issue ID on success" {
    export MOCK_WK_NEW_ID="test-xyz1"

    run create_feature_issue "test-op"
    assert_success
    assert_output "test-xyz1"
}

@test "create_feature_issue uses default ID from mock" {
    run create_feature_issue "my-feature"
    assert_success
    assert_output "mock-abc1"
}

@test "create_feature_issue returns empty on wk failure" {
    export MOCK_WK_NEW_FAIL=1

    run create_feature_issue "test-op"
    assert_failure
}

@test "create_feature_issue extracts ID from wk output format" {
    # Verify the regex works with the expected format
    export MOCK_WK_NEW_ID="v0-def2"

    run create_feature_issue "auth-feature"
    assert_success
    assert_output "v0-def2"
}

# ============================================================================
# file_plan_issue() without existing ID tests (backwards compatibility)
# ============================================================================

@test "file_plan_issue creates new issue when no existing ID provided" {
    # Create a plan file
    echo "# Test Plan" > "${TEST_TEMP_DIR}/test.md"

    run file_plan_issue "test-op" "${TEST_TEMP_DIR}/test.md"
    assert_success
    assert_output "mock-abc1"
}

@test "file_plan_issue with custom ID" {
    export MOCK_WK_NEW_ID="custom-id1"
    echo "# My Plan" > "${TEST_TEMP_DIR}/plan.md"

    run file_plan_issue "my-op" "${TEST_TEMP_DIR}/plan.md"
    assert_success
    assert_output "custom-id1"
}

@test "file_plan_issue fails when plan file not found" {
    run file_plan_issue "test-op" "/nonexistent/plan.md"
    assert_failure
    assert_output --partial "plan file not found"
}

@test "file_plan_issue fails when wk new fails" {
    echo "# Plan" > "${TEST_TEMP_DIR}/plan.md"
    export MOCK_WK_NEW_FAIL=1

    run file_plan_issue "test-op" "${TEST_TEMP_DIR}/plan.md"
    assert_failure
    assert_output --partial "wk new failed"
}

# ============================================================================
# file_plan_issue() with existing ID tests (update mode)
# ============================================================================

@test "file_plan_issue with existing ID returns that ID" {
    echo "# Test Plan Content" > "${TEST_TEMP_DIR}/test.md"

    run file_plan_issue "test-op" "${TEST_TEMP_DIR}/test.md" "existing-id"
    assert_success
    assert_output "existing-id"
}

@test "file_plan_issue with existing ID does not call wk new" {
    echo "# Plan" > "${TEST_TEMP_DIR}/plan.md"
    # If wk new was called, this would make it fail
    export MOCK_WK_NEW_FAIL=1

    # Should succeed because wk new should NOT be called when existing_id is provided
    run file_plan_issue "test-op" "${TEST_TEMP_DIR}/plan.md" "pre-existing-id"
    assert_success
    assert_output "pre-existing-id"
}

@test "file_plan_issue updates existing issue with plan content" {
    # Create plan file with specific content
    echo "# My Feature Plan" > "${TEST_TEMP_DIR}/plan.md"
    echo "This is the implementation plan." >> "${TEST_TEMP_DIR}/plan.md"

    # The mock wk edit command succeeds silently
    # We just verify the function completes successfully with the existing ID
    run file_plan_issue "my-feature" "${TEST_TEMP_DIR}/plan.md" "feature-id"
    assert_success
    assert_output "feature-id"
}

@test "file_plan_issue with existing ID still fails on missing plan file" {
    run file_plan_issue "test-op" "/nonexistent/plan.md" "existing-id"
    assert_failure
    assert_output --partial "plan file not found"
}

# ============================================================================
# Edge cases
# ============================================================================

@test "create_feature_issue handles hyphenated names" {
    export MOCK_WK_NEW_ID="proj-feat1"

    run create_feature_issue "my-complex-feature-name"
    assert_success
    assert_output "proj-feat1"
}

@test "file_plan_issue handles multiline plan content" {
    cat > "${TEST_TEMP_DIR}/plan.md" <<'EOF'
# Complex Plan

## Overview
This is a multi-line plan.

## Tasks
- Task 1
- Task 2
- Task 3

## Notes
Special characters: `code`, *bold*, _italic_
EOF

    run file_plan_issue "complex-plan" "${TEST_TEMP_DIR}/plan.md"
    assert_success
    assert_output "mock-abc1"
}
