#!/usr/bin/env bats
# Tests for v0-stop - Stop v0 workers
load '../packages/test-support/helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="$TEST_TEMP_DIR/isolated"
    mkdir -p "$isolated_dir/project/.v0/build/operations"
    cat > "$isolated_dir/project/.v0.rc" <<EOF
PROJECT="teststop"
ISSUE_PREFIX="ts"
EOF
    echo "$isolated_dir/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "stop shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" --help
    '
    assert_success
    assert_output --partial "Usage: v0 stop"
}

@test "stop shows usage with -h" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" -h
    '
    assert_success
    assert_output --partial "Usage: v0 stop"
}

# ============================================================================
# Invalid input tests
# ============================================================================

@test "stop with invalid worker shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" invalid 2>&1
    '
    assert_failure
    assert_output --partial "Unknown option or worker"
}

@test "stop with multiple workers shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" fix chore 2>&1
    '
    assert_failure
    assert_output --partial "Only one worker can be specified"
    assert_output --partial "v0 shutdown"
}

# ============================================================================
# Dry run tests
# ============================================================================

@test "stop --dry-run shows what would happen" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" --dry-run
    '
    assert_success
}

@test "stop fix --dry-run shows single worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" fix --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 fix --stop"
}

@test "stop chore --dry-run shows single worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" chore --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 chore --stop"
}

@test "stop mergeq --dry-run shows single worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" mergeq --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 mergeq --stop"
}

@test "stop --dry-run fix accepts options in any order" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" --dry-run fix
    '
    assert_success
    assert_output --partial "Would run: v0 fix --stop"
}

# ============================================================================
# Force flag tests
# ============================================================================

@test "stop --force fix shows warning about no effect" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-stop" --force fix --dry-run 2>&1
    '
    assert_success
    assert_output --partial "Would run: v0 fix --stop"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 stop command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" stop --help
    '
    assert_success
    assert_output --partial "Usage: v0 stop"
}

@test "v0 --help shows stop command" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    assert_output --partial "stop"
    assert_output --partial "Stop worker"
}
