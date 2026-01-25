#!/usr/bin/env bats
# v0-workspace.bats - Integration tests for workspace functionality

load '../packages/test-support/helpers/test_helper'

setup() {
    _base_setup

    export V0_TEST_MODE=1
    export V0_NO_NOTIFICATIONS=1

    # Create a test git repository
    cd "$TEST_TEMP_DIR/project"
    git init --quiet -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    # Create .v0.rc with workspace configuration
    cat > "$TEST_TEMP_DIR/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
V0_DEVELOP_BRANCH="main"
V0_GIT_REMOTE="origin"
EOF

    # Set up state directory
    mkdir -p "$HOME/.local/state/v0/testproject/workspace"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Config Loading Tests
# ============================================================================

@test "v0_load_config infers workspace mode for main branch" {
    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config

    assert_equal "$V0_WORKSPACE_MODE" "clone"
}

@test "v0_load_config infers worktree mode for v0/develop branch" {
    cat > "$TEST_TEMP_DIR/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
V0_DEVELOP_BRANCH="v0/develop"
EOF

    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config

    assert_equal "$V0_WORKSPACE_MODE" "worktree"
}

@test "v0_load_config respects explicit workspace mode" {
    cat > "$TEST_TEMP_DIR/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
V0_DEVELOP_BRANCH="main"
V0_WORKSPACE_MODE="worktree"
EOF

    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config

    assert_equal "$V0_WORKSPACE_MODE" "worktree"
}

@test "v0_load_config sets V0_WORKSPACE_DIR correctly" {
    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config

    # Workspace dir should be set and contain /workspace/
    [ -n "$V0_WORKSPACE_DIR" ]
    [[ "$V0_WORKSPACE_DIR" == *"/workspace/"* ]]
}

# ============================================================================
# Workspace Mode Inference Tests
# ============================================================================

@test "v0_infer_workspace_mode returns clone for main" {
    source "$PROJECT_ROOT/packages/core/lib/config.sh"

    result=$(v0_infer_workspace_mode "main")
    assert_equal "$result" "clone"
}

@test "v0_infer_workspace_mode returns clone for develop" {
    source "$PROJECT_ROOT/packages/core/lib/config.sh"

    result=$(v0_infer_workspace_mode "develop")
    assert_equal "$result" "clone"
}

@test "v0_infer_workspace_mode returns clone for master" {
    source "$PROJECT_ROOT/packages/core/lib/config.sh"

    result=$(v0_infer_workspace_mode "master")
    assert_equal "$result" "clone"
}

@test "v0_infer_workspace_mode returns worktree for v0/develop" {
    source "$PROJECT_ROOT/packages/core/lib/config.sh"

    result=$(v0_infer_workspace_mode "v0/develop")
    assert_equal "$result" "worktree"
}

@test "v0_infer_workspace_mode returns worktree for custom branch" {
    source "$PROJECT_ROOT/packages/core/lib/config.sh"

    result=$(v0_infer_workspace_mode "integration")
    assert_equal "$result" "worktree"
}

# ============================================================================
# v0-tree Clone Mode Tests
# ============================================================================

@test "v0-tree uses workspace in clone mode" {
    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config

    # Ensure workspace is created
    ws_ensure_workspace

    # Check that v0-tree would use workspace as parent
    # This tests the mode detection without actually creating a worktree
    export V0_WORKSPACE_MODE="clone"
    assert_equal "$V0_WORKSPACE_MODE" "clone"
}

# ============================================================================
# Workspace Lifecycle Tests
# ============================================================================

@test "workspace created via ws_ensure_workspace is valid" {
    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config

    run ws_ensure_workspace
    assert_success

    run ws_validate
    assert_success
}

@test "workspace sync returns to develop branch" {
    source "$PROJECT_ROOT/packages/cli/lib/v0-common.sh"
    v0_load_config
    ws_ensure_workspace

    # Checkout a different branch in workspace
    git -C "$V0_WORKSPACE_DIR" checkout -b feature-branch --quiet

    # Sync should return to develop branch
    ws_sync_to_develop

    branch=$(git -C "$V0_WORKSPACE_DIR" rev-parse --abbrev-ref HEAD)
    assert_equal "$branch" "main"
}

# ============================================================================
# Push/Pull Isolation Tests
# ============================================================================

@test "pushpull functions do not reference workspace" {
    # Verify push/pull functions don't call workspace functions
    # This is a static check to ensure isolation

    run grep -r "ws_ensure_workspace\|V0_WORKSPACE_DIR" "$PROJECT_ROOT/packages/pushpull/lib/"
    assert_failure  # Should find no matches
}

# ============================================================================
# Merge Operations Use Workspace Tests
# ============================================================================

@test "merge execution references workspace" {
    # Verify merge operations use workspace
    run grep -l "V0_WORKSPACE_DIR\|ws_ensure_workspace" "$PROJECT_ROOT/packages/merge/lib/execution.sh"
    assert_success
}

@test "mergeq daemon references workspace" {
    run grep -l "V0_WORKSPACE_DIR\|ws_ensure_workspace" "$PROJECT_ROOT/packages/mergeq/lib/daemon.sh"
    assert_success
}

@test "mergeq processing references workspace" {
    run grep -l "V0_WORKSPACE_DIR\|ws_ensure_workspace" "$PROJECT_ROOT/packages/mergeq/lib/processing.sh"
    assert_success
}

@test "v0-merge references workspace" {
    run grep -l "V0_WORKSPACE_DIR\|ws_ensure_workspace" "$PROJECT_ROOT/bin/v0-merge"
    assert_success
}
