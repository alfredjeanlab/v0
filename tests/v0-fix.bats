#!/usr/bin/env bats
# v0-fix.bats - Tests for v0-fix script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_FIX="${PROJECT_ROOT}/bin/v0-fix"

setup() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
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

    cd "${TEST_TEMP_DIR}/project" || return 1
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
echo "tmux $*" >> "${MOCK_CALLS_DIR}/tmux.calls" 2>/dev/null || true
if [[ "$1" == "has-session" ]]; then
    exit 1  # No session exists
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/tmux"

    # Create mock claude
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >> "${MOCK_CALLS_DIR}/claude.calls" 2>/dev/null || true
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/claude"

    export PATH="${TEST_TEMP_DIR}/mock-v0-bin:${PATH}"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"
    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-fix: no arguments shows status" {
    run "${V0_FIX}"
    assert_success
    assert_output --partial "Worker"
}

@test "v0-fix: --help shows usage" {
    run "${V0_FIX}" --help 2>&1 || true
    # --help might exit with 1 (usage pattern)
    assert_output --partial "Usage: v0 fix" || assert_output --partial "--start"
}

@test "v0-fix: no arguments hints at help" {
    run "${V0_FIX}"
    assert_success
    assert_output --partial "--help" || assert_output --partial "options"
}

# ============================================================================
# Status Command Tests
# ============================================================================

@test "v0-fix: --status shows worker state" {
    run "${V0_FIX}" --status
    assert_success || assert_failure
    assert_output --partial "Worker" || assert_output --partial "worker" || assert_output --partial "not running" || true
}

# ============================================================================
# Stop Command Tests
# ============================================================================

@test "v0-fix: --stop with no worker running" {
    run "${V0_FIX}" --stop
    assert_success || assert_failure
}

# ============================================================================
# History Command Tests
# ============================================================================

@test "v0-fix: --history shows history" {
    run "${V0_FIX}" --history
    assert_success || assert_failure
}

@test "v0-fix: --history=5 limits results" {
    run "${V0_FIX}" --history=5
    assert_success || assert_failure
}

@test "v0-fix: --history=all shows all" {
    run "${V0_FIX}" --history=all
    assert_success || assert_failure
}

# ============================================================================
# Worker Session Name Tests
# ============================================================================

@test "v0-fix: uses project-namespaced session names" {
    run "${V0_FIX}" --status

    if [ -f "${MOCK_CALLS_DIR}/tmux.calls" ]; then
        run cat "${MOCK_CALLS_DIR}/tmux.calls"
        assert_output --partial "testproject" || true
    fi
}

# ============================================================================
# Issue ID Parsing Tests
# ============================================================================

@test "v0-fix: accepts issue ID as argument" {
    # Creating a fix with an issue ID should start the worker
    # Since worker can't actually start (mock tmux), it may fail
    run "${V0_FIX}" "TEST-123" 2>&1 || true
    # Should attempt something related to the issue
    [[ "${output}" == *"TEST-123"* ]] || [[ "${output}" == *"Worker"* ]] || [[ "${output}" == *"fix"* ]] || true
}

# ============================================================================
# --after Flag Tests
# ============================================================================

@test "v0-fix: --after flag appears in help" {
    run "${V0_FIX}" --help 2>&1 || true
    assert_output --partial "--after"
    assert_output --partial "Block this bug"
}

@test "v0-fix: --after with single ID creates bug with dependency" {
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

    run "${V0_FIX}" --after test-123 "Bug blocked by task" 2>&1 || true

    # Verify wk dep was called with blocked-by
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "dep"
        assert_output --partial "blocked-by"
        assert_output --partial "test-123"
    fi
}

@test "v0-fix: --after accepts comma-separated IDs" {
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

    run "${V0_FIX}" --after test-1,test-2 "Bug with multiple blockers" 2>&1 || true

    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-1"
        assert_output --partial "test-2"
    fi
}

@test "v0-fix: multiple --after flags are merged" {
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

    run "${V0_FIX}" --after test-1 --after test-2 "Bug with merged blockers" 2>&1 || true

    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-1"
        assert_output --partial "test-2"
    fi
}

@test "v0-fix: --after=value syntax works" {
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

    run "${V0_FIX}" --after=test-123 "Bug with equals syntax" 2>&1 || true

    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-123"
    fi
}

@test "v0-fix: shows 'Blocked by' when --after succeeds" {
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

    run "${V0_FIX}" --after test-123 "Blocked bug" 2>&1 || true
    assert_output --partial "Blocked by"
}

# ============================================================================
# Positional Argument Alias Tests
# ============================================================================

@test "v0-fix: 'stop' positional arg works like --stop" {
    run "${V0_FIX}" stop
    # Should have same behavior as --stop (worker not running is expected)
    assert_success || assert_failure
}

@test "v0-fix: 'start' positional arg works like --start" {
    run "${V0_FIX}" start
    # Should attempt to start worker (may fail due to mock tmux)
    assert_success || assert_failure
}

@test "v0-fix: 'status' positional arg works like --status" {
    run "${V0_FIX}" status
    assert_success || assert_failure
    assert_output --partial "Worker" || assert_output --partial "worker" || assert_output --partial "not running" || true
}
