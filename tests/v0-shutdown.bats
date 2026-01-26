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

    # Kill any stray polling daemons for this test project (from previous test runs)
    pkill -f "while true.*v0-testshutdown" 2>/dev/null || true

    # Clean up any nudge PID file that might exist
    rm -f "${project_dir}/.v0/build/nudge/.daemon.pid" 2>/dev/null || true

    # Run shutdown - should complete successfully
    # Note: May report "No v0 sessions" or may find/cleanup background daemons
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown"
    '
    assert_success
    # Should either report no sessions or complete shutdown
    [[ "$output" == *"No v0 sessions running"* ]] || [[ "$output" == *"Shutdown complete"* ]]
}

# ============================================================================
# Dry run tests
# ============================================================================

@test "shutdown --dry-run does not actually kill sessions" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Kill any stray polling daemons for this test project (from previous test runs)
    pkill -f "while true.*v0-testshutdown" 2>/dev/null || true

    # Clean up any nudge PID file that might exist
    rm -f "${project_dir}/.v0/build/nudge/.daemon.pid" 2>/dev/null || true

    # Create a mock session name file to track what would be killed
    # Note: In real usage, this would require a real tmux session
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --dry-run
    '
    assert_success
    # Dry-run should show what would be done (or report nothing to do)
    # Should NOT contain "Stopped" or "Deleted" (actual actions)
    refute_output --partial "Stopped nudge"
    refute_output --partial "Deleted local branch"
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
    assert_output --partial "Stop worker(s)"
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

    # Kill any stray polling daemons for this test project (from previous test runs)
    pkill -f "while true.*v0-testshutdown" 2>/dev/null || true

    # Clean up any nudge PID file that might exist
    rm -f "${project_dir}/.v0/build/nudge/.daemon.pid" 2>/dev/null || true

    # This test verifies the session pattern is correctly constructed
    # The output should reference testshutdown, not any other project
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown"
    '
    assert_success
    # Should either reference the project name or complete successfully
    [[ "$output" == *"testshutdown"* ]] || [[ "$output" == *"Shutdown complete"* ]]
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

@test "shutdown warns about unmerged v0/worker/chore branch (legacy)" {
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

@test "shutdown warns about unmerged user-specific chores branch" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create user-specific chores branch with unmerged commits
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-chores --quiet
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
    assert_output --partial "Warning: v0/agent/test-user-chores has commits not in main, skipping"
    assert_output --partial "some branches preserved"
}

@test "shutdown warns about unmerged v0/worker/fix branch (legacy)" {
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

@test "shutdown warns about unmerged user-specific bugs branch" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create user-specific bugs branch with unmerged commits
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-bugs --quiet
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
    assert_output --partial "Warning: v0/agent/test-user-bugs has commits not in main, skipping"
    assert_output --partial "some branches preserved"
}

@test "shutdown deletes merged v0/worker/chore branch without warning (legacy)" {
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

@test "shutdown deletes merged user-specific chores branch without warning" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create user-specific chores branch and merge it to main
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-chores --quiet
        echo "chore work" > chore.txt
        git add chore.txt
        git commit --quiet -m "Chore work"
        git checkout main --quiet
        git merge v0/agent/test-user-chores --quiet -m "Merge chore"
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" 2>&1
    '
    assert_success
    assert_output --partial "Deleting local branch: v0/agent/test-user-chores"
    refute_output --partial "Warning:"
    refute_output --partial "some branches preserved"
}

@test "shutdown --force deletes unmerged v0/worker/chore branch (legacy)" {
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

@test "shutdown --force deletes unmerged user-specific bugs branch" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # Create user-specific bugs branch with unmerged commits
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-bugs --quiet
        echo "fix work" > fix.txt
        git add fix.txt
        git commit --quiet -m "Fix work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --force 2>&1
    '
    assert_success
    assert_output --partial "Warning: v0/agent/test-user-bugs has commits not in main, deleting anyway (--force)"
    assert_output --partial "Deleting local branch: v0/agent/test-user-bugs"
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

# ============================================================================
# Drop-everything with v0/agent/* branches (worktree mode)
# ============================================================================

# Helper to create git repo with worktree mode config
setup_worktree_mode_project() {
    local project_dir="${TEST_TEMP_DIR}/worktree-project"
    mkdir -p "${project_dir}/.v0/build/operations"

    # Create .v0.rc with worktree mode (v0/agent/* branch)
    cat > "${project_dir}/.v0.rc" <<EOF
PROJECT="testshutdown"
ISSUE_PREFIX="ts"
V0_DEVELOP_BRANCH="v0/agent/test-user-abc1"
V0_WORKSPACE_MODE="worktree"
EOF

    # Initialize git repo with main branch
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

@test "shutdown --drop-workspace deletes v0/agent/* branch in worktree mode" {
    local project_dir
    project_dir=$(setup_worktree_mode_project)

    # Create the v0/agent/* develop branch
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-abc1 --quiet
        echo "agent work" > agent.txt
        git add agent.txt
        git commit --quiet -m "Agent work"
        git checkout main --quiet
    )

    # Verify branch exists before shutdown
    run git -C "${project_dir}" branch --list 'v0/agent/test-user-abc1'
    assert_output --partial "v0/agent/test-user-abc1"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --drop-workspace 2>&1
    '
    assert_success
    assert_output --partial "Cleaning up agent develop branches (worktree mode)"
    assert_output --partial "Deleting local branch: v0/agent/test-user-abc1"

    # Verify branch is deleted
    run git -C "${project_dir}" branch --list 'v0/agent/test-user-abc1'
    assert_output ""
}

@test "shutdown --drop-everything deletes v0/agent/* branch in worktree mode" {
    local project_dir
    project_dir=$(setup_worktree_mode_project)

    # Create the v0/agent/* develop branch
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-abc1 --quiet
        echo "agent work" > agent.txt
        git add agent.txt
        git commit --quiet -m "Agent work"
        git checkout main --quiet
    )

    # Verify branch exists before shutdown
    run git -C "${project_dir}" branch --list 'v0/agent/test-user-abc1'
    assert_output --partial "v0/agent/test-user-abc1"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --drop-everything 2>&1
    '
    assert_success
    assert_output --partial "Cleaning up agent develop branches (worktree mode)"
    assert_output --partial "Deleting local branch: v0/agent/test-user-abc1"

    # Verify branch is deleted
    run git -C "${project_dir}" branch --list 'v0/agent/test-user-abc1'
    assert_output ""
}

