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

# ============================================================================
# Worktree Detection Tests
# ============================================================================

@test "ws_is_worktree returns false for clone" {
    ws_ensure_workspace
    run ws_is_worktree
    assert_failure
}

@test "ws_is_worktree returns true for worktree" {
    export V0_WORKSPACE_MODE="worktree"
    git -C "$TEST_TEMP_DIR/project" checkout -b temp-branch --quiet
    ws_ensure_workspace

    run ws_is_worktree
    assert_success
}

# ============================================================================
# Config Match Tests
# ============================================================================

@test "ws_matches_config returns true when config matches" {
    ws_ensure_workspace
    run ws_matches_config
    assert_success
}

@test "ws_matches_config fails when mode mismatches (clone exists, worktree expected)" {
    # Create clone workspace
    ws_ensure_workspace

    # Change mode to worktree
    export V0_WORKSPACE_MODE="worktree"

    run ws_matches_config
    assert_failure
    assert_output --partial "clone but config expects worktree"
}

@test "ws_matches_config fails when branch mismatches" {
    ws_ensure_workspace

    # Change expected branch
    export V0_DEVELOP_BRANCH="v0/develop"

    run ws_matches_config
    assert_failure
    assert_output --partial "but config expects 'v0/develop'"
}

# ============================================================================
# Auto-Recreate on Config Change Tests
# ============================================================================

@test "ws_ensure_workspace recreates when mode changes from clone to worktree" {
    # Create clone workspace first
    ws_ensure_workspace
    assert_dir_exists "$V0_WORKSPACE_DIR"
    # Verify it's a clone (.git is directory)
    run test -d "$V0_WORKSPACE_DIR/.git"
    assert_success

    # Switch V0_ROOT to temp branch so worktree can use main
    git -C "$TEST_TEMP_DIR/project" checkout -b temp-branch --quiet

    # Change mode to worktree
    export V0_WORKSPACE_MODE="worktree"

    # Should auto-recreate
    run ws_ensure_workspace
    assert_success
    assert_output --partial "Recreating workspace"

    # Verify it's now a worktree (.git is file)
    run test -f "$V0_WORKSPACE_DIR/.git"
    assert_success
}

@test "ws_ensure_workspace recreates when branch changes" {
    ws_ensure_workspace
    local old_branch
    old_branch=$(git -C "$V0_WORKSPACE_DIR" rev-parse --abbrev-ref HEAD)
    assert_equal "$old_branch" "main"

    # Create and push new develop branch in V0_ROOT
    git -C "$TEST_TEMP_DIR/project" checkout -b v0/develop --quiet
    git -C "$TEST_TEMP_DIR/project" checkout main --quiet

    # Change expected branch
    export V0_DEVELOP_BRANCH="v0/develop"

    # Should auto-recreate
    run ws_ensure_workspace
    assert_success
    assert_output --partial "Recreating workspace"

    # Verify branch changed
    local new_branch
    new_branch=$(git -C "$V0_WORKSPACE_DIR" rev-parse --abbrev-ref HEAD)
    assert_equal "$new_branch" "v0/develop"
}

# ============================================================================
# Remote URL Matching Tests
# ============================================================================

@test "ws_remote_matches returns true for worktree (always synced)" {
    # Switch V0_ROOT to temp branch so worktree can use main
    git -C "$TEST_TEMP_DIR/project" checkout -b temp-branch --quiet

    export V0_WORKSPACE_MODE="worktree"
    ws_ensure_workspace

    run ws_remote_matches
    assert_success
}

@test "ws_remote_matches returns true when clone origin matches main repo remote" {
    # Add a remote to the main repo
    git -C "$TEST_TEMP_DIR/project" remote add origin "https://example.com/repo.git"

    ws_ensure_workspace

    run ws_remote_matches
    assert_success
}

