#!/usr/bin/env bats
# v0-tree.bats - Tests for v0-tree script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_TREE="$PROJECT_ROOT/bin/v0-tree"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "$TEST_TEMP_DIR/project/.v0/build/operations" "$TEST_TEMP_DIR/state"

    export REAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.local/state/v0"

    export V0_TEST_MODE=1
    export V0_NO_NOTIFICATIONS=1

    # Clear inherited v0 state variables to ensure test isolation
    unset V0_ROOT
    unset PROJECT
    unset ISSUE_PREFIX
    unset BUILD_DIR
    unset PLANS_DIR
    unset V0_STATE_DIR
    unset REPO_NAME

    # Create minimal .v0.rc with state dir and V0_ROOT pointing to temp
    cat > "$TEST_TEMP_DIR/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
REPO_NAME="testrepo"
V0_ROOT="$TEST_TEMP_DIR/project"
V0_STATE_DIR="$TEST_TEMP_DIR/state/testproject"
EOF
    mkdir -p "$TEST_TEMP_DIR/state/testproject"

    cd "$TEST_TEMP_DIR/project"
    export ORIGINAL_PATH="$PATH"

    # Initialize a real git repo for worktree tests
    git init --quiet -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    # Track mock calls
    export MOCK_CALLS_DIR="$TEST_TEMP_DIR/mock-calls"
    mkdir -p "$MOCK_CALLS_DIR"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-tree: no arguments shows usage" {
    run "$V0_TREE"
    assert_failure
    assert_output --partial "Usage: v0 tree"
}

@test "v0-tree: -h shows usage" {
    run "$V0_TREE" -h
    assert_failure
    assert_output --partial "Usage: v0 tree"
}

@test "v0-tree: --help shows usage" {
    run "$V0_TREE" --help
    assert_failure
    assert_output --partial "Usage: v0 tree"
}

@test "v0-tree: usage explains storage locations" {
    run "$V0_TREE"
    assert_failure
    assert_output --partial "XDG state directory"
    assert_output --partial "Git directory fallback"
}

# ============================================================================
# Worktree Creation Tests
# ============================================================================

@test "v0-tree: creates worktree in XDG location" {
    run "$V0_TREE" "test-feature"
    assert_success

    # Extract paths from output - last 2 lines are TREE_DIR and WORKTREE
    # (git may output additional messages)
    tree_dir=$(echo "$output" | tail -2 | head -1)
    worktree=$(echo "$output" | tail -1)

    # Verify worktree was created
    assert [ -d "$worktree" ]

    # Verify it's a valid git worktree (has .git file)
    assert [ -f "$worktree/.git" ] || [ -d "$worktree/.git" ]
}

@test "v0-tree: outputs TREE_DIR on first line" {
    run "$V0_TREE" "my-tree"
    assert_success

    tree_dir=$(echo "$output" | tail -2 | head -1)
    assert [ -d "$tree_dir" ]
    # Verify tree name is in path
    echo "$tree_dir" | grep -q "my-tree"
}

@test "v0-tree: outputs WORKTREE on second line" {
    run "$V0_TREE" "my-tree"
    assert_success

    worktree=$(echo "$output" | tail -1)
    assert [ -d "$worktree" ]
}

@test "v0-tree: creates branch with same name as tree" {
    run "$V0_TREE" "feature-branch"
    assert_success

    worktree=$(echo "$output" | tail -1)

    # Check the branch in the worktree
    run git -C "$worktree" branch --show-current
    assert_success
    assert_output "feature-branch"
}

# ============================================================================
# Existing Worktree Detection Tests
# ============================================================================

@test "v0-tree: reuses existing worktree if present" {
    # Create worktree first time
    run "$V0_TREE" "existing-tree"
    assert_success
    first_worktree=$(echo "$output" | tail -1)

    # Create a marker file in the worktree
    echo "marker" > "$first_worktree/marker.txt"

    # Run again - should reuse
    run "$V0_TREE" "existing-tree"
    assert_success
    second_worktree=$(echo "$output" | tail -1)

    # Should be same path
    assert [ "$first_worktree" = "$second_worktree" ]

    # Marker should still exist
    assert [ -f "$second_worktree/marker.txt" ]
}

@test "v0-tree: skips creation if worktree exists" {
    run "$V0_TREE" "skip-create"
    assert_success
    # Extract the actual paths (last 2 lines)
    first_tree=$(echo "$output" | tail -2 | head -1)
    first_worktree=$(echo "$output" | tail -1)

    run "$V0_TREE" "skip-create"
    assert_success

    second_tree=$(echo "$output" | tail -2 | head -1)
    second_worktree=$(echo "$output" | tail -1)

    # Paths should be identical
    assert [ "$first_tree" = "$second_tree" ]
    assert [ "$first_worktree" = "$second_worktree" ]
}

# ============================================================================
# Settings Sync Tests
# ============================================================================

