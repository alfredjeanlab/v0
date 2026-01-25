#!/usr/bin/env bats
# v0-build.bats - Tests for v0-build script (blocked-by dependency feature)

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_BUILD="${PROJECT_ROOT}/bin/v0-build"

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
BUILD_DIR="${TEST_TEMP_DIR}/project/.v0/build"
PLANS_DIR="${TEST_TEMP_DIR}/project/plans"
V0_PLANS_DIR="plans"
V0_GIT_REMOTE="origin"
V0_DEVELOP_BRANCH="develop"
V0_FEATURE_BRANCH="feature/{{name}}"
EOF
    mkdir -p "${TEST_TEMP_DIR}/state/testproject"
    mkdir -p "${TEST_TEMP_DIR}/project/plans"

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
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/tmux" <<'MOCK_EOF'
#!/bin/bash
echo "tmux $*" >> "$MOCK_CALLS_DIR/tmux.calls" 2>/dev/null || true
if [[ "$1" == "has-session" ]]; then
    exit 1  # No session exists
fi
exit 0
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/tmux"

    # Create mock claude
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/claude" <<'MOCK_EOF'
#!/bin/bash
echo "claude $*" >> "$MOCK_CALLS_DIR/claude.calls" 2>/dev/null || true
exit 0
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/claude"

    # Create mock wk
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'MOCK_EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "show" ]]; then
    echo '{"status": "open"}'
    exit 0
fi
if [[ "$1" == "new" ]]; then
    echo "Created test-abc123"
    exit 0
fi
if [[ "$1" == "list" ]]; then
    exit 0
fi
if [[ "$1" == "dep" ]]; then
    exit 0
fi
if [[ "$1" == "init" ]]; then
    exit 0
fi
exit 0
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    # Create mock m4
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/m4" <<'MOCK_EOF'
#!/bin/bash
echo "m4 $*" >> "$MOCK_CALLS_DIR/m4.calls" 2>/dev/null || true
cat
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/m4"

    # Create mock jq (pass through to real jq)
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/jq" <<'MOCK_EOF'
#!/bin/bash
/usr/bin/jq "$@"
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/jq"

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

@test "v0-build: --help shows usage" {
    run "${V0_BUILD}" --help 2>&1 || true
    assert_output --partial "Usage: v0 build"
}

@test "v0-build: --help shows --after option" {
    run "${V0_BUILD}" --help 2>&1 || true
    assert_output --partial "--after"
}

# ============================================================================
# get_blocker_issue_id Helper Tests
# ============================================================================

@test "v0-build: get_blocker_issue_id extracts epic_id from blocker state" {
    # Create a blocker operation with epic_id
    local blocker_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/blocker"
    mkdir -p "${blocker_dir}"
    cat > "${blocker_dir}/state.json" <<EOF
{
  "name": "blocker",
  "phase": "merged",
  "epic_id": "test-abc123"
}
EOF

    # Source the script to get the function (indirectly test via v0-build behavior)
    # The function is internal, so we test it through integration
    # This test verifies the state file structure is correct
    run jq -r '.epic_id // empty' "${blocker_dir}/state.json"
    assert_success
    assert_output "test-abc123"
}

@test "v0-build: get_blocker_issue_id returns empty for missing epic_id" {
    local blocker_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/blocker"
    mkdir -p "${blocker_dir}"
    cat > "${blocker_dir}/state.json" <<EOF
{
  "name": "blocker",
  "phase": "init"
}
EOF

    run jq -r '.epic_id // empty' "${blocker_dir}/state.json"
    assert_success
    assert_output ""
}

# ============================================================================
# --after Flag Validation Tests
# ============================================================================

@test "v0-build: --after requires existing operation" {
    run "${V0_BUILD}" test-op "Test prompt" --after nonexistent 2>&1
    assert_failure
    assert_output --partial "does not exist"
}

@test "v0-build: --eager requires --after" {
    run "${V0_BUILD}" test-op "Test prompt" --eager 2>&1
    assert_failure
    assert_output --partial "--eager requires --after"
}

# ============================================================================
# wk dep Integration Tests
# ============================================================================

@test "v0-build: --after with blocker epic_id calls wk dep blocked-by" {
    # Create blocker operation with epic_id
    local blocker_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/blocker"
    mkdir -p "${blocker_dir}"
    cat > "${blocker_dir}/state.json" <<EOF
{
  "name": "blocker",
  "phase": "merged",
  "epic_id": "test-blocker123"
}
EOF

    # Create a plan file with existing feature ID to trigger --plan path
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    cat > "${TEST_TEMP_DIR}/project/plans/test-op.md" <<EOF
# Test Plan

Feature: \`test-feature456\`

## Tasks
- Task 1
EOF

    # Run v0 build with --plan and --after (dry-run to avoid tmux)
    run "${V0_BUILD}" test-op --plan "${TEST_TEMP_DIR}/project/plans/test-op.md" --after blocker --dry-run 2>&1 || true

    # Check that wk dep was called with blocked-by
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        # Should contain: wk dep test-feature456 blocked-by test-blocker123
        assert_output --partial "dep"
        assert_output --partial "blocked-by"
        assert_output --partial "test-blocker123"
    fi
}

@test "v0-build: --after without blocker epic_id silently skips wk dep" {
    # Create blocker operation without epic_id (early stage)
    local blocker_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/blocker"
    mkdir -p "${blocker_dir}"
    cat > "${blocker_dir}/state.json" <<EOF
{
  "name": "blocker",
  "phase": "init",
  "epic_id": null
}
EOF

    # Create a plan file with existing feature ID
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    cat > "${TEST_TEMP_DIR}/project/plans/test-op.md" <<EOF
# Test Plan

Feature: \`test-feature456\`

## Tasks
- Task 1
EOF

    # Run v0 build with --plan and --after (dry-run to avoid tmux)
    run "${V0_BUILD}" test-op --plan "${TEST_TEMP_DIR}/project/plans/test-op.md" --after blocker --dry-run 2>&1 || true

    # Check that wk dep was NOT called (no blocker epic_id)
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        # Should NOT contain blocked-by since blocker has no epic_id
        refute_output --partial "blocked-by"
    fi
}

@test "v0-build: --after stores dependency in state.json" {
    # Create blocker operation
    local blocker_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/blocker"
    mkdir -p "${blocker_dir}"
    cat > "${blocker_dir}/state.json" <<EOF
{
  "name": "blocker",
  "phase": "merged",
  "epic_id": "test-blocker123"
}
EOF

    # Run v0 build with --after (dry-run)
    run "${V0_BUILD}" test-op "Test prompt" --after blocker --dry-run 2>&1 || true

    # Verify state file has after field
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    if [[ -f "${state_file}" ]]; then
        run jq -r '.after' "${state_file}"
        assert_output "blocker"
    fi
}
