#!/usr/bin/env bats
# Tests for v0-monitor - Monitor worker queues and auto-shutdown
load '../helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    mkdir -p "${isolated_dir}/project/.v0/build/mergeq"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testmonitor"
ISSUE_PREFIX="tm"
EOF
    echo "${isolated_dir}/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "monitor shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-monitor" --help
    '
    assert_success
    assert_output --partial "Usage: v0 monitor"
    assert_output --partial "Monitor worker queues"
}

@test "monitor shows usage with -h" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-monitor" -h
    '
    assert_success
    assert_output --partial "Usage: v0 monitor"
}

@test "monitor shows usage with no arguments" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-monitor"
    '
    assert_success
    assert_output --partial "Usage: v0 monitor"
}

# ============================================================================
# Status tests
# ============================================================================

@test "monitor --status when not running" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        export V0_STATE_DIR="'"${project_dir}"'/.v0"
        "'"${PROJECT_ROOT}"'/bin/v0-monitor" --status
    '
    assert_failure
    assert_output --partial "Monitor is not running"
}

# ============================================================================
# Stop tests
# ============================================================================

@test "monitor --stop when not running is safe" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        export V0_STATE_DIR="'"${project_dir}"'/.v0"
        "'"${PROJECT_ROOT}"'/bin/v0-monitor" --stop
    '
    assert_success
    assert_output --partial "Monitor is not running"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 monitor command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" monitor --help
    '
    assert_success
    assert_output --partial "Usage: v0 monitor"
}

@test "v0 --help shows monitor command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "monitor"
}

# ============================================================================
# Option validation tests
# ============================================================================

@test "monitor rejects unknown options" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-monitor" --invalid 2>&1
    '
    assert_success  # Shows usage instead of failing
    assert_output --partial "Unknown option: --invalid"
}
