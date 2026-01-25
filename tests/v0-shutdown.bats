#!/usr/bin/env bats
# Tests for v0-shutdown - Stop all v0 processes for a project
load '../packages/test-support/helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testshutdown"
ISSUE_PREFIX="ts"
EOF
    echo "${isolated_dir}/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "shutdown shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --help
    '
    assert_success  # help exits with 0
    assert_output --partial "Usage: v0 stop"
    assert_output --partial "Stop all v0 workers"
}

@test "shutdown shows usage with -h" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" -h
    '
    assert_success
    assert_output --partial "Usage: v0 stop"
}

# ============================================================================
# No sessions tests
# ============================================================================

@test "shutdown reports no sessions when project has none" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Run shutdown - should report no sessions for testshutdown project
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown"
    '
    assert_success
    assert_output --partial "No v0 sessions running for project: testshutdown"
}

# ============================================================================
# Dry run tests
# ============================================================================

@test "shutdown --dry-run does not actually kill sessions" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a mock session name file to track what would be killed
    # Note: In real usage, this would require a real tmux session
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --dry-run
    '
    assert_success
    # With no sessions, dry-run should still report nothing to do
    assert_output --partial "No v0 sessions running for project: testshutdown"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 stop command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" stop --help
    '
    assert_success
    assert_output --partial "Usage: v0 stop"
}

@test "v0 --help shows stop command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "stop"
    assert_output --partial "Stop all v0 processes"
}

@test "shutdown is a hidden alias for stop" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" shutdown --help
    '
    assert_success
    assert_output --partial "Usage: v0 stop"
}

@test "v0 --help does not show shutdown (hidden alias)" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    refute_output --partial "shutdown"
    assert_output --partial "stop"
}

# ============================================================================
# Option validation tests
# ============================================================================

@test "shutdown rejects unknown options" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --invalid 2>&1
    '
    assert_failure
    assert_output --partial "Unknown option: --invalid"
}

# ============================================================================
# Session pattern tests
# ============================================================================

@test "shutdown only targets sessions for current project" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # This test verifies the session pattern is correctly constructed
    # The output should reference testshutdown, not any other project
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown"
    '
    assert_success
    assert_output --partial "testshutdown"
}

# ============================================================================
# Unmerged branch protection tests
# ============================================================================

# Helper to create git repo with branches for testing unmerged protection
setup_git_project_with_branches() {
    local project_dir="${TEST_TEMP_DIR}/gitproject"
    mkdir -p "${project_dir}/.v0/build/operations"

    # Create .v0.rc with explicit main branch (tests use main for merge checks)
    cat > "${project_dir}/.v0.rc" <<EOF
PROJECT="testshutdown"
ISSUE_PREFIX="ts"
V0_DEVELOP_BRANCH="main"
EOF

    # Initialize git repo with explicit main branch
    (
        cd "${project_dir}" || return 1
        git init --quiet --initial-branch=main
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "initial" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
    )

    echo "${project_dir}"
}

@test "shutdown warns about unmerged v0/worker/chore branch" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create v0/worker/chore branch with unmerged commits
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/worker/chore --quiet
        echo "chore work" > chore.txt
        git add chore.txt
        git commit --quiet -m "Chore work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" 2>&1
    '
    assert_success
    assert_output --partial "Warning: v0/worker/chore has commits not in main, skipping"
    assert_output --partial "some branches preserved"
}

@test "shutdown warns about unmerged v0/worker/fix branch" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create v0/worker/fix branch with unmerged commits
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/worker/fix --quiet
        echo "fix work" > fix.txt
        git add fix.txt
        git commit --quiet -m "Fix work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" 2>&1
    '
    assert_success
    assert_output --partial "Warning: v0/worker/fix has commits not in main, skipping"
    assert_output --partial "some branches preserved"
}

@test "shutdown deletes merged v0/worker/chore branch without warning" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create v0/worker/chore branch and merge it to main
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/worker/chore --quiet
        echo "chore work" > chore.txt
        git add chore.txt
        git commit --quiet -m "Chore work"
        git checkout main --quiet
        git merge v0/worker/chore --quiet -m "Merge chore"
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" 2>&1
    '
    assert_success
    assert_output --partial "Deleting local branch: v0/worker/chore"
    refute_output --partial "Warning:"
    refute_output --partial "some branches preserved"
}

@test "shutdown --force deletes unmerged v0/worker/chore branch" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create v0/worker/chore branch with unmerged commits
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/worker/chore --quiet
        echo "chore work" > chore.txt
        git add chore.txt
        git commit --quiet -m "Chore work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --force 2>&1
    '
    assert_success
    assert_output --partial "Warning: v0/worker/chore has commits not in main, deleting anyway (--force)"
    assert_output --partial "Deleting local branch: v0/worker/chore"
    refute_output --partial "some branches preserved"
}

@test "shutdown deletes other v0/worker/* branches without checking" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create v0/worker/feature branch with unmerged commits (should be deleted without warning)
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/worker/feature --quiet
        echo "feature work" > feature.txt
        git add feature.txt
        git commit --quiet -m "Feature work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" 2>&1
    '
    assert_success
    assert_output --partial "Deleting local branch: v0/worker/feature"
    refute_output --partial "Warning:"
}
