#!/usr/bin/env bats
# v0-decompose.bats - Tests for v0-decompose script

load '../helpers/test_helper'

# Path to the script under test
V0_DECOMPOSE="${PROJECT_ROOT}/bin/v0-decompose"

setup() {
    # Call common setup from test_helper
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    mkdir -p "${TEST_TEMP_DIR}/state"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"

    export V0_TEST_MODE=1
    export V0_NO_NOTIFICATIONS=1

    # Clear inherited v0 state variables to ensure test isolation
    unset V0_ROOT
    unset PROJECT
    unset ISSUE_PREFIX
    unset BUILD_DIR
    unset PLANS_DIR
    unset V0_STATE_DIR

    # Create minimal .v0.rc
    cat > "${TEST_TEMP_DIR}/project/.v0.rc" <<'EOF'
PROJECT="testproject"
ISSUE_PREFIX="test"
EOF

    cd "${TEST_TEMP_DIR}/project" || return 1

    # Initialize git repo for plan commit checks
    # Use /usr/bin/git explicitly to bypass the mock git in PATH
    /usr/bin/git init --quiet
    /usr/bin/git config user.email "test@example.com"
    /usr/bin/git config user.name "Test User"
    /usr/bin/git add .v0.rc
    /usr/bin/git commit --quiet -m "Initial commit"

    export ORIGINAL_PATH="${PATH}"

    # Add mock-bin to PATH (after git init so setup uses real git)
    export PATH="${TESTS_DIR}/helpers/mock-bin:${PATH}"

    # Track calls to mocked commands
    export MOCK_CALLS_DIR="${TEST_TEMP_DIR}/mock-calls"
    mkdir -p "${MOCK_CALLS_DIR}"

    # Create mock claude binary
    mkdir -p "${TEST_TEMP_DIR}/mock-v0-bin"
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "${MOCK_CALLS_DIR}/claude.calls"
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

@test "v0-decompose: no arguments shows usage" {
    run "${V0_DECOMPOSE}"
    assert_failure
    assert_output --partial "Usage: v0 decompose"
    assert_output --partial "<plan-file>"
}

@test "v0-decompose: usage shows example" {
    run "${V0_DECOMPOSE}"
    assert_failure
    assert_output --partial "Example:"
    assert_output --partial "v0 decompose"
}

# ============================================================================
# Input Validation Tests
# ============================================================================

@test "v0-decompose: errors when plan file doesn't exist" {
    run "${V0_DECOMPOSE}" "nonexistent-plan.md"
    assert_failure
    assert_output --partial "Error: Plan file not found"
    assert_output --partial "nonexistent-plan.md"
}

@test "v0-decompose: errors with descriptive message for missing file" {
    run "${V0_DECOMPOSE}" "/path/to/nowhere/plan.md"
    assert_failure
    assert_output --partial "Error: Plan file not found: /path/to/nowhere/plan.md"
}

# ============================================================================
# Plan File Processing Tests
# ============================================================================

@test "v0-decompose: reads plan file when it exists" {
    # Create a test plan file
    cat > "${TEST_TEMP_DIR}/project/plans/test-plan.md" <<'EOF'
# Test Plan

## Tasks
1. First task
2. Second task
EOF
    # Commit the plan file
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plans/test-plan.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: test-plan"

    run "${V0_DECOMPOSE}" "plans/test-plan.md"
    assert_success

    # Verify claude was called
    assert [ -f "${MOCK_CALLS_DIR}/claude.calls" ]
}

@test "v0-decompose: extracts basename from plan file path" {
    cat > "${TEST_TEMP_DIR}/project/plans/my-feature.md" <<'EOF'
# My Feature Plan
Some content
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plans/my-feature.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: my-feature"

    run "${V0_DECOMPOSE}" "plans/my-feature.md"
    assert_success

    # The prompt should include the basename label
    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "my-feature"
}

@test "v0-decompose: handles plan files with .md extension" {
    cat > "${TEST_TEMP_DIR}/project/test.md" <<'EOF'
# Test
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add test.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: test"

    run "${V0_DECOMPOSE}" "test.md"
    assert_success
}

@test "v0-decompose: handles nested plan file paths" {
    mkdir -p "${TEST_TEMP_DIR}/project/plans/subdir"
    cat > "${TEST_TEMP_DIR}/project/plans/subdir/deep-plan.md" <<'EOF'
# Deep Plan
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plans/subdir/deep-plan.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: deep-plan"

    run "${V0_DECOMPOSE}" "plans/subdir/deep-plan.md"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "deep-plan"
}

# ============================================================================
# Claude Invocation Tests
# ============================================================================

@test "v0-decompose: calls claude with --model opus" {
    cat > "${TEST_TEMP_DIR}/project/plan.md" <<'EOF'
# Plan
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plan.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan"

    run "${V0_DECOMPOSE}" "plan.md"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "--model opus"
}

@test "v0-decompose: skips permissions by default" {
    cat > "${TEST_TEMP_DIR}/project/plan.md" <<'EOF'
# Plan
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plan.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan"

    run "${V0_DECOMPOSE}" "plan.md"
    assert_success

    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "--dangerously-skip-permissions"
}

@test "v0-decompose: respects V0_SAFE mode" {
    cat > "${TEST_TEMP_DIR}/project/plan.md" <<'EOF'
# Plan
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plan.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan"

    export V0_SAFE=1
    run "${V0_DECOMPOSE}" "plan.md"
    assert_success

    # In safe mode, should NOT have --dangerously-skip-permissions
    run cat "${MOCK_CALLS_DIR}/claude.calls"
    refute_output --partial "--dangerously-skip-permissions"
}

# ============================================================================
# Plan Label Tests
# ============================================================================

@test "v0-decompose: adds plan label based on basename" {
    cat > "${TEST_TEMP_DIR}/project/plans/auth.md" <<'EOF'
# Authentication Plan
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plans/auth.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: auth"

    run "${V0_DECOMPOSE}" "plans/auth.md"
    assert_success

    # Should label issues with plan:auth
    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "plan:auth"
}

@test "v0-decompose: strips .md from basename for label" {
    cat > "${TEST_TEMP_DIR}/project/feature.md" <<'EOF'
# Feature
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add feature.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: feature"

    run "${V0_DECOMPOSE}" "feature.md"
    assert_success

    # Should use "feature" not "feature.md"
    run cat "${MOCK_CALLS_DIR}/claude.calls"
    assert_output --partial "plan:feature"
    refute_output --partial "plan:feature.md"
}

# ============================================================================
# Uncommitted Plan File Check Tests
# ============================================================================

@test "v0-decompose: errors when plan file is not committed" {
    cat > "${TEST_TEMP_DIR}/project/plans/uncommitted.md" <<'EOF'
# Uncommitted Plan
EOF
    # Do NOT commit the file

    run "${V0_DECOMPOSE}" "plans/uncommitted.md"
    assert_failure
    assert_output --partial "Error: Plan file is not committed"
    assert_output --partial "plans/uncommitted.md"
}

@test "v0-decompose: errors when plan file has uncommitted changes" {
    cat > "${TEST_TEMP_DIR}/project/plans/modified.md" <<'EOF'
# Original Plan
EOF
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add plans/modified.md
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Add plan: modified"

    # Modify the file after committing
    echo "# Modified content" >> "${TEST_TEMP_DIR}/project/plans/modified.md"

    run "${V0_DECOMPOSE}" "plans/modified.md"
    assert_failure
    assert_output --partial "Error: Plan file has uncommitted changes"
}

@test "v0-decompose: succeeds when plans directory is gitignored" {
    # Add plans/ to .gitignore
    echo "plans/" >> "${TEST_TEMP_DIR}/project/.gitignore"
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" add .gitignore
    /usr/bin/git -C "${TEST_TEMP_DIR}/project" commit --quiet -m "Ignore plans directory"

    cat > "${TEST_TEMP_DIR}/project/plans/ignored.md" <<'EOF'
# Ignored Plan
EOF
    # File is NOT committed but should be allowed because gitignored

    run "${V0_DECOMPOSE}" "plans/ignored.md"
    assert_success
}
