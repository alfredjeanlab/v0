#!/usr/bin/env bats
# Tests for alias and backward-compatibility behavior
# Verifies that hidden --start/--stop flags still work
load '../packages/test-support/helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="$TEST_TEMP_DIR/isolated"
    mkdir -p "$isolated_dir/project/.v0/build/operations"
    cat > "$isolated_dir/project/.v0.rc" <<EOF
PROJECT="testaliases"
ISSUE_PREFIX="ta"
EOF
    echo "$isolated_dir/project"
}

setup() {
    _base_setup
    setup_v0_env
}

# ============================================================================
# Hidden --start/--stop flags still work
# ============================================================================

@test "v0 fix --start still works (hidden alias)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    # Should not error with "Unknown option"
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-fix" --start 2>&1
    '
    # May fail for other reasons (tmux not available, etc.) but not "Unknown option"
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 fix --stop still works (hidden alias)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-fix" --stop 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 chore --start still works (hidden alias)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-chore" --start 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 chore --stop still works (hidden alias)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-chore" --stop 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 mergeq --start still works (hidden alias)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-mergeq" --start 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 mergeq --stop still works (hidden alias)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-mergeq" --stop 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

# ============================================================================
# Positional start/stop arguments still work
# ============================================================================

@test "v0 fix start still works (positional)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-fix" start 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 fix stop still works (positional)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-fix" stop 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

@test "v0 chore start still works (positional)" {
    setup_mock_binaries claude tmux
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-chore" start 2>&1
    '
    refute_output --partial "Unknown option"
    refute_output --partial "Unknown flag"
}

# ============================================================================
# startup/shutdown aliases still work
# ============================================================================

@test "v0 startup still works (hidden alias)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" startup --dry-run 2>&1
    '
    assert_success
    # Startup with dry-run should show what it would do
    assert_output --partial "Would"
}

@test "v0 shutdown still works (hidden alias)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Kill any stray polling daemons for this test project
    pkill -f "while true.*v0-testaliases" 2>/dev/null || true

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" shutdown --dry-run 2>&1
    '
    assert_success
    # Shutdown should either report nothing to do or show what it would do
    assert_output --partial "testaliases"
}

# ============================================================================
# Primary v0 start/stop commands work
# ============================================================================

@test "v0 start fix --dry-run works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" start fix --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 fix --start"
}

@test "v0 start chore --dry-run works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" start chore --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 chore --start"
}

@test "v0 start mergeq --dry-run works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" start mergeq --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 mergeq --start"
}

@test "v0 stop fix --dry-run works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" stop fix --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 fix --stop"
}

@test "v0 stop chore --dry-run works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" stop chore --dry-run
    '
    assert_success
    assert_output --partial "Would run: v0 chore --stop"
}
