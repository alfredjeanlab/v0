#!/usr/bin/env bats
# Tests for v0-startup - Start v0 workers for a project
load '../packages/test-support/helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="$TEST_TEMP_DIR/isolated"
    mkdir -p "$isolated_dir/project/.v0/build/operations"
    cat > "$isolated_dir/project/.v0.rc" <<EOF
PROJECT="teststartup"
ISSUE_PREFIX="ts"
EOF
    echo "$isolated_dir/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "startup shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --help
    '
    assert_success
    assert_output --partial "Usage: v0 start"
    assert_output --partial "Start v0 workers"
}

@test "startup shows usage with -h" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" -h
    '
    assert_success
    assert_output --partial "Usage: v0 start"
}

# ============================================================================
# Dry run tests
# ============================================================================

@test "startup --dry-run shows what would be started" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run
    '
    assert_success
    assert_output --partial "Would start: v0 fix --start"
    assert_output --partial "Would start: v0 chore --start"
    assert_output --partial "Would start: v0 mergeq --start"
}

@test "startup --dry-run fix shows only fix worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run fix
    '
    assert_success
    assert_output --partial "Would start: v0 fix --start"
    refute_output --partial "Would start: v0 chore --start"
    refute_output --partial "Would start: v0 mergeq --start"
}

@test "startup --dry-run with multiple workers shows only those workers" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run fix chore
    '
    assert_success
    assert_output --partial "Would start: v0 fix --start"
    assert_output --partial "Would start: v0 chore --start"
    refute_output --partial "Would start: v0 mergeq --start"
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
    assert_output --partial "Start workers"
}

@test "startup is a hidden alias for start" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" startup --help
    '
    assert_success
    assert_output --partial "Usage: v0 start"
}

@test "v0 --help does not show startup (hidden alias)" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    refute_output --partial "startup"
    assert_output --partial "start"
}

# ============================================================================
# Option validation tests
# ============================================================================

@test "startup rejects unknown options" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --invalid 2>&1
    '
    assert_failure
    assert_output --partial "Unknown option or worker: --invalid"
}

@test "startup rejects unknown worker names" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run unknown 2>&1
    '
    assert_failure
    assert_output --partial "Unknown option or worker: unknown"
}

# ============================================================================
# Worker specification tests
# ============================================================================

@test "startup accepts fix worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run fix
    '
    assert_success
    assert_output --partial "Would start: v0 fix --start"
}

@test "startup accepts chore worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run chore
    '
    assert_success
    assert_output --partial "Would start: v0 chore --start"
}

@test "startup accepts mergeq worker" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run mergeq
    '
    assert_success
    assert_output --partial "Would start: v0 mergeq --start"
}

@test "startup accepts all three workers" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-startup" --dry-run fix chore mergeq
    '
    assert_success
    assert_output --partial "Would start: v0 fix --start"
    assert_output --partial "Would start: v0 chore --start"
    assert_output --partial "Would start: v0 mergeq --start"
}
