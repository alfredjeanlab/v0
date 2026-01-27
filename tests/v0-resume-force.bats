#!/usr/bin/env bats
# v0-resume-force.bats - Tests for v0 resume --force flag

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

    # Set up mock data directory for wk
    export MOCK_DATA_DIR="${TEST_TEMP_DIR}/mock-data"
    mkdir -p "${MOCK_DATA_DIR}/wk"

    # Create mock wk that supports blocker queries
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'MOCK_EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true

case "$1" in
    "show")
        issue_id="$2"
        # Check for mock data file
        if [[ -n "${MOCK_DATA_DIR:-}" ]]; then
            mock_file="${MOCK_DATA_DIR}/wk/${issue_id}.json"
            if [[ -f "${mock_file}" ]]; then
                cat "${mock_file}"
                exit 0
            fi
        fi
        # Default: return basic JSON with no blockers
        echo '{"status": "open", "blockers": []}'
        exit 0
        ;;
    "new")
        echo "test-newissue"
        exit 0
        ;;
    "init"|"list"|"dep"|"edit"|"label")
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    export PATH="${TEST_TEMP_DIR}/mock-v0-bin:${PATH}"
}

teardown() {
    # Kill any running workers before cleanup
    if [[ -n "${TEST_TEMP_DIR:-}" ]]; then
        # Find and kill any worker processes
        local op_dir
        for op_dir in "${TEST_TEMP_DIR}/project/.v0/build/operations/"*/; do
            if [[ -d "${op_dir}" ]]; then
                local state_file="${op_dir}/state.json"
                if [[ -f "${state_file}" ]]; then
                    local pid
                    pid=$(jq -r '.worker_pid // empty' "${state_file}" 2>/dev/null || true)
                    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                        kill -9 "${pid}" 2>/dev/null || true
                        # Wait for process to terminate
                        for _ in 1 2 3 4 5; do
                            kill -0 "${pid}" 2>/dev/null || break
                            sleep 0.1
                        done
                    fi
                fi
            fi
        done
    fi

    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"
    if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# Helper to create a blocked operation
create_blocked_operation() {
    local op_name="$1"
    local blocker_id="$2"
    local epic_id="${3:-test-epic123}"

    # Create operation state
    local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/${op_name}"
    mkdir -p "${op_dir}/logs"
    cat > "${op_dir}/state.json" <<EOF
{
  "name": "${op_name}",
  "phase": "queued",
  "epic_id": "${epic_id}",
  "prompt": "Test operation",
  "created_at": "2026-01-15T10:00:00Z",
  "labels": [],
  "plan_file": null,
  "tmux_session": null,
  "worktree": null,
  "current_issue": null,
  "completed": [],
  "merge_queued": true,
  "merge_status": null,
  "merged_at": null,
  "merge_error": null,
  "worker_pid": null,
  "worker_log": null,
  "worker_started_at": null,
  "_schema_version": 2
}
EOF

    # Set up mock wk data for the epic (with blocker)
    cat > "${MOCK_DATA_DIR}/wk/${epic_id}.json" <<EOF
{
  "id": "${epic_id}",
  "status": "open",
  "blockers": ["${blocker_id}"]
}
EOF

    # Set up mock wk data for the blocker (status: open)
    cat > "${MOCK_DATA_DIR}/wk/${blocker_id}.json" <<EOF
{
  "id": "${blocker_id}",
  "status": "open",
  "labels": ["plan:${op_name}-blocker"]
}
EOF
}

# ============================================================================
# --force Flag Tests
# ============================================================================

@test "v0 resume shows error when blocked (exit 1)" {
    create_blocked_operation "test-op" "test-blocker456"

    run "${V0_BUILD}" --resume test-op 2>&1
    assert_failure
    [ "$status" -eq 1 ]
    assert_output --partial "Error: Operation is blocked by"
    assert_output --partial "--force"
}

@test "v0 resume --force bypasses blocker with warning" {
    create_blocked_operation "test-op" "test-blocker456"

    run "${V0_BUILD}" --resume --force test-op 2>&1
    # Should succeed (not blocked)
    assert_success
    assert_output --partial "Warning: Ignoring blocker"
}

@test "v0 resume -f is alias for --force" {
    create_blocked_operation "test-op" "test-blocker456"

    run "${V0_BUILD}" --resume -f test-op 2>&1
    assert_success
    assert_output --partial "Ignoring blocker"
}

@test "v0 resume blocked error message suggests --force" {
    create_blocked_operation "test-op" "test-blocker456"

    run "${V0_BUILD}" --resume test-op 2>&1
    assert_failure
    assert_output --partial "v0 resume --force test-op"
}

@test "v0 resume with no blockers succeeds without --force" {
    local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op"
    mkdir -p "${op_dir}/logs"
    cat > "${op_dir}/state.json" <<EOF
{
  "name": "test-op",
  "phase": "queued",
  "epic_id": "test-epic123",
  "prompt": "Test operation",
  "created_at": "2026-01-15T10:00:00Z",
  "_schema_version": 2
}
EOF

    # Set up mock wk data with no blockers
    cat > "${MOCK_DATA_DIR}/wk/test-epic123.json" <<EOF
{
  "id": "test-epic123",
  "status": "open",
  "blockers": []
}
EOF

    run "${V0_BUILD}" --resume test-op 2>&1
    # Should succeed (not blocked)
    assert_success
    refute_output --partial "blocked"
}

@test "v0-build --help shows --force option" {
    run "${V0_BUILD}" --help 2>&1 || true
    assert_output --partial "--force"
    assert_output --partial "Bypass blockers"
}

@test "v0 resume --force sets ignore_blockers in state for worker" {
    create_blocked_operation "test-op" "test-blocker456"

    run "${V0_BUILD}" --resume --force test-op 2>&1
    assert_success

    # Verify ignore_blockers was set in state
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    run jq -r '.ignore_blockers' "${state_file}"
    assert_output "true"
}

# ============================================================================
# Resume Cancelled Operations Tests
# ============================================================================

# Helper to create a cancelled operation
create_cancelled_operation() {
    local op_name="$1"
    local epic_id="${2:-test-epic123}"

    local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/${op_name}"
    mkdir -p "${op_dir}/logs"
    cat > "${op_dir}/state.json" <<EOF
{
  "name": "${op_name}",
  "phase": "cancelled",
  "epic_id": "${epic_id}",
  "prompt": "Test operation",
  "created_at": "2026-01-15T10:00:00Z",
  "labels": [],
  "plan_file": "plans/${op_name}.md",
  "tmux_session": null,
  "worktree": null,
  "current_issue": null,
  "completed": [],
  "merge_queued": true,
  "merge_status": null,
  "merged_at": null,
  "merge_error": null,
  "worker_pid": null,
  "worker_log": null,
  "worker_started_at": null,
  "_schema_version": 2
}
EOF

    # Set up mock wk data for the epic (no blockers by default)
    cat > "${MOCK_DATA_DIR}/wk/${epic_id}.json" <<EOF
{
  "id": "${epic_id}",
  "status": "open",
  "blockers": []
}
EOF
}

@test "v0 resume clears cancelled state and resumes" {
    create_cancelled_operation "test-op"

    run "${V0_BUILD}" --resume test-op 2>&1
    assert_success
    assert_output --partial "Clearing cancelled state"
    assert_output --partial "Resuming"

    # Verify phase was updated (should be queued since epic_id exists)
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    run jq -r '.phase' "${state_file}"
    assert_output "queued"
}

@test "v0 resume cancelled with blockers clears cancelled but shows blocked error" {
    create_cancelled_operation "test-op" "test-epic123"

    # Add blocker to the operation
    cat > "${MOCK_DATA_DIR}/wk/test-epic123.json" <<EOF
{
  "id": "test-epic123",
  "status": "open",
  "blockers": ["test-blocker789"]
}
EOF
    cat > "${MOCK_DATA_DIR}/wk/test-blocker789.json" <<EOF
{
  "id": "test-blocker789",
  "status": "open",
  "labels": ["plan:blocker-op"]
}
EOF

    run "${V0_BUILD}" --resume test-op 2>&1
    # Should fail due to blocker, but cancelled state should be cleared first
    assert_failure
    assert_output --partial "Clearing cancelled state"
    assert_output --partial "blocked by"

    # Verify phase was updated from cancelled to queued (before blocker check)
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    run jq -r '.phase' "${state_file}"
    assert_output "queued"
}

@test "v0 resume cancelled with blockers and --force bypasses blocker" {
    create_cancelled_operation "test-op" "test-epic123"

    # Add blocker to the operation
    cat > "${MOCK_DATA_DIR}/wk/test-epic123.json" <<EOF
{
  "id": "test-epic123",
  "status": "open",
  "blockers": ["test-blocker789"]
}
EOF
    cat > "${MOCK_DATA_DIR}/wk/test-blocker789.json" <<EOF
{
  "id": "test-blocker789",
  "status": "open",
  "labels": ["plan:blocker-op"]
}
EOF

    run "${V0_BUILD}" --resume --force test-op 2>&1
    assert_success
    assert_output --partial "Clearing cancelled state"
    assert_output --partial "Ignoring blocker"
}
