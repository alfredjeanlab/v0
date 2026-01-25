#!/usr/bin/env bats
# Tests for help output formatting
# Verifies that --start/--stop flags are hidden from user-facing help
load '../packages/test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env
}

# ============================================================================
# Main v0 help shows start/stop with worker pattern
# ============================================================================

@test "v0 help shows 'v0 start' command" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    assert_output --partial "v0 start"
}

@test "v0 help shows 'v0 stop' command" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    assert_output --partial "v0 stop"
}

@test "v0 help shows worker sub-options pattern" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    # Should show the worker options in some form
    assert_output --partial "[fix|chore|mergeq]"
}

# ============================================================================
# v0-fix help should NOT show --start/--stop
# ============================================================================

@test "v0 fix help hides --start flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-fix" --help
    # usage() exits with 1
    assert_failure
    # Should not show --start as a documented option
    refute_output --partial "  --start"
    refute_output --partial "Start worker"
}

@test "v0 fix help hides --stop flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-fix" --help
    # usage() exits with 1
    assert_failure
    # Should not show --stop as a documented option
    refute_output --partial "  --stop"
    refute_output --partial "Stop the worker"
}

@test "v0 fix help shows --status flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-fix" --help
    # usage() exits with 1
    assert_failure
    # --status should still be visible
    assert_output --partial "--status"
}

@test "v0 fix help shows --history flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-fix" --help
    # usage() exits with 1
    assert_failure
    # --history should still be visible
    assert_output --partial "--history"
}

# ============================================================================
# v0-chore help should NOT show --start/--stop
# ============================================================================

@test "v0 chore help hides --start flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-chore" --help
    # usage() exits with 1
    assert_failure
    refute_output --partial "  --start"
    refute_output --partial "Start worker"
}

@test "v0 chore help hides --stop flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-chore" --help
    # usage() exits with 1
    assert_failure
    refute_output --partial "  --stop"
    refute_output --partial "Stop the worker"
}

@test "v0 chore help shows --status flag" {
    setup_mock_binaries claude tmux

    run "$PROJECT_ROOT/bin/v0-chore" --help
    # usage() exits with 1
    assert_failure
    assert_output --partial "--status"
}

# ============================================================================
# v0-mergeq help should NOT show --start/--stop
# ============================================================================

@test "v0 mergeq help hides --start flag" {
    run "$PROJECT_ROOT/bin/v0-mergeq" --help
    # usage() exits with 1
    assert_failure
    refute_output --partial "  --start"
    refute_output --partial "Start daemon"
}

@test "v0 mergeq help hides --stop flag" {
    run "$PROJECT_ROOT/bin/v0-mergeq" --help
    # usage() exits with 1
    assert_failure
    refute_output --partial "  --stop"
    refute_output --partial "Stop the daemon"
}

@test "v0 mergeq help shows --status flag" {
    run "$PROJECT_ROOT/bin/v0-mergeq" --help
    # usage() exits with 1
    assert_failure
    assert_output --partial "--status"
}

# ============================================================================
# v0-start and v0-stop help should be clear
# ============================================================================

@test "v0 start help shows worker options" {
    run "$PROJECT_ROOT/bin/v0-start" --help
    assert_success
    assert_output --partial "fix"
    assert_output --partial "chore"
    assert_output --partial "mergeq"
}

@test "v0 stop help shows worker options" {
    run "$PROJECT_ROOT/bin/v0-stop" --help
    assert_success
    assert_output --partial "fix"
    assert_output --partial "chore"
    assert_output --partial "mergeq"
}

# ============================================================================
# v0-prime shows modern commands
# ============================================================================

@test "v0 prime shows 'v0 start' not 'v0 startup'" {
    run "$PROJECT_ROOT/bin/v0-prime"
    assert_success
    assert_output --partial "v0 start"
    # Should not show the old 'v0 startup' in the getting started section
    refute_output --partial "v0 startup"
}