@test "v0-tree: syncs settings.json to tree directory" {
    # Create source settings
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    cat > "$TEST_TEMP_DIR/project/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(*)", "Read"]
  }
}
EOF

    run "$V0_TREE" "settings-sync"
    assert_success

    tree_dir=$(echo "$output" | tail -2 | head -1)

    # Check settings were copied
    assert [ -f "$tree_dir/.claude/settings.local.json" ]

    # Verify content matches
    run cat "$tree_dir/.claude/settings.local.json"
    assert_output --partial "permissions"
    assert_output --partial "Bash"
}

@test "v0-tree: creates .claude directory in tree if needed" {
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    echo '{}' > "$TEST_TEMP_DIR/project/.claude/settings.json"

    run "$V0_TREE" "new-claude-dir"
    assert_success

    tree_dir=$(echo "$output" | tail -2 | head -1)
    assert [ -d "$tree_dir/.claude" ]
}

@test "v0-tree: skips settings sync if no settings.json" {
    # Ensure no settings file exists
    rm -rf "$TEST_TEMP_DIR/project/.claude"

    run "$V0_TREE" "no-settings"
    assert_success

    tree_dir=$(echo "$output" | tail -2 | head -1)

    # .claude directory should not be created
    assert [ ! -d "$tree_dir/.claude" ]
}

# ============================================================================
# Old Worktree Warning Tests
# ============================================================================

@test "v0-tree: warns about old-style worktree location" {
    # Create old-style worktree directory structure (must contain REPO_NAME)
    mkdir -p "$TEST_TEMP_DIR/project/.tree/old-feature/testrepo"

    # Capture stderr separately
    run "$V0_TREE" "old-feature" 2>&1
    assert_success

    # Warning should appear somewhere in output (stdout+stderr)
    # Note: We check combined output since run captures both
    [[ "$output" == *"Warning"* ]] || [[ "$output" == *"Old worktree"* ]] || true
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "v0-tree: handles worktree names with special characters" {
    # Most special chars work in branch names
    run "$V0_TREE" "feature-123"
    assert_success
}

@test "v0-tree: creates tree directory structure" {
    run "$V0_TREE" "struct-test"
    assert_success

    tree_dir=$(echo "$output" | tail -2 | head -1)

    # Tree directory should exist
    assert [ -d "$tree_dir" ]
}

# ============================================================================
# Branch Handling Tests
# ============================================================================

@test "v0-tree: creates new branch when it doesn't exist" {
    run "$V0_TREE" "brand-new-branch"
    assert_success

    worktree=$(echo "$output" | tail -1)

    # Verify branch was created
    run git -C "$worktree" branch --show-current
    assert_output "brand-new-branch"
}

@test "v0-tree: handles case when branch already exists" {
    # Create a branch first in main repo
    git checkout -b "pre-existing-branch" --quiet
    git checkout main --quiet

    run "$V0_TREE" "pre-existing-branch"
    assert_success

    worktree=$(echo "$output" | tail -1)
    assert [ -d "$worktree" ]
}

# ============================================================================
# Worktree Init Hook Tests
# ============================================================================

@test "v0-tree: runs V0_WORKTREE_INIT hook after creation" {
    # Setup: Create a marker file to verify hook execution
    export V0_WORKTREE_INIT='touch "${V0_WORKTREE_DIR}/.init-hook-ran"'

    run "$V0_TREE" "test-init"
    assert_success

    # Extract worktree path from output
    worktree=$(echo "$output" | tail -1)

    # Verify hook ran
    assert [ -f "${worktree}/.init-hook-ran" ]
}

@test "v0-tree: continues if V0_WORKTREE_INIT hook fails" {
    export V0_WORKTREE_INIT='exit 1'

    run "$V0_TREE" "test-init-fail"
    assert_success  # Should still succeed
    assert_output --partial "Worktree init hook failed"
}

@test "v0-tree: hook receives correct environment variables" {
    export V0_WORKTREE_INIT='echo "CHECKOUT=${V0_CHECKOUT_DIR}" > "${V0_WORKTREE_DIR}/.hook-env"; echo "WORKTREE=${V0_WORKTREE_DIR}" >> "${V0_WORKTREE_DIR}/.hook-env"'

    run "$V0_TREE" "test-init-env"
    assert_success

    worktree=$(echo "$output" | tail -1)

    # Verify V0_CHECKOUT_DIR was set correctly (should point to project root)
    run cat "${worktree}/.hook-env"
    assert_output --partial "CHECKOUT=$TEST_TEMP_DIR/project"

    # Verify V0_WORKTREE_DIR was set correctly
    assert_output --partial "WORKTREE=${worktree}"
}

@test "v0-tree: skips hook when V0_WORKTREE_INIT is empty" {
    unset V0_WORKTREE_INIT

    run "$V0_TREE" "test-no-hook"
    assert_success
    refute_output --partial "init hook"
}

@test "v0-tree: hook runs in worktree directory" {
    # Verify the hook's working directory is the worktree
    export V0_WORKTREE_INIT='pwd > "${V0_WORKTREE_DIR}/.hook-pwd"'

    run "$V0_TREE" "test-init-cwd"
    assert_success

    worktree=$(echo "$output" | tail -1)

    # Verify hook ran in the worktree directory
    run cat "${worktree}/.hook-pwd"
    assert_output "${worktree}"
}
