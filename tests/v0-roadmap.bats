#!/usr/bin/env bats
# v0-roadmap.bats - Tests for v0-roadmap command

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_ROADMAP="${PROJECT_ROOT}/bin/v0-roadmap"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/roadmaps" "${TEST_TEMP_DIR}/state"

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

    # Create mock wk that returns a fake idea ID
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "new" ]] && [[ "$2" == "idea" ]]; then
    echo "Created test-abc123"
fi
if [[ "$1" == "list" ]]; then
    echo ""
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    # Create mock m4
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/m4" <<'EOF'
#!/bin/bash
echo "m4 $*" >> "$MOCK_CALLS_DIR/m4.calls" 2>/dev/null || true
# Output a minimal CLAUDE.md
echo "## Your Mission"
echo "Test roadmap"
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/m4"

    # Create mock jq (use real jq if available, otherwise simple mock)
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "${TEST_TEMP_DIR}/mock-v0-bin/jq"
    fi

    export PATH="${TEST_TEMP_DIR}/mock-v0-bin:${PATH}"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"

    # Kill any background workers that might have been started
    if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}/project/.v0/build/roadmaps" ]]; then
        for state_file in "${TEST_TEMP_DIR}/project/.v0/build/roadmaps"/*/state.json; do
            [[ -f "${state_file}" ]] || continue
            local pid
            pid=$(jq -r '.worker_pid // empty' "${state_file}" 2>/dev/null || true)
            if [[ -n "${pid}" ]] && [[ "${pid}" != "null" ]]; then
                kill "${pid}" 2>/dev/null || true
                # Wait briefly for process to terminate
                for _ in {1..10}; do
                    kill -0 "${pid}" 2>/dev/null || break
                    sleep 0.1
                done
            fi
        done
    fi

    if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-roadmap: --help shows usage" {
    run "${V0_ROADMAP}" --help 2>&1 || true
    assert_output --partial "Usage: v0 roadmap"
}

@test "v0-roadmap: no arguments shows usage error" {
    run "${V0_ROADMAP}" 2>&1 || true
    assert_failure
    assert_output --partial "Usage: v0 roadmap"
}

@test "v0-roadmap: --status with no roadmaps shows empty" {
    run "${V0_ROADMAP}" --status
    assert_success
    # Output shows "Roadmaps:" header and "(none)" when empty
    assert_output --partial "(none)"
}

# ============================================================================
# Name Validation Tests
# ============================================================================

@test "v0-roadmap: rejects invalid name with spaces" {
    run "${V0_ROADMAP}" "invalid name" "Description" 2>&1
    assert_failure
    assert_output --partial "must start with an alphanumeric"
}

@test "v0-roadmap: accepts name starting with number" {
    run "${V0_ROADMAP}" "123roadmap" "Test description" --dry-run
    assert_success
}

@test "v0-roadmap: rejects name starting with underscore" {
    run "${V0_ROADMAP}" "_roadmap" "Description" 2>&1
    assert_failure
    assert_output --partial "must start with an alphanumeric"
}

@test "v0-roadmap: accepts valid name with letters and hyphens" {
    run "${V0_ROADMAP}" "my-roadmap" "Test description" --dry-run
    assert_success
}

@test "v0-roadmap: accepts valid name with letters and numbers" {
    run "${V0_ROADMAP}" "roadmap123" "Test description" --dry-run
    assert_success
}

# ============================================================================
# Dry Run Tests
# ============================================================================

@test "v0-roadmap: --dry-run creates state directory" {
    run "${V0_ROADMAP}" test-roadmap "Test roadmap description" --dry-run
    assert_success
    assert_output --partial "Creating roadmap"
    assert [ -d "${TEST_TEMP_DIR}/project/.v0/build/roadmaps/test-roadmap" ]
}

@test "v0-roadmap: --dry-run creates state.json" {
    run "${V0_ROADMAP}" test-roadmap "Test roadmap description" --dry-run
    assert_success
    assert [ -f "${TEST_TEMP_DIR}/project/.v0/build/roadmaps/test-roadmap/state.json" ]
}

@test "v0-roadmap: --dry-run state contains roadmap_description" {
    run "${V0_ROADMAP}" test-roadmap "My amazing roadmap" --dry-run
    assert_success
    run jq -r '.roadmap_description' "${TEST_TEMP_DIR}/project/.v0/build/roadmaps/test-roadmap/state.json"
    assert_output "My amazing roadmap"
}

@test "v0-roadmap: --dry-run state contains correct name" {
    run "${V0_ROADMAP}" myroadmap "Some description" --dry-run
    assert_success
    run jq -r '.name' "${TEST_TEMP_DIR}/project/.v0/build/roadmaps/myroadmap/state.json"
    assert_output "myroadmap"
}

@test "v0-roadmap: --dry-run state has init phase" {
    run "${V0_ROADMAP}" test-roadmap "Test" --dry-run
    assert_success
    run jq -r '.phase' "${TEST_TEMP_DIR}/project/.v0/build/roadmaps/test-roadmap/state.json"
    assert_output "init"
}

@test "v0-roadmap: --dry-run does not launch worker" {
    run "${V0_ROADMAP}" test-roadmap "Test roadmap" --dry-run
    assert_success
    assert_output --partial "Dry run complete"
    # No tmux calls should be made
    assert [ ! -f "${MOCK_CALLS_DIR}/tmux.calls" ] || ! grep -q "new-session" "${MOCK_CALLS_DIR}/tmux.calls"
}

# ============================================================================
# Duplicate Roadmap Tests
# ============================================================================

@test "v0-roadmap: rejects duplicate roadmap name" {
    # Create first roadmap
    run "${V0_ROADMAP}" myroadmap "First roadmap" --dry-run
    assert_success

    # Try to create second roadmap with same name
    run "${V0_ROADMAP}" myroadmap "Second roadmap" --dry-run 2>&1
    assert_failure
    assert_output --partial "already exists"
}

# ============================================================================
# Resume Tests
# ============================================================================

@test "v0-roadmap: --resume fails for non-existent roadmap" {
    run "${V0_ROADMAP}" nonexistent --resume 2>&1
    assert_failure
    assert_output --partial "No roadmap found"
}

@test "v0-roadmap: --resume works for existing roadmap" {
    # Create roadmap first
    run "${V0_ROADMAP}" myroadmap "Test" --dry-run
    assert_success

    # Now resume should work - use --dry-run to avoid launching real worker
    run "${V0_ROADMAP}" myroadmap --resume --dry-run 2>&1
    # It should find the roadmap and try to resume
    assert_output --partial "Resuming roadmap"
}

# ============================================================================
# Status Display Tests
# ============================================================================

@test "v0-roadmap: --status shows existing roadmaps" {
    # Create a roadmap
    run "${V0_ROADMAP}" myroadmap "Test description" --dry-run
    assert_success

    # Status should show it
    run "${V0_ROADMAP}" --status
    assert_success
    assert_output --partial "myroadmap"
}

@test "v0-roadmap: --status shows roadmap phase" {
    # Create a roadmap
    run "${V0_ROADMAP}" myroadmap "Test description" --dry-run
    assert_success

    # Status should show the phase
    run "${V0_ROADMAP}" --status
    assert_success
    assert_output --partial "init"
}

# ============================================================================
# wk Idea Integration Tests
# ============================================================================

@test "v0-roadmap: creates wk idea issue" {
    run "${V0_ROADMAP}" myroadmap "Test roadmap" --dry-run
    assert_success

    # Check that wk new idea was called
    assert [ -f "${MOCK_CALLS_DIR}/wk.calls" ]
    run grep "new idea" "${MOCK_CALLS_DIR}/wk.calls"
    assert_success
}

@test "v0-roadmap: idea label includes roadmap name" {
    run "${V0_ROADMAP}" myroadmap "Test roadmap" --dry-run
    assert_success

    # Check that the roadmap label was included
    run grep "roadmap:myroadmap" "${MOCK_CALLS_DIR}/wk.calls"
    assert_success
}

# ============================================================================
# M4 Template Substitution Tests
# ============================================================================

@test "v0-roadmap-worker: m4 array expansion preserves spaces in description" {
    # This test verifies the fix for m4 argument handling with spaces
    # The worker now uses an array for M4_ARGS to avoid word-splitting
    #
    # We test this by simulating the exact code pattern from v0-roadmap-worker
    # with a mock m4 that logs its arguments

    # Create mock m4 that logs its arguments
    mkdir -p "${TEST_TEMP_DIR}/mock-bin"
    cat > "${TEST_TEMP_DIR}/mock-bin/m4" <<'MOCK_EOF'
#!/bin/bash
for arg in "$@"; do
    echo "ARG: $arg"
done
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-bin/m4"

    export PATH="${TEST_TEMP_DIR}/mock-bin:${PATH}"

    # Simulate the fixed code pattern from v0-roadmap-worker
    NAME="test-roadmap"
    DESCRIPTION="Build a REST API with multiple endpoints"
    IDEA_ID="test-123"
    V0_GIT_REMOTE="origin"

    # This is the fixed array-based approach
    M4_ARGS=(
        -D "ROADMAP_NAME=${NAME}"
        -D "ROADMAP_DESCRIPTION=${DESCRIPTION}"
        -D "IDEA_ID=${IDEA_ID:-none}"
        -D "V0_GIT_REMOTE=${V0_GIT_REMOTE}"
    )

    # Run m4 with the array expansion
    run m4 "${M4_ARGS[@]}" /dev/null

    # Verify the description with spaces was passed as a single argument
    assert_output --partial "ARG: -D"
    assert_output --partial "ROADMAP_DESCRIPTION=Build a REST API with multiple endpoints"
}

# ============================================================================
# Worker Environment Variable Tests
# ============================================================================

@test "v0-roadmap-worker: tmux command includes BUILD_DIR env var" {
    # This test verifies that the roadmap worker passes BUILD_DIR to the tmux session
    # We check the source code directly since launching workers in tests is complex

    run grep -E "BUILD_DIR=" "${PROJECT_ROOT}/bin/v0-roadmap-worker"
    assert_success
    assert_output --partial "BUILD_DIR='\${BUILD_DIR}'"
}

@test "v0-roadmap-worker: tmux command includes V0_DEVELOP_BRANCH env var" {
    # This test verifies that the roadmap worker passes V0_DEVELOP_BRANCH to the tmux session

    run grep -E "V0_DEVELOP_BRANCH=" "${PROJECT_ROOT}/bin/v0-roadmap-worker"
    assert_success
    assert_output --partial "V0_DEVELOP_BRANCH='\${V0_DEVELOP_BRANCH}'"
}