@test "ws_remote_matches fails when clone origin differs from main repo remote" {
    # Add a remote to the main repo
    git -C "$TEST_TEMP_DIR/project" remote add origin "https://example.com/repo.git"

    ws_ensure_workspace

    # Change the workspace's origin to a different URL
    git -C "$V0_WORKSPACE_DIR" remote set-url origin "https://different.example.com/repo.git"

    run ws_remote_matches
    assert_failure
    assert_output --partial "differs from"
}

@test "ws_matches_config fails when remote URL mismatches" {
    # Add a remote to the main repo
    git -C "$TEST_TEMP_DIR/project" remote add origin "https://example.com/repo.git"

    ws_ensure_workspace

    # Change the workspace's origin to a different URL
    git -C "$V0_WORKSPACE_DIR" remote set-url origin "https://different.example.com/repo.git"

    run ws_matches_config
    assert_failure
    assert_output --partial "differs from"
}

@test "ws_ensure_workspace recreates when remote URL changes" {
    # Add a remote to the main repo
    git -C "$TEST_TEMP_DIR/project" remote add origin "https://example.com/repo.git"

    ws_ensure_workspace

    # Change the workspace's origin to a different URL (simulating stale workspace)
    git -C "$V0_WORKSPACE_DIR" remote set-url origin "https://stale.example.com/repo.git"

    # Should auto-recreate
    run ws_ensure_workspace
    assert_success
    assert_output --partial "Recreating workspace"

    # Verify origin now matches
    local workspace_url main_url
    workspace_url=$(git -C "$V0_WORKSPACE_DIR" remote get-url origin)
    main_url=$(git -C "$TEST_TEMP_DIR/project" remote get-url origin)
    assert_equal "$workspace_url" "$main_url"
}

# ============================================================================
# ws_init_wok_link Tests
# ============================================================================

@test "ws_init_wok_link skips when wk not available" {
    # Hide wk command
    wk() { return 127; }
    export -f wk

    # Should succeed (skip gracefully)
    run ws_init_wok_link "/some/path"
    assert_success
}

@test "ws_init_wok_link skips when no .wok in main repo" {
    # Mock wk to be available
    wk() { echo "mock wk"; return 0; }
    export -f wk

    # V0_ROOT has no .wok directory
    run ws_init_wok_link "$TEST_TEMP_DIR/project"
    assert_success
}

@test "ws_init_wok_link handles incomplete .wok directory from git checkout" {
    # This tests the bug where git checkout creates .wok/.gitignore but no config.toml,
    # which causes wk init to fail with "already initialized"
    local worktree="$TEST_TEMP_DIR/worktree"
    mkdir -p "$worktree/.wok"
    echo "config.toml" > "$worktree/.wok/.gitignore"
    # No config.toml - simulates incomplete initialization from git checkout

    # Create a valid .wok in "main repo"
    mkdir -p "$TEST_TEMP_DIR/project/.wok"
    echo 'prefix = "test"' > "$TEST_TEMP_DIR/project/.wok/config.toml"

    # Mock wk init to create config.toml (must recreate .wok since it gets removed)
    wk() {
        if [[ "$1" == "init" ]]; then
            local path_arg="" prev=""
            for arg in "$@"; do
                if [[ "$prev" == "--path" ]]; then
                    path_arg="$arg"
                fi
                prev="$arg"
            done
            if [[ -n "$path_arg" ]]; then
                mkdir -p "$path_arg/.wok"
                echo 'workspace = "/mock"' > "$path_arg/.wok/config.toml"
            fi
            return 0
        fi
        return 0
    }
    export -f wk

    # Should remove incomplete .wok and reinitialize
    run ws_init_wok_link "$worktree"
    assert_success

    # config.toml should now exist
    assert_file_exists "$worktree/.wok/config.toml"
}

@test "ws_init_wok_link skips when already properly initialized" {
    local worktree="$TEST_TEMP_DIR/worktree"
    mkdir -p "$worktree/.wok"
    echo 'workspace = "/some/path"' > "$worktree/.wok/config.toml"

    # Create a valid .wok in "main repo"
    mkdir -p "$TEST_TEMP_DIR/project/.wok"
    echo 'prefix = "test"' > "$TEST_TEMP_DIR/project/.wok/config.toml"

    # Track if wk was called
    WK_CALLED=false
    wk() {
        WK_CALLED=true
        return 0
    }
    export -f wk
    export WK_CALLED

    run ws_init_wok_link "$worktree"
    assert_success

    # wk should not have been called since config.toml already exists
    [[ "$WK_CALLED" == "false" ]]
}

