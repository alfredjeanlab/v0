#!/usr/bin/env bats
# v0-merge.bats - Tests for v0-merge script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_MERGE="${PROJECT_ROOT}/bin/v0-merge"

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
EOF
    echo "${isolated_dir}/project"
}

setup() {
    _base_setup
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-merge: no arguments shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'"
    '
    assert_failure
    assert_output --partial "Usage: v0 merge"
}

# ============================================================================
# Argument Parsing Tests
# ============================================================================

@test "v0-merge: --resolve after operation name works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" nonexistent --resolve 2>&1
    '
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
    refute_output --partial "No operation found for '--resolve'"
}

@test "v0-merge: --resolve before operation name works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" --resolve nonexistent 2>&1
    '
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
    refute_output --partial "No operation found for '--resolve'"
}

@test "v0-merge: only --resolve shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" --resolve
    '
    assert_failure
    assert_output --partial "Usage: v0 merge"
}
