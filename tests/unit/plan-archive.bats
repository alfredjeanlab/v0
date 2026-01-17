#!/usr/bin/env bats
# Tests for archive_plan() function in v0-common.sh

load '../helpers/test_helper'

# ============================================================================
# archive_plan() tests
# ============================================================================

@test "archive_plan creates archive directory with date" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/test-feature.md"

    archive_plan "plans/test-feature.md"

    local archive_date
    archive_date=$(date +%Y-%m-%d)
    assert_dir_exists "${PLANS_DIR}/archive/${archive_date}"
}

@test "archive_plan moves plan to archive" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/test-feature.md"

    archive_plan "plans/test-feature.md"

    local archive_date
    archive_date=$(date +%Y-%m-%d)
    assert_file_exists "${PLANS_DIR}/archive/${archive_date}/test-feature.md"
    assert_file_not_exists "${PLANS_DIR}/test-feature.md"
}

@test "archive_plan returns 1 for missing file" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"

    run archive_plan "plans/nonexistent.md"
    assert_failure
}

@test "archive_plan returns 1 for empty argument" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    run archive_plan ""
    assert_failure
}

@test "archive_plan handles absolute paths" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/absolute-test.md"

    archive_plan "${PLANS_DIR}/absolute-test.md"

    local archive_date
    archive_date=$(date +%Y-%m-%d)
    assert_file_exists "${PLANS_DIR}/archive/${archive_date}/absolute-test.md"
}

@test "archive_plan preserves file content" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"
    cat > "${PLANS_DIR}/content-test.md" <<'EOF'
# Test Plan

This is test content with multiple lines.

## Details
- Item 1
- Item 2
EOF

    archive_plan "plans/content-test.md"

    local archive_date
    archive_date=$(date +%Y-%m-%d)
    run cat "${PLANS_DIR}/archive/${archive_date}/content-test.md"
    assert_success
    assert_output --partial "# Test Plan"
    assert_output --partial "This is test content"
    assert_output --partial "Item 1"
}

@test "archive_plan is idempotent (returns 1 if already archived)" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/idempotent-test.md"

    # First archive should succeed
    run archive_plan "plans/idempotent-test.md"
    assert_success

    # Second archive should fail (file no longer exists at source)
    run archive_plan "plans/idempotent-test.md"
    assert_failure
}

@test "archive_plan handles multiple plans on same day" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${PLANS_DIR}"
    echo "# Plan A" > "${PLANS_DIR}/plan-a.md"
    echo "# Plan B" > "${PLANS_DIR}/plan-b.md"

    archive_plan "plans/plan-a.md"
    archive_plan "plans/plan-b.md"

    local archive_date
    archive_date=$(date +%Y-%m-%d)
    assert_file_exists "${PLANS_DIR}/archive/${archive_date}/plan-a.md"
    assert_file_exists "${PLANS_DIR}/archive/${archive_date}/plan-b.md"
}
