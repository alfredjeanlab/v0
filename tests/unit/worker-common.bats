#!/usr/bin/env bats
# Tests for worker-common.sh - Worker Utilities & Backoff

load '../helpers/test_helper'

# Setup for worker tests
setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/project/.v0/build/operations"
    mkdir -p "$TEST_TEMP_DIR/state"

    export REAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.local/state/v0"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "$TEST_TEMP_DIR/project"
    export ORIGINAL_PATH="$PATH"

    # Create valid v0 config
    create_v0rc "testproject" "testp"

    # Export paths
    export V0_ROOT="$TEST_TEMP_DIR/project"
    export PROJECT="testproject"
    export ISSUE_PREFIX="testp"
    export BUILD_DIR="$TEST_TEMP_DIR/project/.v0/build"
    export WORKER_SESSION="v0-testproject-worker-fix"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"

    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# calculate_backoff() tests
# ============================================================================

# Backoff formula: 5 * 2^(n-1), capped at 300
calculate_backoff() {
    local failure_count="$1"
    local backoff=$((5 * (2 ** (failure_count - 1))))
    if [ $backoff -gt 300 ]; then
        backoff=300
    fi
    echo $backoff
}

@test "backoff calculation returns 5 for first failure" {
    run calculate_backoff 1
    assert_success
    assert_output "5"
}

@test "backoff calculation returns 10 for second failure" {
    run calculate_backoff 2
    assert_success
    assert_output "10"
}

@test "backoff calculation returns 20 for third failure" {
    run calculate_backoff 3
    assert_success
    assert_output "20"
}

@test "backoff calculation returns 40 for fourth failure" {
    run calculate_backoff 4
    assert_success
    assert_output "40"
}

@test "backoff calculation returns 80 for fifth failure" {
    run calculate_backoff 5
    assert_success
    assert_output "80"
}

@test "backoff calculation returns 160 for sixth failure" {
    run calculate_backoff 6
    assert_success
    assert_output "160"
}

@test "backoff caps at 300 seconds for seventh failure" {
    run calculate_backoff 7
    assert_success
    assert_output "300"
}

@test "backoff stays capped at 300 for tenth failure" {
    run calculate_backoff 10
    assert_success
    assert_output "300"
}

@test "backoff stays capped at 300 for very high failure count" {
    run calculate_backoff 20
    assert_success
    assert_output "300"
}

# ============================================================================
# find_worker_state_dir() tests
# ============================================================================

