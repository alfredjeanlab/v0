#!/usr/bin/env bats
# Tests for stop-fix.sh hook - Fix worker stop verification

load '../../test-support/helpers/test_helper'

# Setup for stop-fix hook tests
setup() {
    _base_setup
    setup_v0_env
    export WORKER_SESSION="v0-testproject-worker-fix"
    export HOOK_SCRIPT="$PROJECT_ROOT/packages/hooks/lib/stop-fix.sh"
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
    echo '[]'
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
    echo '[{"id":"testp-1234"}]'
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
    echo '[{"id":"testp-1234"}]'
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
    echo '[{"id":"testp-1234"}]'
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
    echo '[{"id":"testp-1234"}]'
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
    echo '[{"id":"testp-1234"},{"id":"testp-5678"}]'
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
