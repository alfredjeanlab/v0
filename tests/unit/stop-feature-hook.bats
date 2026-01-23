#!/usr/bin/env bats
# Tests for stop-feature.sh hook - Feature worker stop verification

load '../helpers/test_helper'

# Setup for stop-feature hook tests
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
    export V0_PLAN_LABEL="plan:test-feature"
    export V0_OP="test-feature"

    # Store hook path
    export HOOK_SCRIPT="$BATS_TEST_DIRNAME/../../lib/hooks/stop-feature.sh"
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

@test "stop-feature hook approves when no open issues" {
    # Create mock wk that returns no issues
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
# Return empty list for any status query
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Unset worktree to avoid uncommitted changes check
    unset V0_WORKTREE

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves when stop_hook_active is true" {
    run bash -c 'echo "{\"stop_hook_active\": true}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves for auth-related stop reason" {
    run bash -c 'echo "{\"reason\": \"authentication failed\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves for credential-related stop reason" {
    run bash -c 'echo "{\"reason\": \"invalid credentials\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves for credit-related stop reason" {
    run bash -c 'echo "{\"reason\": \"out of credits\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves for billing-related stop reason" {
    run bash -c 'echo "{\"reason\": \"billing issue\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves for payment-related stop reason" {
    run bash -c 'echo "{\"reason\": \"payment required\"}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook approves when V0_PLAN_LABEL is not set" {
    unset V0_PLAN_LABEL
    unset V0_OP
    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

# ============================================================================
# Blocking tests - open issues
# ============================================================================

@test "stop-feature hook blocks when todo issues exist" {
    # Create mock wk that returns open issues
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$*" == *"--status todo"* ]]; then
    echo "testp-1234 - Some task"
    echo "testp-5678 - Another task"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    assert_output --partial 'issues remain'
}

@test "stop-feature hook blocks when in_progress issues exist" {
    # Create mock wk that returns in_progress issues
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$*" == *"--status in_progress"* ]]; then
    echo "testp-abcd - Working on this"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    assert_output --partial 'issues remain'
}

@test "stop-feature hook includes issue IDs in block message" {
    # Create mock wk that returns issues with IDs
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$*" == *"--status todo"* ]]; then
    echo "testp-1234 - Some task"
fi
if [[ "$*" == *"--status in_progress"* ]]; then
    echo "testp-5678 - In progress task"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial 'testp-1234'
    assert_output --partial 'testp-5678'
}

@test "stop-feature hook includes wk ready hint in block message" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$*" == *"--status todo"* ]]; then
    echo "testp-1234 - Some task"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial 'wk ready --label'
}

# ============================================================================
# Uncommitted changes tests
# ============================================================================

@test "stop-feature hook blocks when worktree has uncommitted changes" {
    # Create mock wk that returns no issues
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo with uncommitted changes
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
        # Add uncommitted change
        echo "modified" >> README.md
    )

    export V0_WORKTREE="$TEST_TEMP_DIR/repo"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output --partial '"decision": "block"'
    assert_output --partial 'Uncommitted changes'
}

@test "stop-feature hook approves when worktree is clean" {
    # Create mock wk that returns no issues
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo with no uncommitted changes
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

    export V0_WORKTREE="$TEST_TEMP_DIR/repo"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook ignores untracked files in uncommitted check" {
    # Create mock wk that returns no issues
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/wk" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/wk"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock git repo with only untracked files
    mkdir -p "$TEST_TEMP_DIR/repo"
    (
        cd "$TEST_TEMP_DIR/repo"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
        # Add untracked file (should be ignored)
        echo "untracked" > untracked.txt
    )

    export V0_WORKTREE="$TEST_TEMP_DIR/repo"

    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}
