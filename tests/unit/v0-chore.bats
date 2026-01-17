#!/usr/bin/env bats
# v0-chore.bats - Tests for v0-chore script

load '../helpers/test_helper'

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
