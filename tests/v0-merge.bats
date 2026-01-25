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

# ============================================================================
# Verification Failed Cleanup Tests
# ============================================================================

@test "v0-merge: verification_failed with merge_commit on main cleans up" {
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

    # Get the default branch name (main or master depending on git version)
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Update .v0.rc to use the correct develop branch
    echo "V0_DEVELOP_BRANCH=\"${default_branch}\"" >> "${project_dir}/.v0.rc"

    # Create feature branch and merge it to main
    git checkout -b feature/already-merged --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    local merge_commit
    merge_commit=$(git rev-parse HEAD)
    git checkout "${default_branch}" --quiet
    git merge --ff-only feature/already-merged --quiet

    # Delete the feature branch (simulating post-merge cleanup)
    git branch -d feature/already-merged

    # Create operation state with verification_failed status but merge_commit on main
    mkdir -p "${project_dir}/.v0/build/operations/test-op"
    cat > "${project_dir}/.v0/build/operations/test-op/state.json" <<EOF
{
    "name": "test-op",
    "phase": "completed",
    "worktree": "/nonexistent/path",
    "branch": "feature/already-merged",
    "merge_status": "verification_failed",
    "merge_commit": "${merge_commit}"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR -u MERGEQ_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" test-op 2>&1
    '
    # Should output cleanup message instead of error
    assert_output --partial "already merged"
    assert_output --partial "Cleanup complete"
    refute_output --partial "Error:"
}

@test "v0-merge: verification_failed without merge_commit on main shows error" {
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

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Update .v0.rc to use the correct develop branch
    echo "V0_DEVELOP_BRANCH=\"${default_branch}\"" >> "${project_dir}/.v0.rc"

    # Create a commit hash that is NOT on main
    local fake_commit="0000000000000000000000000000000000000000"

    # Create operation state with verification_failed status and non-existent merge_commit
    mkdir -p "${project_dir}/.v0/build/operations/test-op"
    cat > "${project_dir}/.v0/build/operations/test-op/state.json" <<EOF
{
    "name": "test-op",
    "phase": "completed",
    "worktree": "/nonexistent/path",
    "branch": "feature/not-merged",
    "merge_status": "verification_failed",
    "merge_commit": "${fake_commit}"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR -u MERGEQ_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" test-op 2>&1
    '
    # Should show the original error
    assert_failure
    assert_output --partial "Error:"
    assert_output --partial "previously failed to merge"
}

@test "v0-merge: verification_failed with remote branch already merged cleans up" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a bare "remote" repo
    local remote_dir="${TEST_TEMP_DIR}/remote.git"
    git init --bare --quiet "${remote_dir}"

    # Initialize git repo
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    git remote add origin "${remote_dir}"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"
    git push --quiet -u origin HEAD

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Update .v0.rc to use the correct develop branch
    echo "V0_DEVELOP_BRANCH=\"${default_branch}\"" >> "${project_dir}/.v0.rc"

    # Create feature branch, push to remote, then merge to main
    git checkout -b feature/remote-merged --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git push --quiet -u origin feature/remote-merged
    git checkout "${default_branch}" --quiet
    git merge --ff-only feature/remote-merged --quiet
    git push --quiet origin "${default_branch}"

    # Delete local feature branch (simulating worktree cleanup)
    git branch -d feature/remote-merged

    # Delete local remote-tracking ref (simulating stale refs)
    git update-ref -d refs/remotes/origin/feature/remote-merged

    # Create operation state with verification_failed status
    # Remote branch still exists but local refs are stale
    mkdir -p "${project_dir}/.v0/build/operations/test-op"
    cat > "${project_dir}/.v0/build/operations/test-op/state.json" <<EOF
{
    "name": "test-op",
    "phase": "completed",
    "worktree": "/nonexistent/path",
    "branch": "feature/remote-merged",
    "merge_status": "verification_failed",
    "merge_commit": "0000000000000000000000000000000000000000"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR -u MERGEQ_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" test-op 2>&1
    '
    # Should output cleanup message instead of error
    assert_output --partial "already merged"
    assert_output --partial "Cleanup complete"
    refute_output --partial "Error:"
}

@test "v0-merge: verification_failed with remote branch not merged allows merge" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a bare "remote" repo
    local remote_dir="${TEST_TEMP_DIR}/remote.git"
    git init --bare --quiet "${remote_dir}"

    # Initialize git repo
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    git remote add origin "${remote_dir}"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"
    git push --quiet -u origin HEAD

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Update .v0.rc to use the correct develop branch
    echo "V0_DEVELOP_BRANCH=\"${default_branch}\"" >> "${project_dir}/.v0.rc"

    # Create feature branch and push to remote, but don't merge
    git checkout -b feature/remote-not-merged --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git push --quiet -u origin feature/remote-not-merged
    git checkout "${default_branch}" --quiet

    # Delete local feature branch (simulating worktree cleanup)
    git branch -D feature/remote-not-merged

    # Delete local remote-tracking ref (simulating stale refs)
    git update-ref -d refs/remotes/origin/feature/remote-not-merged

    # Create operation state with verification_failed status
    # Remote branch exists but local refs are stale
    mkdir -p "${project_dir}/.v0/build/operations/test-op"
    cat > "${project_dir}/.v0/build/operations/test-op/state.json" <<EOF
{
    "name": "test-op",
    "phase": "completed",
    "worktree": "/nonexistent/path",
    "branch": "feature/remote-not-merged",
    "merge_status": "verification_failed",
    "merge_commit": "0000000000000000000000000000000000000000"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR -u MERGEQ_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" test-op 2>&1
    '
    # Should find remote branch and attempt merge (success since ff is possible)
    assert_success
    assert_output --partial "Found remote branch"
    assert_output --partial "attempting merge"
    refute_output --partial "previously failed to merge"
}

@test "v0-merge: verification_failed extracts branch from worktree path when no branch field" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a bare "remote" repo
    local remote_dir="${TEST_TEMP_DIR}/remote.git"
    git init --bare --quiet "${remote_dir}"

    # Initialize git repo
    cd "${project_dir}"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    git remote add origin "${remote_dir}"
    echo "initial" > file.txt
    git add file.txt
    git commit --quiet -m "Initial commit"
    git push --quiet -u origin HEAD

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Update .v0.rc to use the correct develop branch
    echo "V0_DEVELOP_BRANCH=\"${default_branch}\"" >> "${project_dir}/.v0.rc"

    # Create feature branch and push to remote, but don't merge
    git checkout -b feature/extract-test --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git push --quiet -u origin feature/extract-test
    git checkout "${default_branch}" --quiet

    # Delete local feature branch (simulating worktree cleanup)
    git branch -D feature/extract-test

    # Delete local remote-tracking ref (simulating stale refs)
    git update-ref -d refs/remotes/origin/feature/extract-test

    # Create operation state with verification_failed but NO branch field
    # The worktree path contains the branch info: .../tree/feature/extract-test/v0
    mkdir -p "${project_dir}/.v0/build/operations/extract-test"
    cat > "${project_dir}/.v0/build/operations/extract-test/state.json" <<EOF
{
    "name": "extract-test",
    "phase": "completed",
    "worktree": "${TEST_TEMP_DIR}/tree/feature/extract-test/v0",
    "merge_status": "verification_failed",
    "merge_commit": "0000000000000000000000000000000000000000"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR -u MERGEQ_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" extract-test 2>&1
    '
    # Should extract branch from worktree path and find remote branch
    assert_success
    assert_output --partial "Found remote branch"
    assert_output --partial "feature/extract-test"
    assert_output --partial "attempting merge"
    refute_output --partial "previously failed to merge"
}

# ============================================================================
# Non-Fast-Forward Merge Tests
# ============================================================================

@test "v0-merge: non-ff merge without worktree suggests --resolve" {
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

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Update .v0.rc to use the correct develop branch
    echo "V0_DEVELOP_BRANCH=\"${default_branch}\"" >> "${project_dir}/.v0.rc"

    # Create feature branch
    git checkout -b feature/diverged --quiet
    echo "feature" > feature.txt
    git add feature.txt
    git commit --quiet -m "Feature commit"
    git checkout "${default_branch}" --quiet

    # Add a commit to main to make branches diverge (ff not possible)
    echo "main change" > main.txt
    git add main.txt
    git commit --quiet -m "Main commit"

    # No worktree, no state file - just the branch
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_MERGE}"'" feature/diverged 2>&1
    '
    # Should fail and suggest using --resolve
    assert_failure
    assert_output --partial "No worktree found. Attempting direct branch merge"
    assert_output --partial "Cannot fast-forward merge"
    assert_output --partial "--resolve"
}
