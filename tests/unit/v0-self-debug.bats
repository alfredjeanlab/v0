#!/usr/bin/env bats
# v0-self-debug.bats - Tests for v0-self-debug script

load '../helpers/test_helper'

# Path to the script under test
V0_SELF_DEBUG="${PROJECT_ROOT}/bin/v0-self-debug"

setup() {
    # Call common setup from test_helper
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/mergeq/logs"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/logs"
    mkdir -p "${TEST_TEMP_DIR}/state/tree"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0/testproject/tree"

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

    # Initialize git repo
    /usr/bin/git init --quiet
    /usr/bin/git config user.email "test@example.com"
    /usr/bin/git config user.name "Test User"
    /usr/bin/git add .v0.rc
    /usr/bin/git commit --quiet -m "Initial commit"

    export ORIGINAL_PATH="${PATH}"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"
    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Helper Functions
# ============================================================================

# Create a mock operation with state
create_mock_operation() {
    local name="$1"
    local type="${2:-feature}"
    local phase="${3:-init}"
    local status="${4:-running}"
    local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/${name}"

    mkdir -p "${op_dir}/logs"

    cat > "${op_dir}/state.json" <<EOF
{
    "name": "${name}",
    "type": "${type}",
    "phase": "${phase}",
    "status": "${status}",
    "machine": "test-machine",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
    echo "Test log entry for ${name}" > "${op_dir}/logs/events.log"
}

# Create mock worker state
create_mock_worker_state() {
    local type="$1"
    local worker_dir="${HOME}/.local/state/v0/testproject/tree/v0-${type}-worker"
    mkdir -p "${worker_dir}"
    echo "12345" > "${worker_dir}/.worker-pid"
    echo "v0/worker/${type}" > "${worker_dir}/.worker-branch"
    echo "[$(date)] Polling iteration" > "/tmp/v0-testproject-${type}-polling.log"
}

# Create mock merge queue state
create_mock_mergeq_state() {
    local mergeq_dir="${TEST_TEMP_DIR}/project/.v0/build/mergeq"
    mkdir -p "${mergeq_dir}/logs"
    cat > "${mergeq_dir}/queue.json" <<'EOF'
{
    "version": 1,
    "entries": []
}
EOF
    echo "Queue daemon started" > "${mergeq_dir}/logs/daemon.log"
}

# Update operation state with jq
update_operation_state() {
    local name="$1"
    local jq_expr="$2"
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/${name}/state.json"
    local tmp
    tmp=$(mktemp)
    jq "${jq_expr}" "${state_file}" > "${tmp}" && mv "${tmp}" "${state_file}"
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-self-debug: --help shows usage" {
    run "${V0_SELF_DEBUG}" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "v0 self debug"
}

@test "v0-self-debug: -h shows usage" {
    run "${V0_SELF_DEBUG}" -h
    assert_success
    assert_output --partial "Usage:"
}

@test "v0-self-debug: no arguments shows error" {
    run "${V0_SELF_DEBUG}"
    assert_failure
    assert_output --partial "Error: No operation specified"
    assert_output --partial "Usage:"
}

# ============================================================================
# Basic Report Generation Tests
# ============================================================================

@test "v0-self-debug: generates report for existing operation" {
    create_mock_operation "test-feature" "feature" "building" "running"

    run "${V0_SELF_DEBUG}" test-feature --stdout
    assert_success
    assert_output --partial "v0-debug-report: true"
    assert_output --partial "operation: test-feature"
    assert_output --partial "type: feature"
    assert_output --partial "phase: building"
}

@test "v0-self-debug: report contains operation state" {
    create_mock_operation "test-feature" "feature" "init" "running"

    run "${V0_SELF_DEBUG}" test-feature --stdout
    assert_success
    assert_output --partial "## Operation State"
    assert_output --partial '"name": "test-feature"'
}

@test "v0-self-debug: report contains git state" {
    create_mock_operation "test-feature" "feature" "init" "running"

    run "${V0_SELF_DEBUG}" test-feature --stdout
    assert_success
    assert_output --partial "## Git State"
    assert_output --partial "### Main Repository"
}

@test "v0-self-debug: report contains operation logs" {
    create_mock_operation "test-feature" "feature" "init" "running"

    run "${V0_SELF_DEBUG}" test-feature --stdout
    assert_success
    assert_output --partial "## Operation Logs"
    assert_output --partial "Test log entry for test-feature"
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "v0-self-debug: fails gracefully for unknown operation" {
    run "${V0_SELF_DEBUG}" nonexistent --stdout
    assert_failure
    assert_output --partial "Error: Operation not found"
    assert_output --partial "nonexistent"
}

@test "v0-self-debug: handles missing log files gracefully" {
    create_mock_operation "no-logs" "feature" "init" "running"
    rm -rf "${TEST_TEMP_DIR}/project/.v0/build/operations/no-logs/logs"

    run "${V0_SELF_DEBUG}" no-logs --stdout
    assert_success
    assert_output --partial "No logs directory found"
}

@test "v0-self-debug: handles unknown option" {
    run "${V0_SELF_DEBUG}" --unknown-option
    assert_failure
    assert_output --partial "Unknown option"
}

# ============================================================================
# Worker Debug Tests
# ============================================================================

@test "v0-self-debug: fix worker debug collects worker state" {
    create_mock_worker_state "fix"

    run "${V0_SELF_DEBUG}" fix --stdout
    assert_success
    assert_output --partial "# Debug Report: Fix Worker"
    assert_output --partial "## Fix Worker State"
    assert_output --partial "### Process Info"
}

@test "v0-self-debug: chore worker debug collects worker state" {
    create_mock_worker_state "chore"

    run "${V0_SELF_DEBUG}" chore --stdout
    assert_success
    assert_output --partial "# Debug Report: Chore Worker"
    assert_output --partial "## Chore Worker State"
}

@test "v0-self-debug: fix debug includes backoff state" {
    create_mock_worker_state "fix"

    run "${V0_SELF_DEBUG}" fix --stdout
    assert_success
    assert_output --partial "### Backoff State"
    assert_output --partial "Error flag:"
}

# ============================================================================
# Merge Queue Debug Tests
# ============================================================================

@test "v0-self-debug: mergeq debug collects queue state" {
    create_mock_mergeq_state

    run "${V0_SELF_DEBUG}" mergeq --stdout
    assert_success
    assert_output --partial "# Debug Report: Merge Queue"
    assert_output --partial "## Merge Queue State"
    assert_output --partial "queue.json"
}

@test "v0-self-debug: merge is alias for mergeq" {
    create_mock_mergeq_state

    run "${V0_SELF_DEBUG}" merge --stdout
    assert_success
    assert_output --partial "# Debug Report: Merge Queue"
}

@test "v0-self-debug: mergeq shows operations in merge phase" {
    create_mock_mergeq_state
    create_mock_operation "merging-op" "feature" "merging" "running"

    run "${V0_SELF_DEBUG}" mergeq --stdout
    assert_success
    assert_output --partial "## Operations in Merge Phase"
    assert_output --partial "merging-op"
}

# ============================================================================
# Nudge Debug Tests
# ============================================================================

@test "v0-self-debug: nudge debug collects daemon state" {
    run "${V0_SELF_DEBUG}" nudge --stdout
    assert_success
    assert_output --partial "# Debug Report: Nudge Daemon"
    assert_output --partial "## Nudge Daemon State"
    assert_output --partial "### Active Tmux Sessions"
}

# ============================================================================
# Output Options Tests
# ============================================================================

@test "v0-self-debug: --output writes to custom path" {
    create_mock_operation "test-feature" "feature" "init" "running"
    local output_file="${TEST_TEMP_DIR}/custom-debug.md"

    run "${V0_SELF_DEBUG}" test-feature --output "${output_file}"
    assert_success
    assert [ -f "${output_file}" ]
    run cat "${output_file}"
    assert_output --partial "v0-debug-report: true"
}

@test "v0-self-debug: default output creates file in debug dir" {
    create_mock_operation "test-feature" "feature" "init" "running"

    run "${V0_SELF_DEBUG}" test-feature
    assert_success
    assert_output --partial "Debug report generated:"
    assert_output --partial ".v0/build/debug/"
    assert_output --partial "test-feature.md"
}

@test "v0-self-debug: --stdout prints to stdout" {
    create_mock_operation "test-feature" "feature" "init" "running"

    run "${V0_SELF_DEBUG}" test-feature --stdout
    assert_success
    assert_output --partial "---"
    assert_output --partial "v0-debug-report: true"
    # Should NOT contain file output message
    refute_output --partial "Debug report generated:"
}

@test "v0-self-debug: --verbose includes more logs" {
    create_mock_operation "test-feature" "feature" "init" "running"
    echo "[$(date)] test-feature: test entry" > "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"

    run "${V0_SELF_DEBUG}" test-feature --verbose --stdout
    assert_success
    assert_output --partial "## Verbose Logs"
}

# ============================================================================
# Cross-cutting Context Tests
# ============================================================================

@test "v0-self-debug: includes merge context for queued operations" {
    create_mock_operation "queued-op" "feature" "building" "running"
    update_operation_state "queued-op" '.merge_queued = true'
    create_mock_mergeq_state

    run "${V0_SELF_DEBUG}" queued-op --stdout
    assert_success
    assert_output --partial "## Merge Queue State"
}

@test "v0-self-debug: includes dependency context" {
    create_mock_operation "dep-op" "feature" "blocked" "waiting"
    update_operation_state "dep-op" '.after = "auth-op"'
    create_mock_operation "auth-op" "feature" "building" "running"

    run "${V0_SELF_DEBUG}" dep-op --stdout
    assert_success
    assert_output --partial "## Related Operations"
    assert_output --partial "auth-op"
}

@test "v0-self-debug: includes v0.log context" {
    create_mock_operation "logged-op" "feature" "init" "running"
    echo "[2026-01-18T03:00:00Z] logged-op: Test log entry" > "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"

    run "${V0_SELF_DEBUG}" logged-op --stdout
    assert_success
    assert_output --partial "## v0.log Context"
    assert_output --partial "logged-op: Test log entry"
}

# ============================================================================
# Most Recent Operation Tests
# ============================================================================

@test "v0-self-debug: plan debugs most recent plan operation" {
    create_mock_operation "old-plan" "plan" "completed" "success"
    sleep 0.1
    create_mock_operation "new-plan" "plan" "failed" "error"

    run "${V0_SELF_DEBUG}" plan --stdout
    assert_success
    assert_output --partial "operation: new-plan"
}

@test "v0-self-debug: decompose debugs most recent decomposing operation" {
    create_mock_operation "decompose-fail" "feature" "decomposing" "error"

    run "${V0_SELF_DEBUG}" decompose --stdout
    assert_success
    assert_output --partial "operation: decompose-fail"
}

@test "v0-self-debug: reports error when no plan operation exists" {
    # Ensure operations directory exists but has no plan operations
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"

    run "${V0_SELF_DEBUG}" plan --stdout
    assert_failure
    # The error message goes to stderr, which is captured by run
    assert_output --partial "Could not find operation"
}

# ============================================================================
# Report Format Tests
# ============================================================================

@test "v0-self-debug: report has correct frontmatter" {
    create_mock_operation "test-op" "feature" "building" "running"

    run "${V0_SELF_DEBUG}" test-op --stdout
    assert_success
    # Check YAML frontmatter markers
    assert_output --partial "---"
    assert_output --partial "v0-debug-report: true"
    assert_output --partial "generated_at:"
    assert_output --partial "machine:"
}

@test "v0-self-debug: report contains section markers" {
    create_mock_operation "test-op" "feature" "building" "running"

    run "${V0_SELF_DEBUG}" test-op --stdout
    assert_success
    assert_output --partial "<!-- section: operation-state -->"
    assert_output --partial "<!-- section: operation-logs -->"
    assert_output --partial "<!-- section: git-state -->"
}

# ============================================================================
# Log Filtering Tests
# ============================================================================

@test "v0-self-debug: filters debug report frontmatter from logs" {
    create_mock_operation "test-op" "feature" "building" "running"
    local logs_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/logs"

    # Create a log that contains debug report frontmatter (simulating tmux capture)
    cat > "${logs_dir}/feature.log" <<'EOF'
Normal log line 1
---
v0-debug-report: true
operation: old-debug
type: unknown
phase: unknown
status: unknown
machine: test-machine
generated_at: 2026-01-18T00:00:00Z
---
Normal log line 2
EOF

    run "${V0_SELF_DEBUG}" test-op --stdout
    assert_success
    # Should contain normal log lines
    assert_output --partial "Normal log line 1"
    assert_output --partial "Normal log line 2"
    # Should NOT contain debug report frontmatter from the log
    refute_output --partial "v0-debug-report: true"$'\n'"operation: old-debug"
}

@test "v0-self-debug: filter_debug_frontmatter removes frontmatter lines" {
    source "${PROJECT_ROOT}/lib/v0-common.sh"
    source "${PROJECT_ROOT}/lib/debug-common.sh"

    local input="Normal line
---
v0-debug-report: true
operation: test
type: feature
phase: building
status: running
machine: localhost
generated_at: 2026-01-18T00:00:00Z
---
Another normal line"

    local filtered
    filtered=$(echo "${input}" | filter_debug_frontmatter)

    [[ "${filtered}" == *"Normal line"* ]]
    [[ "${filtered}" == *"Another normal line"* ]]
    [[ "${filtered}" != *"v0-debug-report:"* ]]
    [[ "${filtered}" != *"operation: test"* ]]
}