@test "ws_create_clone initializes wok link when main repo has .wok" {
    # Create a .wok in main repo
    mkdir -p "$TEST_TEMP_DIR/project/.wok"
    echo 'prefix = "test"' > "$TEST_TEMP_DIR/project/.wok/config.toml"

    # Create a mock wk script that tracks calls
    local mock_wk_log="$TEST_TEMP_DIR/wk-calls.log"
    mkdir -p "$TEST_TEMP_DIR/mock-bin"
    cat > "$TEST_TEMP_DIR/mock-bin/wk" <<'MOCK_WK'
#!/bin/bash
echo "$@" >> "$WK_MOCK_LOG"
if [[ "$1" == "init" ]]; then
    # Find --path argument
    local prev=""
    for arg in "$@"; do
        if [[ "$prev" == "--path" ]]; then
            mkdir -p "$arg/.wok"
            echo 'workspace = "/mock"' > "$arg/.wok/config.toml"
        fi
        prev="$arg"
    done
fi
exit 0
MOCK_WK
    chmod +x "$TEST_TEMP_DIR/mock-bin/wk"
    export PATH="$TEST_TEMP_DIR/mock-bin:$PATH"
    export WK_MOCK_LOG="$mock_wk_log"

    run ws_create_clone
    assert_success

    # wk init should have been called with --path pointing to workspace
    assert_file_exists "$mock_wk_log"
    run cat "$mock_wk_log"
    assert_output --partial "init"
    assert_output --partial "--path"
    # Verify config.toml was created in workspace (by our mock)
    assert_file_exists "$V0_WORKSPACE_DIR/.wok/config.toml"
}

@test "ws_ensure_workspace repairs incomplete wok link on existing workspace" {
    # Create initial workspace (without wok)
    run ws_create_clone
    assert_success

    # Simulate incomplete .wok directory (e.g., from git checkout of older workspace)
    # This happens when .wok/.gitignore exists but config.toml doesn't
    rm -rf "$V0_WORKSPACE_DIR/.wok"
    mkdir -p "$V0_WORKSPACE_DIR/.wok"
    echo "# gitignore" > "$V0_WORKSPACE_DIR/.wok/.gitignore"

    # Set up main repo with .wok
    mkdir -p "$V0_ROOT/.wok"
    echo 'prefix = "test"' > "$V0_ROOT/.wok/config.toml"

    # Mock wk to track calls and create config.toml
    local mock_wk_log="$TEST_TEMP_DIR/wk-repair.log"
    mkdir -p "$TEST_TEMP_DIR/mock-bin"
    cat > "$TEST_TEMP_DIR/mock-bin/wk" <<'MOCK_WK'
#!/bin/bash
echo "$@" >> "$WK_MOCK_LOG"
# Extract --path argument and create config.toml there
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--path" ]]; then
        mkdir -p "$arg/.wok"
        echo 'prefix = "test"' > "$arg/.wok/config.toml"
        break
    fi
    prev="$arg"
done
exit 0
MOCK_WK
    chmod +x "$TEST_TEMP_DIR/mock-bin/wk"
    export PATH="$TEST_TEMP_DIR/mock-bin:$PATH"
    export WK_MOCK_LOG="$mock_wk_log"

    # Call ws_ensure_workspace on existing workspace - should repair wok link
    run ws_ensure_workspace
    assert_success

    # wk init should have been called to repair the incomplete .wok
    assert_file_exists "$mock_wk_log"
    run cat "$mock_wk_log"
    assert_output --partial "init"
    assert_output --partial "--workspace"
    # Verify config.toml was created (repaired)
    assert_file_exists "$V0_WORKSPACE_DIR/.wok/config.toml"
}
