#!/usr/bin/env bats
# validate.bats - Tests for workspace validation functions

load '../../test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env

    # Set up workspace-specific variables
    export V0_WORKSPACE_MODE="clone"
    export V0_WORKSPACE_DIR="$V0_STATE_DIR/workspace/testrepo"
    export REPO_NAME="testrepo"
    export V0_GIT_REMOTE="origin"
    export V0_DEVELOP_BRANCH="main"

    # Initialize a real git repo
    cd "$TEST_TEMP_DIR/project"
    git init --quiet -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    # Source workspace library
    source "$PROJECT_ROOT/packages/workspace/lib/workspace.sh"

    # Create workspace for validation tests
    ws_ensure_workspace
}

# ============================================================================
# Validation Tests
# ============================================================================

@test "ws_validate succeeds for valid workspace" {
    run ws_validate
    assert_success
}

@test "ws_validate fails when workspace doesn't exist" {
    rm -rf "$V0_WORKSPACE_DIR"
    run ws_validate
    assert_failure
    assert_output --partial "does not exist"
}

@test "ws_validate fails for non-git directory" {
    rm -rf "$V0_WORKSPACE_DIR"
    mkdir -p "$V0_WORKSPACE_DIR"

    run ws_validate
    assert_failure
    assert_output --partial "not a valid git directory"
}

# ============================================================================
# Branch Detection Tests
# ============================================================================

@test "ws_is_on_develop returns true when on develop branch" {
    run ws_is_on_develop
    assert_success
}

@test "ws_is_on_develop returns false when on different branch" {
    git -C "$V0_WORKSPACE_DIR" checkout -b feature-branch --quiet

    run ws_is_on_develop
    assert_failure
}

@test "ws_get_current_branch returns current branch name" {
    result=$(ws_get_current_branch)
    assert_equal "$result" "main"
}

@test "ws_get_current_branch returns different branch after checkout" {
    git -C "$V0_WORKSPACE_DIR" checkout -b feature-branch --quiet

    result=$(ws_get_current_branch)
    assert_equal "$result" "feature-branch"
}

# ============================================================================
# Sync Tests
# ============================================================================

@test "ws_sync_to_develop returns to develop branch" {
    git -C "$V0_WORKSPACE_DIR" checkout -b feature-branch --quiet

    run ws_sync_to_develop
    assert_success

    branch=$(ws_get_current_branch)
    assert_equal "$branch" "main"
}

@test "ws_sync_to_develop handles rebase-merge directory gracefully" {
    # Get the actual git dir (may differ for worktrees)
    local git_dir
    git_dir=$(git -C "$V0_WORKSPACE_DIR" rev-parse --git-dir)
    if [[ "$git_dir" != /* ]]; then
        git_dir="$V0_WORKSPACE_DIR/$git_dir"
    fi

    # Simulate rebase-merge directory (just presence, not real rebase state)
    mkdir -p "$git_dir/rebase-merge"

    # ws_sync_to_develop should succeed even with stale rebase-merge dir
    # (git rebase --abort is called but may not clean up fake rebase state)
    run ws_sync_to_develop
    assert_success

    # Workspace should still be on develop branch
    branch=$(ws_get_current_branch)
    assert_equal "$branch" "main"
}

@test "ws_sync_to_develop aborts incomplete merge" {
    # Get the actual git dir
    local git_dir
    git_dir=$(git -C "$V0_WORKSPACE_DIR" rev-parse --git-dir)
    if [[ "$git_dir" != /* ]]; then
        git_dir="$V0_WORKSPACE_DIR/$git_dir"
    fi

    # Simulate MERGE_HEAD file
    touch "$git_dir/MERGE_HEAD"

    run ws_sync_to_develop
    assert_success

    # MERGE_HEAD should be cleaned up
    [ ! -f "$git_dir/MERGE_HEAD" ]
}

# ============================================================================
# Uncommitted Changes Tests
# ============================================================================

@test "ws_has_uncommitted_changes returns false for clean workspace" {
    run ws_has_uncommitted_changes
    assert_failure  # returns 1 (false) when no changes
}

@test "ws_has_uncommitted_changes returns true for modified file" {
    echo "modified" >> "$V0_WORKSPACE_DIR/README.md"

    run ws_has_uncommitted_changes
    assert_success  # returns 0 (true) when has changes
}

@test "ws_has_uncommitted_changes ignores untracked files" {
    echo "untracked" > "$V0_WORKSPACE_DIR/untracked.txt"

    run ws_has_uncommitted_changes
    assert_failure  # untracked files don't count
}

# ============================================================================
# Conflict Detection Tests
# ============================================================================

@test "ws_has_conflicts returns false for clean workspace" {
    run ws_has_conflicts
    assert_failure
}

# Note: Testing actual conflicts requires a more complex git setup
# which is covered in integration tests

# ============================================================================
# Clean Workspace Tests
# ============================================================================

@test "ws_clean_workspace removes uncommitted changes" {
    echo "modified" >> "$V0_WORKSPACE_DIR/README.md"

    ws_clean_workspace

    run ws_has_uncommitted_changes
    assert_failure
}

@test "ws_clean_workspace removes untracked files" {
    echo "untracked" > "$V0_WORKSPACE_DIR/untracked.txt"

    ws_clean_workspace

    run test -f "$V0_WORKSPACE_DIR/untracked.txt"
    assert_failure
}