@test "shutdown --drop-everything does not delete v0/agent/*-bugs or *-chores (already handled)" {
    local project_dir
    project_dir=$(setup_worktree_mode_project)

    # Create both the develop branch and worker branches
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-abc1 --quiet
        echo "agent work" > agent.txt
        git add agent.txt
        git commit --quiet -m "Agent work"
        git checkout -b v0/agent/test-user-abc1-bugs --quiet
        echo "bugs work" > bugs.txt
        git add bugs.txt
        git commit --quiet -m "Bugs work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --drop-everything --force 2>&1
    '
    assert_success
    # Worker branches are handled in the worker branch section, not agent branch section
    assert_output --partial "Cleaning up local worker branches"
    # The agent develop branch should be handled in its own section
    assert_output --partial "Cleaning up agent develop branches (worktree mode)"
    assert_output --partial "Deleting local branch: v0/agent/test-user-abc1"
}

@test "shutdown --drop-workspace does NOT delete develop branch in clone mode" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # The setup_git_project_with_branches uses main as develop branch (clone mode)
    # Verify main branch exists before shutdown
    run git -C "${project_dir}" branch --list 'main'
    assert_output --partial "main"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --drop-workspace 2>&1
    '
    assert_success
    # Should NOT see agent branch cleanup message (clone mode)
    refute_output --partial "Cleaning up agent develop branches"

    # Verify main branch still exists
    run git -C "${project_dir}" branch --list 'main'
    assert_output --partial "main"
}

@test "shutdown --drop-everything does NOT delete develop branch in clone mode" {
    local project_dir
    project_dir=$(setup_git_project_with_branches)

    # The setup_git_project_with_branches uses main as develop branch (clone mode)
    # Verify main branch exists before shutdown
    run git -C "${project_dir}" branch --list 'main'
    assert_output --partial "main"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --drop-everything 2>&1
    '
    assert_success
    # Should NOT see agent branch cleanup message (clone mode)
    refute_output --partial "Cleaning up agent develop branches"

    # Verify main branch still exists
    run git -C "${project_dir}" branch --list 'main'
    assert_output --partial "main"
}

@test "shutdown without --drop-everything does NOT delete v0/agent/* branch" {
    local project_dir
    project_dir=$(setup_worktree_mode_project)

    # Create the v0/agent/* develop branch
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-abc1 --quiet
        echo "agent work" > agent.txt
        git add agent.txt
        git commit --quiet -m "Agent work"
        git checkout main --quiet
    )

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" 2>&1
    '
    assert_success
    # Should NOT see agent branch cleanup (no --drop-everything)
    refute_output --partial "Cleaning up agent develop branches"

    # Verify branch still exists
    run git -C "${project_dir}" branch --list 'v0/agent/test-user-abc1'
    assert_output --partial "v0/agent/test-user-abc1"
}

# ============================================================================
# Worktree branch prefix handling tests
# ============================================================================

@test "shutdown handles branches with + prefix (checked out in worktree)" {
    local project_dir
    project_dir=$(setup_worktree_mode_project)

    # Create the v0/agent/* develop branch
    (
        cd "${project_dir}" || return 1
        git checkout -b v0/agent/test-user-abc1 --quiet
        echo "agent work" > agent.txt
        git add agent.txt
        git commit --quiet -m "Agent work"
    )

    # Create a worktree that checks out the branch (this adds + prefix in git branch output)
    local worktree_dir="${TEST_TEMP_DIR}/worktree"
    mkdir -p "${worktree_dir}"
    (
        cd "${project_dir}" || return 1
        git worktree add "${worktree_dir}/checkout" v0/agent/test-user-abc1 --quiet 2>/dev/null || true
    )

    # Verify branch shows with + prefix
    run git -C "${project_dir}" branch --list 'v0/agent/test-user-abc1'
    # Output should contain the branch (may have + prefix if worktree succeeded)
    assert_output --partial "v0/agent/test-user-abc1"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-shutdown" --drop-everything --force 2>&1
    '
    assert_success
    assert_output --partial "Cleaning up agent develop branches (worktree mode)"
    # Should show the branch name without + prefix
    assert_output --partial "Deleting local branch: v0/agent/test-user-abc1"
    # Should NOT show + prefix in branch name (that was the bug)
    refute_output --partial "Deleting local branch: + v0/agent"
    refute_output --partial "Deleting local branch: +"
}
