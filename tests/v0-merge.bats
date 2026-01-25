#!/usr/bin/env bats
# v0-merge.bats - Tests for v0-merge script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_MERGE="${PROJECT_ROOT}/bin/v0-merge"

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
EOF
    echo "${isolated_dir}/project"
}

setup() {
    _base_setup
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-merge: no arguments shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'"
    '
    assert_failure
    assert_output --partial "Usage: v0 merge"
}

# ============================================================================
# Argument Parsing Tests
# ============================================================================

@test "v0-merge: --resolve after operation name works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" nonexistent --resolve 2>&1
    '
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
    refute_output --partial "No operation found for '--resolve'"
}

@test "v0-merge: --resolve before operation name works" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" --resolve nonexistent 2>&1
    '
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
    refute_output --partial "No operation found for '--resolve'"
}

@test "v0-merge: only --resolve shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" --resolve
    '
    assert_failure
    assert_output --partial "Usage: v0 merge"
}

# ============================================================================
# Worktree-less Merge Tests
# ============================================================================

@test "v0-merge: operation with missing worktree but existing branch succeeds for fast-forward" {
    skip "requires real git repository setup with remote"
    # This test would require a more complex setup with a bare remote repository
    # to properly test the branch-only merge flow
}

@test "v0-merge: operation with missing worktree and missing branch fails" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create operation state with worktree that doesn't exist and branch that doesn't exist
    mkdir -p "${project_dir}/.v0/build/operations/test-op"
    cat > "${project_dir}/.v0/build/operations/test-op/state.json" <<EOF
{
    "name": "test-op",
    "phase": "completed",
    "worktree": "/nonexistent/path/to/worktree",
    "branch": "feature/nonexistent-branch"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" test-op 2>&1
    '
    assert_failure
    assert_output --partial "Worktree not found and branch"
}

@test "v0-merge: outputs message when merging without worktree" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Initialize git repo
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"

    # Create feature branch
    git checkout -b feature/test-branch --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git checkout main --quiet 2>/dev/null || git checkout master --quiet

    # Create operation state pointing to the branch but with missing worktree
    mkdir -p "${project_dir}/.v0/build/operations/test-op"
    cat > "${project_dir}/.v0/build/operations/test-op/state.json" <<EOF
{
    "name": "test-op",
    "phase": "completed",
    "worktree": "/nonexistent/path/to/worktree",
    "branch": "feature/test-branch"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" test-op 2>&1
    '
    # This should succeed with fast-forward merge (no remote needed for local branch)
    # Note: Will fail on push since there's no remote, but should show the no-worktree message
    assert_output --partial "No worktree found. Attempting direct branch merge"
}

# ============================================================================
# Queue-based Branch Merge Tests
# ============================================================================

@test "v0-merge: queue entry with no state file resolves local branch" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Initialize git repo
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"

    # Create feature branch
    git checkout -b feature/queue-test --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git checkout main --quiet 2>/dev/null || git checkout master --quiet

    # Create queue entry without operation state (simulate external queue addition)
    mkdir -p "${project_dir}/.v0/build/mergeq"
    cat > "${project_dir}/.v0/build/mergeq/queue.json" <<EOF
{
    "version": 1,
    "entries": [
        {
            "operation": "feature/queue-test",
            "worktree": "",
            "priority": 0,
            "enqueued_at": "2026-01-01T00:00:00Z",
            "status": "pending",
            "merge_type": "branch"
        }
    ]
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" feature/queue-test 2>&1
    '
    # Should show the no-worktree message since it resolved from queue
    assert_output --partial "No worktree found. Attempting direct branch merge"
}

@test "v0-merge: error shows hint when queue entry exists but branch missing" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Initialize git repo (need a git repo for branch resolution to work)
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"

    # Create queue entry for a branch that doesn't exist
    mkdir -p "${project_dir}/.v0/build/mergeq"
    cat > "${project_dir}/.v0/build/mergeq/queue.json" <<EOF
{
    "version": 1,
    "entries": [
        {
            "operation": "feature/phantom",
            "worktree": "",
            "priority": 0,
            "enqueued_at": "2026-01-01T00:00:00Z",
            "status": "pending",
            "merge_type": "branch"
        }
    ]
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" feature/phantom 2>&1
    '
    assert_failure
    assert_output --partial "No operation found"
    assert_output --partial "in the merge queue"
    assert_output --partial "git fetch"
}

@test "v0-merge: direct branch resolution works without queue entry" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Initialize git repo
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"

    # Create feature branch
    git checkout -b feature/direct-branch --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git checkout main --quiet 2>/dev/null || git checkout master --quiet

    # No queue entry, no state file - just a branch
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" feature/direct-branch 2>&1
    '
    # Should show the no-worktree message since it resolved directly from branch
    assert_output --partial "No worktree found. Attempting direct branch merge"
}
