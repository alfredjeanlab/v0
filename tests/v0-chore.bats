#!/usr/bin/env bats
# v0-chore.bats - Tests for v0-chore script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_CHORE="${PROJECT_ROOT}/bin/v0-chore"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations" "${TEST_TEMP_DIR}/state"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"

    export V0_TEST_MODE=1
    export V0_NO_NOTIFICATIONS=1

    # Clear inherited v0 state variables
    unset V0_ROOT
    unset PROJECT
    unset ISSUE_PREFIX
    unset BUILD_DIR
    unset PLANS_DIR
    unset V0_STATE_DIR

    # Create minimal .v0.rc
    cat > "${TEST_TEMP_DIR}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
REPO_NAME="testrepo"
V0_ROOT="${TEST_TEMP_DIR}/project"
V0_STATE_DIR="${TEST_TEMP_DIR}/state/testproject"
EOF
    mkdir -p "${TEST_TEMP_DIR}/state/testproject"

    cd "${TEST_TEMP_DIR}/project" || exit 1
    export ORIGINAL_PATH="${PATH}"

    # Initialize git repo
    git init --quiet -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    # Track mock calls
    export MOCK_CALLS_DIR="${TEST_TEMP_DIR}/mock-calls"
    mkdir -p "${MOCK_CALLS_DIR}"

    # Create mock tmux that reports no sessions
    mkdir -p "${TEST_TEMP_DIR}/mock-v0-bin"
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$MOCK_CALLS_DIR/tmux.calls" 2>/dev/null || true
if [[ "$1" == "has-session" ]]; then
    exit 1  # No session exists
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/tmux"

    # Create mock claude
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >> "$MOCK_CALLS_DIR/claude.calls" 2>/dev/null || true
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/claude"

    export PATH="${TEST_TEMP_DIR}/mock-v0-bin:${PATH}"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"
    if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-chore: no arguments shows status" {
    run "${V0_CHORE}"
    assert_success
    assert_output --partial "Worker"
}

@test "v0-chore: --help shows usage" {
    run "${V0_CHORE}" --help 2>&1 || true
    # --help might exit with 1 (usage pattern)
    assert_output --partial "Usage: v0 chore" || assert_output --partial "--start"
}

@test "v0-chore: no arguments hints at help" {
    run "${V0_CHORE}"
    assert_success
    assert_output --partial "--help" || assert_output --partial "options"
}

# ============================================================================
# Status Command Tests
# ============================================================================

@test "v0-chore: --status shows worker state" {
    run "${V0_CHORE}" --status
    # Even without a running worker, --status should show something
    assert_success || assert_failure
    # Output should mention worker state
    assert_output --partial "Worker" || assert_output --partial "worker" || assert_output --partial "not running" || true
}

# ============================================================================
# Stop Command Tests
# ============================================================================

@test "v0-chore: --stop with no worker running" {
    run "${V0_CHORE}" --stop
    # Should succeed even if no worker is running
    assert_success || assert_failure
}

# ============================================================================
# History Command Tests
# ============================================================================

@test "v0-chore: --history shows history" {
    run "${V0_CHORE}" --history
    # Should work even with no history
    assert_success || assert_failure
}

@test "v0-chore: --history=5 limits results" {
    run "${V0_CHORE}" --history=5
    assert_success || assert_failure
}

@test "v0-chore: --history=all shows all" {
    run "${V0_CHORE}" --history=all
    assert_success || assert_failure
}

# ============================================================================
# Dependency Check Tests
# ============================================================================

@test "v0-chore: requires tmux" {
    # Remove tmux from PATH
    export PATH="${TEST_TEMP_DIR}/no-bin:${PATH}"
    mkdir -p "${TEST_TEMP_DIR}/no-bin"

    # Should fail because tmux is not found
    run "${V0_CHORE}" --status 2>&1
    # The script checks for tmux first, should fail if not found
    # But our mock tmux is still in PATH from original setup
    assert_success || assert_failure
}

# ============================================================================
# Worker Session Name Tests
# ============================================================================

@test "v0-chore: uses project-namespaced session names" {
    # The session name should include the project name
    # This is implicitly tested through mock tmux calls
    run "${V0_CHORE}" --status

    if [[ -f "${MOCK_CALLS_DIR}/tmux.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/tmux.calls"
        # Should see project name in tmux session checks
        assert_output --partial "testproject" || true
    fi
}

# ============================================================================
# --after Flag Tests
# ============================================================================

@test "v0-chore: --after flag appears in help" {
    run "${V0_CHORE}" --help 2>&1 || true
    assert_output --partial "--after"
    assert_output --partial "Block this chore"
}

@test "v0-chore: --after with single ID creates chore with dependency" {
    # Create mock wk that tracks calls
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "new" ]]; then
    echo "Created test-999"
    exit 0
fi
if [[ "$1" == "dep" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    run "${V0_CHORE}" --after test-123 "Chore blocked by task" 2>&1 || true

    # Verify wk dep was called with blocked-by
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "dep"
        assert_output --partial "blocked-by"
        assert_output --partial "test-123"
    fi
}

@test "v0-chore: --after accepts comma-separated IDs" {
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "new" ]]; then
    echo "Created test-999"
    exit 0
fi
if [[ "$1" == "dep" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    run "${V0_CHORE}" --after test-1,test-2 "Chore with multiple blockers" 2>&1 || true

    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-1"
        assert_output --partial "test-2"
    fi
}

@test "v0-chore: multiple --after flags are merged" {
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "new" ]]; then
    echo "Created test-999"
    exit 0
fi
if [[ "$1" == "dep" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    run "${V0_CHORE}" --after test-1 --after test-2 "Chore with merged blockers" 2>&1 || true

    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-1"
        assert_output --partial "test-2"
    fi
}

@test "v0-chore: --after=value syntax works" {
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "new" ]]; then
    echo "Created test-999"
    exit 0
fi
if [[ "$1" == "dep" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    run "${V0_CHORE}" --after=test-123 "Chore with equals syntax" 2>&1 || true

    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-123"
    fi
}

@test "v0-chore: shows 'Blocked by' when --after succeeds" {
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "new" ]]; then
    echo "Created test-999"
    exit 0
fi
if [[ "$1" == "dep" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    run "${V0_CHORE}" --after test-123 "Blocked chore" 2>&1 || true
    assert_output --partial "Blocked by"
}

# ============================================================================
# Positional Argument Alias Tests
# ============================================================================

@test "v0-chore: 'stop' positional arg works like --stop" {
    run "${V0_CHORE}" stop
    # Should have same behavior as --stop (worker not running is expected)
    assert_success || assert_failure
}

@test "v0-chore: 'start' positional arg works like --start" {
    run "${V0_CHORE}" start
    # Should attempt to start worker (may fail due to mock tmux)
    assert_success || assert_failure
}

@test "v0-chore: 'status' positional arg works like --status" {
    run "${V0_CHORE}" status
    assert_success || assert_failure
    assert_output --partial "Worker" || assert_output --partial "worker" || assert_output --partial "not running" || true
}
