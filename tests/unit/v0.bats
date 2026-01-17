#!/usr/bin/env bats
# Tests for v0 - Main command dispatcher
load '../helpers/test_helper'

# ============================================================================
# Usage and help tests
# ============================================================================

@test "v0 shows help with --help" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "v0 - A tool to ease you in to multi-agent vibe coding."
    assert_output --partial "Usage: v0 <command>"
}

@test "v0 shows help with -h" {
    run "${PROJECT_ROOT}/bin/v0" -h
    assert_success
    assert_output --partial "v0 - A tool to ease you in to multi-agent vibe coding."
}

@test "v0 shows help with no arguments" {
    run "${PROJECT_ROOT}/bin/v0"
    assert_success
    assert_output --partial "v0 - A tool to ease you in to multi-agent vibe coding."
}

@test "v0 shows version with --version" {
    run "${PROJECT_ROOT}/bin/v0" --version
    assert_success
    assert_output --partial "v0 "
}

@test "v0 help shows resume command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "resume"
    assert_output --partial "Resume an existing feature"
}

# ============================================================================
# Command dispatch tests
# ============================================================================

@test "v0 unknown command fails with error" {
    run "${PROJECT_ROOT}/bin/v0" notacommand
    assert_failure
    assert_output --partial "Unknown command: notacommand"
}

# ============================================================================
# Resume alias tests
# ============================================================================

@test "v0 resume requires config (dispatches to feature)" {
    # Without a config file, resume should fail with config error
    # This verifies it dispatches to feature which needs config
    run "${PROJECT_ROOT}/bin/v0" resume
    assert_failure
    assert_output --partial ".v0.rc"
}

@test "v0 resume shows feature usage when config exists" {
    # With config, resume without args shows feature usage
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" resume
    assert_failure  # usage exits with status 1
    assert_output --partial "Usage: v0 feature"
    assert_output --partial "--resume"
}

@test "v0 resume --help shows feature help" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" resume --help
    # usage() exits with status 1, but it shows the help
    assert_failure
    assert_output --partial "Usage: v0 feature"
    assert_output --partial "--resume"
}

@test "v0 resume passes arguments correctly" {
    create_v0rc "testproject" "test"
    setup_mock_binaries claude tmux

    # v0 resume myfeature --dry-run should become v0-feature --resume myfeature --dry-run
    # With dry-run, it will fail looking for the operation but shows it processed args
    run "${PROJECT_ROOT}/bin/v0" resume myfeature --dry-run
    assert_failure
    # Should indicate it's trying to resume 'myfeature'
    assert_output --partial "myfeature"
}

# ============================================================================
# Alias tests
# ============================================================================

@test "v0 feat routes to feature" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" feat --help
    # usage() exits 1 but shows help
    assert_failure
    assert_output --partial "Usage: v0 feature"
}

@test "v0 decomp routes to decompose" {
    create_v0rc "testproject" "test"
    # decompose without args shows usage
    run "${PROJECT_ROOT}/bin/v0" decomp
    # usage() exits 1 but shows help
    assert_failure
    assert_output --partial "Usage: v0 decompose"
}

@test "v0 bug routes to fix" {
    create_v0rc "testproject" "test"
    setup_mock_binaries claude tmux

    run "${PROJECT_ROOT}/bin/v0" bug --help
    # usage() exits 1 but shows help
    assert_failure
    assert_output --partial "Usage: v0 fix"
}

@test "v0 bugfix routes to fix" {
    create_v0rc "testproject" "test"
    setup_mock_binaries claude tmux

    run "${PROJECT_ROOT}/bin/v0" bugfix --help
    # usage() exits 1 but shows help
    assert_failure
    assert_output --partial "Usage: v0 fix"
}

# Note: v0 chat/talk forwards directly to claude command, doesn't have its own --help
@test "v0 chat routes to talk command" {
    # Just verify it doesn't error out with unknown command
    run "${PROJECT_ROOT}/bin/v0" chat --version 2>&1
    # Should show claude's version, not error about unknown command
    refute_output --partial "Unknown command"
}
