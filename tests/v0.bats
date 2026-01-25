#!/usr/bin/env bats
# Tests for v0 - Main command dispatcher
load '../packages/test-support/helpers/test_helper'

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

@test "v0 help does not show tree command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    # Check that 'tree' is not listed as a command (with leading spaces indicating a command entry)
    refute_output --partial "  tree "
}

@test "v0 help shows resume in same section as cancel" {
    # resume should be grouped with cancel/hold/prune (operational control commands)
    # not with feat/plan (feature pipeline commands)
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    # Extract the section containing cancel and verify resume is nearby
    # Cancel and resume should be within a few lines of each other
    local cancel_line resume_line
    cancel_line=$(echo "$output" | grep -n "cancel" | head -1 | cut -d: -f1)
    resume_line=$(echo "$output" | grep -n "resume" | head -1 | cut -d: -f1)
    # They should be close together (within 5 lines)
    local diff=$((resume_line - cancel_line))
    if [[ $diff -lt 0 ]]; then
        diff=$((-diff))
    fi
    [[ $diff -le 5 ]]
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

@test "v0 resume shows build usage when config exists" {
    # With config, resume without args shows build usage
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" resume
    assert_failure  # usage exits with status 1
    assert_output --partial "Usage: v0 build"
    assert_output --partial "--resume"
}

@test "v0 resume --help shows build help" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" resume --help
    # usage() exits with status 1, but it shows the help
    assert_failure
    assert_output --partial "Usage: v0 build"
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

@test "v0 feat routes to build" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" feat --help
    # usage() exits 1 but shows help
    assert_failure
    assert_output --partial "Usage: v0 build"
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

# ============================================================================
# Show alias tests (undocumented alias for status)
# ============================================================================

@test "v0 show routes to status" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" show
    # Don't require assert_success since status may return non-zero in certain states
    assert_output --partial "Plans:"
}

@test "v0 show with feature name routes to status" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" show nonexistent-feature
    assert_failure
    assert_output --partial "No operation found"
}

@test "v0 show fix routes to status --fix" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" show fix
    assert_success
    assert_output --partial "Fix Worker:"
}

@test "v0 show chore routes to status --chore" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" show chore
    assert_success
    assert_output --partial "Chore Worker:"
}

@test "v0 show merge routes to status --merge" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" show merge
    assert_success
    assert_output --partial "Merge Queue Status:"
}

@test "v0 show mergeq routes to status --merge" {
    create_v0rc "testproject" "test"
    run "${PROJECT_ROOT}/bin/v0" show mergeq
    assert_success
    assert_output --partial "Merge Queue Status:"
}

@test "v0 show is not in help (undocumented)" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    refute_output --partial "show"
}
