#!/usr/bin/env bats
# Tests for v0-start - Start v0 workers
load '../packages/test-support/helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="$TEST_TEMP_DIR/isolated"
    mkdir -p "$isolated_dir/project/.v0/build/operations"
    cat > "$isolated_dir/project/.v0.rc" <<EOF
PROJECT="teststart"
ISSUE_PREFIX="ts"
EOF
    echo "$isolated_dir/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "start shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" --help
    '
    assert_success
    assert_output --partial "Usage: v0 start"
}

@test "start shows usage with -h" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" -h
    '
    assert_success
    assert_output --partial "Usage: v0 start"
}

# ============================================================================
# Invalid input tests
# ============================================================================

@test "start with invalid worker shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" invalid 2>&1
    '
    assert_failure
    assert_output --partial "Unknown option or worker"
}

@test "start with multiple workers shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" fix chore 2>&1
    '
    assert_failure
    assert_output --partial "Only one worker can be specified"
    assert_output --partial "v0 startup"
}

# ============================================================================
# Dry run tests
# ============================================================================

@test "start --dry-run shows what would happen" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" --dry-run
    '
    assert_success
    assert_output --partial "Would start"
}

@test "start fix --dry-run shows single worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" fix --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 fix --start"
}

@test "start chore --dry-run shows single worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" chore --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 chore --start"
}

@test "start mergeq --dry-run shows single worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" mergeq --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 mergeq --start"
}

@test "start --dry-run fix accepts options in any order" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-start" --dry-run fix
    '
    assert_success
    assert_output --partial "Would run: v0 fix --start"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 start command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" start --help
    '
    assert_success
    assert_output --partial "Usage: v0 start"
}

@test "v0 --help shows start command" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    assert_output --partial "start"
    assert_output --partial "Start worker"
}
