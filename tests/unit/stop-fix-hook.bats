#!/usr/bin/env bats
# Tests for stop-fix.sh hook - Fix worker stop verification

load '../helpers/test_helper'

# Setup for stop-fix hook tests
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

    # Store hook path
    export HOOK_SCRIPT="$BATS_TEST_DIRNAME/../../lib/hooks/stop-fix.sh"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"

    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Basic approval tests
# ============================================================================

@test "stop-fix hook approves when no in-progress bugs" {
    # Create mock wk that returns no bugs
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

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-fix hook approves when stop_hook_active is true" {
    run bash -c 'echo "{\"stop_hook_active\": true}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-fix hook approves for auth-related stop reason" {
    run bash -c 'echo "{\"reason\": \"authentication failed\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-fix hook approves for credit-related stop reason" {
    run bash -c 'echo "{\"reason\": \"out of credits\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-fix hook approves for billing-related stop reason" {
    run bash -c 'echo "{\"reason\": \"billing issue\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

# ============================================================================
# Blocking tests - normal in-progress bugs
# ============================================================================

@test "stop-fix hook blocks when bug is in progress" {
    # Create mock wk that returns one in-progress bug
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-1234"}]}'
fi
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    assert_output --partial 'still in progress'
}

# ============================================================================
# Note-without-fix scenario tests
# ============================================================================

@test "stop-fix hook reassigns to human when bug has note but no commits" {
    # Create mock wk that returns bug with notes
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
echo "$@" >> "$TEST_TEMP_DIR/wk.log"
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-1234"}]}'
fi
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[{"content":"Cannot reproduce"}]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo with no commits ahead
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
        git update-ref refs/remotes/origin/main HEAD
    )

    # Create .worker-git-dir file pointing to repo
    echo "$TEST_TEMP_DIR/repo" > "$TEST_TEMP_DIR/project/.worker-git-dir"
    cd "$TEST_TEMP_DIR/project"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    assert_output --partial 'has a note but no fix'
    assert_output --partial 'Reassigned to human'

    # Verify wk edit was called to reassign
    run cat "$TEST_TEMP_DIR/wk.log"
    assert_output --partial "edit testp-1234 assignee worker:human"
}

@test "stop-fix hook blocks normally when bug has note and commits" {
    # Create mock wk that returns bug with notes
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-1234"}]}'
fi
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[{"content":"Cannot reproduce"}]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo WITH commits ahead of origin/main
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
        git update-ref refs/remotes/origin/main HEAD
        # Add a commit ahead
        echo "fix" > fix.txt
        git add fix.txt
        git commit --quiet -m "Fix commit"
    )

    # Create .worker-git-dir file pointing to repo
    echo "$TEST_TEMP_DIR/repo" > "$TEST_TEMP_DIR/project/.worker-git-dir"
    cd "$TEST_TEMP_DIR/project"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    # Should be normal block message, not note-without-fix
    assert_output --partial 'still in progress'
    refute_output --partial 'has a note but no fix'
}

@test "stop-fix hook blocks normally when .worker-git-dir is missing" {
    # Create mock wk that returns bug with notes
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-1234"}]}'
fi
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[{"content":"Cannot reproduce"}]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # No .worker-git-dir file
    cd "$TEST_TEMP_DIR/project"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    # Should be normal block message since we can't check commits
    assert_output --partial 'still in progress'
}

# ============================================================================
# Multiple bugs test
# ============================================================================

@test "stop-fix hook handles multiple in-progress bugs" {
    # Create mock wk that returns multiple bugs
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
    echo '{"issues":[{"id":"testp-1234"},{"id":"testp-5678"}]}'
fi
if [[ "$1" == "show" ]]; then
    echo '{"id":"testp-1234","notes":[]}'
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    assert_output --partial 'still in progress'
}
