#!/usr/bin/env bats
# v0-wait.bats - Tests for v0-wait script

load '../packages/test-support/helpers/test_helper'

V0_WAIT="${PROJECT_ROOT}/bin/v0-wait"

setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
EOF
    echo "${isolated_dir}/project"
}

create_isolated_operation() {
    local project_dir="$1"
    local op_name="$2"
    local json_content="$3"
    local op_dir="${project_dir}/.v0/build/operations/${op_name}"
    mkdir -p "${op_dir}"
    echo "${json_content}" > "${op_dir}/state.json"
}

setup() {
    _base_setup
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-wait: --help shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --help
    '
    assert_success
    assert_output --partial "Usage: v0 wait"
    assert_output --partial "Wait for an operation"
}

@test "v0-wait: requires operation name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'"
    '
    assert_failure
    assert_output --partial "Operation name or --issue required"
}

@test "v0-wait: unknown option shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option"
}

# ============================================================================
# Immediate Completion Tests
# ============================================================================

@test "v0-wait: returns 0 for merged operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: returns 1 for cancelled operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "cancelled", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_failure
    [ "$status" -eq 1 ]
    assert_output --partial "ended with phase: cancelled"
}

@test "v0-wait: returns 3 for non-existent operation" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" nonexistent
    '
    assert_failure
    [ "$status" -eq 3 ]
    assert_output --partial "not found"
}

# ============================================================================
# Issue ID Tests
# ============================================================================

@test "v0-wait: finds operation by issue ID" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine", "epic_id": "TEST-123"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --issue TEST-123
    '
    assert_success
    assert_output --partial "Found operation 'testop'"
    assert_output --partial "completed successfully"
}

@test "v0-wait: returns 3 for unknown issue ID" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --issue UNKNOWN-999
    '
    assert_failure
    [ "$status" -eq 3 ]
    assert_output --partial "No operation found for issue"
}

# ============================================================================
# Timeout Tests
# ============================================================================

@test "v0-wait: timeout returns 2 for non-terminal operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout 1s
    '
    assert_failure
    [ "$status" -eq 2 ]
    assert_output --partial "Timeout"
}

@test "v0-wait: parses duration formats correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    # Test seconds format
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout 1s
    '
    assert_failure
    [ "$status" -eq 2 ]

    # Test invalid format
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout invalid
    '
    assert_failure
    assert_output --partial "Invalid duration format"
}

# ============================================================================
# Quiet Mode Tests
# ============================================================================

@test "v0-wait: --quiet suppresses progress output" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --quiet
    '
    assert_success
    assert_output ""
}

# ============================================================================
# v0 Command Integration Tests
# ============================================================================

@test "v0 wait command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" wait --help
    '
    assert_success
    assert_output --partial "Usage: v0 wait"
}

@test "v0 --help shows wait command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "wait"
}