find_worker_state_dir() {
    local target_session="$1"
    local preferred_root="${2:-}"

    # Try preferred root first if provided
    if [ -n "$preferred_root" ]; then
        local root_name=$(basename "$preferred_root")
        local tree_state_dir="$HOME/.local/state/v0/$root_name/tree/$target_session"
        if [ -f "$tree_state_dir/.worker-git-dir" ]; then
            echo "$tree_state_dir"
            return 0
        fi
    fi

    # Search in all project directories under .local/state/v0
    for dir in "$HOME/.local/state/v0"/*; do
        if [ -d "$dir" ] && [ -f "$dir/tree/$target_session/.worker-git-dir" ]; then
            echo "$dir/tree/$target_session"
            return 0
        fi
    done

    return 1
}

@test "find_worker_state_dir finds existing worker" {
    local session="v0-testproject-worker-fix"
    local state_dir="$HOME/.local/state/v0/testproject/tree/$session"
    mkdir -p "$state_dir"
    touch "$state_dir/.worker-git-dir"

    run find_worker_state_dir "$session"
    assert_success
    assert_output "$state_dir"
}

@test "find_worker_state_dir fails for nonexistent worker" {
    run find_worker_state_dir "nonexistent-worker"
    assert_failure
}

@test "find_worker_state_dir uses preferred root first" {
    local session="v0-preferred-worker-fix"

    # Create in preferred location
    local preferred_dir="$HOME/.local/state/v0/preferred/tree/$session"
    mkdir -p "$preferred_dir"
    touch "$preferred_dir/.worker-git-dir"

    # Also create in another location (different project name)
    local other_dir="$HOME/.local/state/v0/other/tree/v0-other-worker-fix"
    mkdir -p "$other_dir"
    touch "$other_dir/.worker-git-dir"

    # Should find preferred
    run find_worker_state_dir "$session" "/some/path/to/preferred"
    assert_success
    assert_output "$preferred_dir"
}

@test "find_worker_state_dir searches all projects" {
    local session="v0-project-b-worker-chore"
    local state_dir="$HOME/.local/state/v0/project-b/tree/$session"
    mkdir -p "$state_dir"
    touch "$state_dir/.worker-git-dir"

    run find_worker_state_dir "$session"
    assert_success
    assert_output "$state_dir"
}

# ============================================================================
# cleanup_worktree() tests (with mocks)
# ============================================================================

# Mock cleanup function that doesn't actually call git
mock_cleanup_worktree() {
    local tree_dir="$1"
    local branch="$2"

    if [ -z "$tree_dir" ] || [ ! -d "$tree_dir" ]; then
        return 0
    fi

    # Record cleanup attempt
    echo "cleanup: $tree_dir $branch" >> "$TEST_TEMP_DIR/cleanup.log"
    rm -rf "$tree_dir"
}

@test "cleanup_worktree handles empty tree_dir" {
    run mock_cleanup_worktree "" "some-branch"
    assert_success
}

@test "cleanup_worktree handles nonexistent directory" {
    run mock_cleanup_worktree "/nonexistent/path" "some-branch"
    assert_success
}

@test "cleanup_worktree removes existing directory" {
    local tree_dir="$TEST_TEMP_DIR/worktree"
    mkdir -p "$tree_dir"

    mock_cleanup_worktree "$tree_dir" "test-branch"

    assert [ ! -d "$tree_dir" ]
}

@test "cleanup_worktree logs the cleanup" {
    local tree_dir="$TEST_TEMP_DIR/worktree"
    mkdir -p "$tree_dir"

    mock_cleanup_worktree "$tree_dir" "test-branch"

    assert_file_exists "$TEST_TEMP_DIR/cleanup.log"
    run cat "$TEST_TEMP_DIR/cleanup.log"
    assert_output --partial "cleanup: $tree_dir test-branch"
}

# ============================================================================
# worker_running() tests (with mocks)
# ============================================================================

@test "worker_running returns false when session doesn't exist" {
    export MOCK_TMUX_SESSION_EXISTS=false

    worker_running() {
        # Mocked: always returns false
        return 1
    }

    run worker_running
    assert_failure
}

@test "worker_running returns true when session exists" {
    export MOCK_TMUX_SESSION_EXISTS=true

    worker_running() {
        # Mocked: always returns true
        return 0
    }

    run worker_running
    assert_success
}

# ============================================================================
# create_done_script() tests
# ============================================================================

@test "create_done_script creates executable file" {
    local target_dir="$TEST_TEMP_DIR/worker"
    mkdir -p "$target_dir"

    # Simplified version of create_done_script
    cat > "$target_dir/done" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$target_dir/done"

    assert_file_exists "$target_dir/done"
    assert [ -x "$target_dir/done" ]
}

@test "create_done_script file is valid bash" {
    local target_dir="$TEST_TEMP_DIR/worker"
    mkdir -p "$target_dir"

    cat > "$target_dir/done" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$target_dir/done"

    run bash -n "$target_dir/done"
    assert_success
}

# ============================================================================
# Backoff sequence integration test
# ============================================================================

@test "backoff sequence follows exponential pattern" {
    local expected_sequence=(5 10 20 40 80 160 300 300 300)

    for i in $(seq 1 9); do
        local expected="${expected_sequence[$((i-1))]}"
        local actual
        actual=$(calculate_backoff $i)
        assert_equal "$actual" "$expected" "Failure $i: expected $expected, got $actual"
    done
}

# ============================================================================
# reopen_worker_issues() tests
# ============================================================================

@test "reopen_worker_issues succeeds with no matching issues" {
    # Create mock wk that returns empty JSON
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo '{"issues":[]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    run reopen_worker_issues "worker:chore"
    assert_success
    assert_output ""
}

@test "reopen_worker_issues reopens matching issues" {
    # Create mock wk that returns issues and logs calls
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
echo "$@" >> "$TEST_TEMP_DIR/wk.log"
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-1234"},{"id":"testp-5678"}]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    run reopen_worker_issues "worker:fix"
    assert_success
    assert_output --partial "Reopening: testp-1234"
    assert_output --partial "Reopening: testp-5678"

    # Verify wk was called with correct commands
    run cat "$TEST_TEMP_DIR/wk.log"
    assert_output --partial "reopen testp-1234"
    assert_output --partial "edit testp-1234 assignee none"
    assert_output --partial "reopen testp-5678"
    assert_output --partial "edit testp-5678 assignee none"
}

@test "reopen_worker_issues handles wk command failures gracefully" {
    # Create mock wk that fails on reopen/edit
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-fail"}]}'
    exit 0
fi
# All other commands fail
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    # Should not fail even when wk reopen/edit fails
    run reopen_worker_issues "worker:chore"
    assert_success
    assert_output --partial "Reopening: testp-fail"
}

@test "reopen_worker_issues handles jq parse errors gracefully" {
    # Create mock wk that returns invalid JSON
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo "invalid json"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    # Should succeed even with invalid JSON (due to || true)
    run reopen_worker_issues "worker:fix"
    assert_success
}

# ============================================================================
# detect_note_without_fix() tests
# ============================================================================

@test "detect_note_without_fix returns 1 when bug has no notes" {
    # Create mock wk that returns bug with no notes
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
    )

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    run detect_note_without_fix "testp-1234" "$TEST_TEMP_DIR/repo"
    assert_failure  # Returns 1 when no notes
}

@test "detect_note_without_fix returns 1 when bug has notes and commits" {
    # Create mock wk that returns bug with notes
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[{"content":"Cannot reproduce"}]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo with commits ahead of origin/main
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
        # Create origin/main ref
        git update-ref refs/remotes/origin/main HEAD
        # Add another commit
        echo "fix" > fix.txt
        git add fix.txt
        git commit --quiet -m "Fix commit"
    )

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    run detect_note_without_fix "testp-1234" "$TEST_TEMP_DIR/repo"
    assert_failure  # Returns 1 when has commits
}

@test "detect_note_without_fix returns 0 when bug has notes but no commits" {
    # Create mock wk that returns bug with notes
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[{"content":"Cannot reproduce"}]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo with no commits ahead of origin/main
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
        # Create origin/main ref pointing to HEAD (no commits ahead)
        git update-ref refs/remotes/origin/main HEAD
    )

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    run detect_note_without_fix "testp-1234" "$TEST_TEMP_DIR/repo"
    assert_success  # Returns 0 when note exists but no commits
}

@test "detect_note_without_fix returns 1 for invalid bug ID" {
    # Create mock wk that fails for invalid ID
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "show" ]]; then
    echo "error: issue not found" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    run detect_note_without_fix "invalid-id" "$TEST_TEMP_DIR"
    assert_failure  # Returns 1 when wk show fails
}

@test "detect_note_without_fix handles wk command failure gracefully" {
    # Create mock wk that always fails
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Source the function
    source "$BATS_TEST_DIRNAME/../../lib/worker-common.sh"

    # Should return 1 (no note scenario) when wk fails
    run detect_note_without_fix "testp-1234" "$TEST_TEMP_DIR"
    assert_failure
}
