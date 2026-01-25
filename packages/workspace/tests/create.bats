#!/usr/bin/env bats
# create.bats - Tests for workspace creation functions

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
}

# ============================================================================
# Path Helper Tests
# ============================================================================

@test "ws_get_workspace_dir returns configured workspace dir" {
    result=$(ws_get_workspace_dir)
    assert_equal "$result" "$V0_WORKSPACE_DIR"
}

@test "ws_get_workspace_parent returns parent of workspace" {
    result=$(ws_get_workspace_parent)
    assert_equal "$result" "$V0_STATE_DIR/workspace"
}

@test "ws_workspace_exists returns false when workspace doesn't exist" {
    run ws_workspace_exists
    assert_failure
}

@test "ws_workspace_exists returns true when workspace exists" {
    mkdir -p "$V0_WORKSPACE_DIR"
    run ws_workspace_exists
    assert_success
}

# ============================================================================
# Clone Mode Tests
# ============================================================================

@test "ws_create_clone creates workspace via git clone" {
    run ws_create_clone
    assert_success
    assert_dir_exists "$V0_WORKSPACE_DIR"
    # For clones, .git is a directory (not a file like in worktrees)
    run test -e "$V0_WORKSPACE_DIR/.git"
    assert_success
}

@test "ws_create_clone workspace is on correct branch" {
    ws_create_clone
    local branch
    branch=$(git -C "$V0_WORKSPACE_DIR" rev-parse --abbrev-ref HEAD)
    assert_equal "$branch" "main"
}

@test "ws_ensure_workspace creates clone in clone mode" {
    run ws_ensure_workspace
    assert_success
    assert_dir_exists "$V0_WORKSPACE_DIR"
}

@test "ws_ensure_workspace is idempotent" {
    ws_ensure_workspace
    run ws_ensure_workspace
    assert_success
    assert_dir_exists "$V0_WORKSPACE_DIR"
}

# ============================================================================
# Worktree Mode Tests
# ============================================================================

@test "ws_create_worktree creates workspace via git worktree" {
    export V0_WORKSPACE_MODE="worktree"

    # First checkout a different branch so we can create worktree for main
    git -C "$TEST_TEMP_DIR/project" checkout -b temp-branch --quiet

    run ws_create_worktree
    assert_success
    assert_dir_exists "$V0_WORKSPACE_DIR"
}

@test "ws_check_branch_conflict fails when develop branch is checked out" {
    export V0_WORKSPACE_MODE="worktree"
    # main is already checked out
    run ws_check_branch_conflict
    assert_failure
    assert_output --partial "Cannot create worktree"
}

@test "ws_check_branch_conflict passes when different branch is checked out" {
    export V0_WORKSPACE_MODE="worktree"
    git -C "$TEST_TEMP_DIR/project" checkout -b feature-branch --quiet

    run ws_check_branch_conflict
    assert_success
}

# ============================================================================
# Workspace Removal Tests
# ============================================================================

@test "ws_remove_workspace removes clone workspace" {
    ws_ensure_workspace
    assert_dir_exists "$V0_WORKSPACE_DIR"

    ws_remove_workspace
    run test -d "$V0_WORKSPACE_DIR"
    assert_failure
}

@test "ws_remove_workspace is idempotent" {
    run ws_remove_workspace
    assert_success
}

# ============================================================================
# Invalid Workspace Handling
# ============================================================================

@test "ws_ensure_workspace removes and recreates invalid workspace" {
    # Create a directory that's not a valid git repo
    mkdir -p "$V0_WORKSPACE_DIR"
    echo "invalid" > "$V0_WORKSPACE_DIR/file.txt"

    run ws_ensure_workspace
    assert_success
    assert_dir_exists "$V0_WORKSPACE_DIR/.git"
}

@test "ws_is_valid_workspace returns false for non-git directory" {
    mkdir -p "$V0_WORKSPACE_DIR"
    run ws_is_valid_workspace
    assert_failure
}

@test "ws_is_valid_workspace returns true for valid git directory" {
    ws_ensure_workspace
    run ws_is_valid_workspace
    assert_success
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "ws_ensure_workspace fails on invalid mode" {
    export V0_WORKSPACE_MODE="invalid"
    run ws_ensure_workspace
    assert_failure
    assert_output --partial "Invalid V0_WORKSPACE_MODE"
}
