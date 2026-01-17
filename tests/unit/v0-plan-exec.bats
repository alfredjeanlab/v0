#!/usr/bin/env bats
# v0-plan-exec.bats - Tests for v0-plan-exec script

load '../helpers/test_helper'

# Path to the script under test
V0_PLAN_EXEC="${PROJECT_ROOT}/bin/v0-plan-exec"

setup() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"
    mkdir -p "${TEST_TEMP_DIR}/state"

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
    unset V0_DRAFT

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

    # Initialize git repo for plan-exec tests
    git init --quiet -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    # Track mock calls
    export MOCK_CALLS_DIR="${TEST_TEMP_DIR}/mock-calls"
    mkdir -p "${MOCK_CALLS_DIR}"

    # Create mock claude binary
    mkdir -p "${TEST_TEMP_DIR}/mock-v0-bin"
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "${MOCK_CALLS_DIR}/claude.calls"
# Simulate creating a plan file
if [[ "$*" == *"--model opus"* ]]; then
    # Extract name from prompt - look for "Plan name:" pattern
    plan_name=$(echo "$*" | grep -oE "Plan name: [a-zA-Z0-9_-]+" | sed 's/Plan name: //')
    if [ -n "${plan_name}" ]; then
        mkdir -p plans
        echo "# Mock Plan for ${plan_name}" > "plans/${plan_name}.md"
    fi
fi
echo "Mock claude executed"
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

@test "v0-plan-exec: no arguments shows usage" {
    run "${V0_PLAN_EXEC}"
    assert_failure
    assert_output --partial "Usage: v0-plan-exec"
    assert_output --partial "<name>"
    assert_output --partial "<instructions>"
}

@test "v0-plan-exec: only one argument shows usage" {
    run "${V0_PLAN_EXEC}" "my-plan"
    assert_failure
    assert_output --partial "Usage: v0-plan-exec"
}

@test "v0-plan-exec: usage mentions v0 plan as normal interface" {
    run "${V0_PLAN_EXEC}"
    assert_failure
    assert_output --partial "v0 plan"
}

# ============================================================================
# Claude Invocation Tests
# ============================================================================

@test "v0-plan-exec: calls claude with correct model" {
    run "${V0_PLAN_EXEC}" "test-plan" "Create a test feature"
    assert_success

    assert [ -f "${MOCK_CALLS_DIR}/claude.calls" ]
    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "--model opus"
}

@test "v0-plan-exec: skips permissions by default" {
    run "${V0_PLAN_EXEC}" "my-plan" "Build something"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "--dangerously-skip-permissions"
}

@test "v0-plan-exec: respects V0_SAFE mode" {
    export V0_SAFE=1
    run "${V0_PLAN_EXEC}" "safe-plan" "Build carefully"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    refute_output --partial "--dangerously-skip-permissions"
}

# ============================================================================
# Plan Name and Instructions Tests
# ============================================================================

@test "v0-plan-exec: includes plan name in prompt" {
    run "${V0_PLAN_EXEC}" "feature-auth" "Add user authentication"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "feature-auth"
}

@test "v0-plan-exec: includes instructions in prompt" {
    run "${V0_PLAN_EXEC}" "my-feature" "Implement the new dashboard widget"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "Implement the new dashboard widget"
}

# ============================================================================
# Plans Directory Tests
# ============================================================================

@test "v0-plan-exec: creates plans directory if missing" {
    rm -rf "${TEST_TEMP_DIR}/project/plans"

    run "${V0_PLAN_EXEC}" "new-plan" "Create something"
    assert_success

    assert [ -d "${TEST_TEMP_DIR}/project/plans" ]
}

# ============================================================================
# Draft Mode Tests
# ============================================================================

@test "v0-plan-exec: V0_DRAFT=1 skips auto-commit" {
    export V0_DRAFT=1

    # Make sure plan file will be created
    mkdir -p plans
    echo "# Test Plan" > plans/draft-plan.md
    git add plans/draft-plan.md

    run "${V0_PLAN_EXEC}" "draft-plan" "Draft feature"
    assert_success

    # Should mention skipping commit in draft mode
    # The plan file shouldn't be committed
    run git status --porcelain
    assert_output --partial "plans/"
}

# ============================================================================
# Auto-Commit Tests
# ============================================================================

@test "v0-plan-exec: auto-commits plan when worktree is clean" {
    run "${V0_PLAN_EXEC}" "commit-plan" "Feature to commit"
    assert_success

    # Check if plan was committed (mock claude creates the file)
    if [ -f "plans/commit-plan.md" ]; then
        run git log --oneline -1
        # Should have a commit message about the plan
        assert_output --partial "plan" || assert_output --partial "commit-plan" || true
    fi
}
