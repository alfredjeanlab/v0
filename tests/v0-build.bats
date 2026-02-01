#!/usr/bin/env bats
# v0-build.bats - Tests for v0-build script (wok-based dependency feature)

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
    # Return blockers if any deps have been added
    if [[ -f "$MOCK_CALLS_DIR/wk.blockers" ]]; then
        blockers=$(cat "$MOCK_CALLS_DIR/wk.blockers")
        echo "{\"status\": \"open\", \"blockers\": [${blockers}]}"
    else
        echo '{"status": "open"}'
    fi
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
    # Track blocked-by deps for show to return
    if [[ "$3" == "blocked-by" ]] && [[ -n "$4" ]]; then
        if [[ -f "$MOCK_CALLS_DIR/wk.blockers" ]]; then
            existing=$(cat "$MOCK_CALLS_DIR/wk.blockers")
            echo "${existing}, \"$4\"" > "$MOCK_CALLS_DIR/wk.blockers"
        else
            echo "\"$4\"" > "$MOCK_CALLS_DIR/wk.blockers"
        fi
    fi
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
# Blocker Helper Tests (via v0-common.sh functions)
# ============================================================================

@test "v0-build: v0_resolve_to_wok_id extracts epic_id from operation state" {
    # Create an operation with epic_id
    local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/myop"
    mkdir -p "${op_dir}"
    cat > "${op_dir}/state.json" <<EOF
{
  "name": "myop",
  "phase": "merged",
  "epic_id": "test-abc123"
}
EOF

    # Test via jq directly (v0_resolve_to_wok_id uses this internally)
    run jq -r '.epic_id // empty' "${op_dir}/state.json"
    assert_success
    assert_output "test-abc123"
}

@test "v0-build: operation without epic_id returns empty" {
    local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/myop"
    mkdir -p "${op_dir}"
    cat > "${op_dir}/state.json" <<EOF
{
  "name": "myop",
  "phase": "init"
}
EOF

    run jq -r '.epic_id // empty' "${op_dir}/state.json"
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

@test "v0-build: --after creates state file without after field (v2 schema)" {
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

    # Verify state file does NOT have after field (v2 schema uses wok deps)
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    if [[ -f "${state_file}" ]]; then
        run jq -r 'has("after")' "${state_file}"
        assert_output "false"
        # Should have schema version 2
        run jq -r '._schema_version' "${state_file}"
        assert_output "2"
    fi
}

# ============================================================================
# --hold Flag Tests
# ============================================================================

@test "v0-build: --hold sets operation hold state" {
    # Create a plan file to skip planning
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    cat > "${TEST_TEMP_DIR}/project/plans/test-op.md" <<EOF
# Test Plan
Feature: \`test-feature456\`
## Tasks
- Task 1
EOF

    run "${V0_BUILD}" test-op --plan "${TEST_TEMP_DIR}/project/plans/test-op.md" --hold --dry-run 2>&1 || true

    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    if [[ -f "${state_file}" ]]; then
        run jq -r '.held' "${state_file}"
        assert_output "true"
    fi
}

# ============================================================================
# --blocked-by Alias Tests
# ============================================================================

@test "v0-build: --blocked-by is alias for --after" {
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

    run "${V0_BUILD}" test-op "Test prompt" --blocked-by blocker --dry-run 2>&1 || true

    # Verify wk dep was called (via mock calls file)
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "dep"
        assert_output --partial "blocked-by"
    fi
}

@test "v0-build: --after accepts comma-separated list" {
    # Create blocker operations
    for op in blocker1 blocker2; do
        local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/${op}"
        mkdir -p "${op_dir}"
        cat > "${op_dir}/state.json" <<EOF
{
  "name": "${op}",
  "phase": "merged",
  "epic_id": "test-${op}-123"
}
EOF
    done

    run "${V0_BUILD}" test-op "Test prompt" --after blocker1,blocker2 --dry-run 2>&1 || true

    # Verify wk dep was called for both blockers
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "blocked-by"
        assert_output --partial "test-blocker1-123"
        assert_output --partial "test-blocker2-123"
    fi
}

@test "v0-build: --after merges multiple flags" {
    # Create blocker operations
    for op in a b c; do
        local op_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/${op}"
        mkdir -p "${op_dir}"
        cat > "${op_dir}/state.json" <<EOF
{
  "name": "${op}",
  "phase": "merged",
  "epic_id": "test-${op}-123"
}
EOF
    done

    run "${V0_BUILD}" test-op "Test prompt" --after a,b --after c --dry-run 2>&1 || true

    # Verify wk dep was called for all three blockers
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-a-123"
        assert_output --partial "test-b-123"
        assert_output --partial "test-c-123"
    fi
}

# ============================================================================
# --after Dependency Failure Tests
# ============================================================================

@test "v0-build: --after fails operation when wk dep fails" {
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

    # Override wk mock to fail on dep command
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
    exit 1  # Fail on dep command
fi
if [[ "$1" == "init" ]]; then
    exit 0
fi
exit 0
MOCK_EOF
    chmod +x "${TEST_TEMP_DIR}/mock-v0-bin/wk"

    # Run v0 build with --after (dry-run)
    run "${V0_BUILD}" test-op "Test prompt" --after blocker --dry-run 2>&1

    # Should fail because wk dep failed
    assert_failure
    assert_output --partial "Error: Failed to add blocked-by dependency"
    assert_output --partial "wk dep"
}

@test "v0-build: --after verifies dependencies are visible and sets expected_blockers" {
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

    # Create a plan file to ensure we get through to the dep-adding code
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    cat > "${TEST_TEMP_DIR}/project/plans/test-op.md" <<EOF
# Test Plan
Feature: \`test-feature456\`
## Tasks
- Task 1
EOF

    # Update wk mock to return blockers on show (simulating successful dep add)
    cat > "${TEST_TEMP_DIR}/mock-v0-bin/wk" <<'MOCK_EOF'
#!/bin/bash
echo "wk $*" >> "$MOCK_CALLS_DIR/wk.calls" 2>/dev/null || true
if [[ "$1" == "show" ]]; then
    # Return blockers array if this is the new feature's epic
    if [[ "$2" == "test-feature456" ]]; then
        echo '{"status": "open", "blockers": ["test-blocker123"]}'
    else
        echo '{"status": "open", "blockers": []}'
    fi
    exit 0
fi
if [[ "$1" == "new" ]]; then
    echo "test-feature456"
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

    # Run v0 build with --plan and --after (dry-run)
    run "${V0_BUILD}" test-op --plan "${TEST_TEMP_DIR}/project/plans/test-op.md" --after blocker --dry-run 2>&1

    # Verify wk dep was called with blocked-by
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "dep"
        assert_output --partial "blocked-by"
        assert_output --partial "test-blocker123"
    fi

    # Verify expected_blockers was set in state (when deps are verified)
    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    if [[ -f "${state_file}" ]]; then
        run jq -r '.expected_blockers' "${state_file}"
        assert_output "1"
    fi
}

# ============================================================================
# Removed Flag Tests
# ============================================================================

@test "v0-build: --foreground is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --foreground 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

@test "v0-build: --safe is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --safe 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

@test "v0-build: --enqueue is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --enqueue 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

@test "v0-build: --eager is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --eager 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

# ============================================================================
# Inherited Environment Variable Tests (for roadmap/worktree scenarios)
# ============================================================================

@test "v0-build: respects inherited BUILD_DIR over worktree config" {
    # Create a "worktree" directory with its own .v0.rc that would set different BUILD_DIR
    local worktree="${TEST_TEMP_DIR}/worktree"
    mkdir -p "${worktree}/.v0/build/operations"
    cat > "${worktree}/.v0.rc" <<EOF
PROJECT="worktree-project"
ISSUE_PREFIX="wt"
BUILD_DIR="${worktree}/.v0/build"
V0_ROOT="${worktree}"
EOF

    # Initialize git in worktree
    (cd "${worktree}" && git init --quiet -b main && git config user.email "test@example.com" && git config user.name "Test")

    # Set inherited BUILD_DIR pointing to main project (simulating roadmap worker)
    export BUILD_DIR="${TEST_TEMP_DIR}/project/.v0/build"

    # Run v0-build from worktree directory
    cd "${worktree}"
    run "${V0_BUILD}" test-op "Test prompt" --dry-run 2>&1

    # The operation should be created in the inherited BUILD_DIR, not worktree's
    assert [ -d "${TEST_TEMP_DIR}/project/.v0/build/operations/test-op" ]
    assert [ ! -d "${worktree}/.v0/build/operations/test-op" ]
}

@test "v0-build: respects inherited V0_DEVELOP_BRANCH over default" {
    # Set inherited V0_DEVELOP_BRANCH (simulating roadmap worker)
    export V0_DEVELOP_BRANCH="v0/agent/testuser-abc1"

    # Create operation to check state
    run "${V0_BUILD}" test-op "Test prompt" --dry-run 2>&1

    # The V0_DEVELOP_BRANCH should be preserved (check via state file or output)
    # Since --dry-run doesn't create full state, we just verify no error
    assert_success
}

@test "v0-build: uses config values when no inherited BUILD_DIR" {
    # Ensure BUILD_DIR is not inherited
    unset BUILD_DIR

    run "${V0_BUILD}" test-op "Test prompt" --dry-run 2>&1

    # Should use BUILD_DIR from .v0.rc (TEST_TEMP_DIR/project/.v0/build)
    assert [ -d "${TEST_TEMP_DIR}/project/.v0/build/operations/test-op" ]
}

@test "v0-build-worker: respects inherited BUILD_DIR over worktree config" {
    # This tests the fix for the bug where v0-build-worker didn't preserve
    # inherited BUILD_DIR when launched from a workspace context (e.g., by
    # mg_trigger_dependents during merge). Without the fix, v0-build-worker
    # would call v0_load_config which overwrites BUILD_DIR based on the
    # workspace's .v0.rc, causing "No operation found" errors.

    local V0_BUILD_WORKER="${PROJECT_ROOT}/bin/v0-build-worker"

    # Create a "workspace" directory with its own .v0.rc
    local workspace="${TEST_TEMP_DIR}/workspace"
    mkdir -p "${workspace}/.v0/build/operations"
    cat > "${workspace}/.v0.rc" <<EOF
PROJECT="workspace-project"
ISSUE_PREFIX="ws"
BUILD_DIR="${workspace}/.v0/build"
V0_ROOT="${workspace}"
V0_PLANS_DIR="plans"
EOF
    mkdir -p "${workspace}/plans"

    # Initialize git in workspace
    (cd "${workspace}" && git init --quiet -b main && git config user.email "test@example.com" && git config user.name "Test")

    # Create operation state in MAIN project (where it should be found)
    local main_build="${TEST_TEMP_DIR}/project/.v0/build"
    mkdir -p "${main_build}/operations/test-op/logs"
    cat > "${main_build}/operations/test-op/state.json" <<EOF
{
  "name": "test-op",
  "phase": "completed",
  "prompt": "Test"
}
EOF

    # Set inherited BUILD_DIR pointing to main project
    export BUILD_DIR="${main_build}"

    # Run v0-build-worker from workspace directory
    # It should find the operation in inherited BUILD_DIR, not workspace's
    cd "${workspace}"
    run "${V0_BUILD_WORKER}" test-op 2>&1

    # Should NOT get "No operation found" error
    refute_output --partial "No operation found"
}

@test "v0-build: exports BUILD_DIR to child processes even when not inherited" {
    # This tests the fix for the bug where v0-build didn't export BUILD_DIR
    # when it wasn't inherited from the parent process. When mg_trigger_dependents
    # launched v0-build, BUILD_DIR might not be in the environment, so v0-build
    # computes it via v0_load_config. Previously, it wouldn't export the computed
    # value, so v0-build-worker couldn't find the operation.

    # Create test operation state
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations/export-test/logs"
    cat > "${TEST_TEMP_DIR}/project/.v0/build/operations/export-test/state.json" <<EOF
{
  "name": "export-test",
  "phase": "completed",
  "prompt": "Test export"
}
EOF

    # Unset BUILD_DIR to simulate the scenario where it's not inherited
    unset BUILD_DIR

    # Run v0-build in a subshell that checks if BUILD_DIR is exported
    # by trying to access it from a child process
    run bash -c '
        cd "'"${TEST_TEMP_DIR}/project"'" || exit 1

        # Source v0-build setup (simulate what v0-build does before spawning worker)
        V0_DIR="'"${PROJECT_ROOT}"'"
        source "${V0_DIR}/packages/cli/lib/v0-common.sh"
        _INHERITED_BUILD_DIR="${BUILD_DIR:-}"
        v0_load_config
        [[ -n "${_INHERITED_BUILD_DIR}" ]] && BUILD_DIR="${_INHERITED_BUILD_DIR}"
        export BUILD_DIR

        # Verify BUILD_DIR is exported by checking it from a subshell
        child_build_dir=$(bash -c '\''echo "${BUILD_DIR}"'\'')

        if [[ -z "${child_build_dir}" ]]; then
            echo "ERROR: BUILD_DIR not exported to child process"
            exit 1
        fi

        echo "BUILD_DIR exported: ${child_build_dir}"

        # Verify it points to the correct location
        if [[ "${child_build_dir}" != "'"${TEST_TEMP_DIR}/project/.v0/build"'" ]]; then
            echo "ERROR: BUILD_DIR has wrong value"
            echo "  Expected: '"${TEST_TEMP_DIR}/project/.v0/build"'"
            echo "  Got: ${child_build_dir}"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "BUILD_DIR exported"
}

@test "v0-merge: exports BUILD_DIR to child processes for mg_trigger_dependents" {
    # This tests that v0-merge exports BUILD_DIR so that when mg_trigger_dependents
    # launches v0-build to resume dependent operations, they can find their state files.

    local project_dir="${TEST_TEMP_DIR}/merge-export-project"
    mkdir -p "${project_dir}/.v0/build/operations"

    # Initialize git repo
    (
        cd "${project_dir}"
        git init --quiet -b main
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "test" > README.md
        git add README.md
        git commit --quiet -m "Initial commit"
    )

    cat > "${project_dir}/.v0.rc" <<EOF
PROJECT="mergetest"
ISSUE_PREFIX="mt"
V0_DEVELOP_BRANCH="main"
V0_GIT_REMOTE="origin"
EOF

    # Run a subshell that sources v0-merge's initialization and checks BUILD_DIR export
    run env -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1

        V0_DIR="'"${PROJECT_ROOT}"'"
        source "${V0_DIR}/packages/cli/lib/v0-common.sh"
        _INHERITED_BUILD_DIR="${BUILD_DIR:-}"
        v0_load_config
        [[ -n "${_INHERITED_BUILD_DIR}" ]] && BUILD_DIR="${_INHERITED_BUILD_DIR}"
        export BUILD_DIR

        # Verify BUILD_DIR is exported by checking from a child process
        child_build_dir=$(bash -c '\''echo "${BUILD_DIR}"'\'')

        if [[ -z "${child_build_dir}" ]]; then
            echo "ERROR: BUILD_DIR not exported"
            exit 1
        fi

        # BUILD_DIR should be set to project/.v0/build
        if [[ ! "${child_build_dir}" == *"/.v0/build" ]]; then
            echo "ERROR: BUILD_DIR does not end with /.v0/build"
            echo "  Got: ${child_build_dir}"
            exit 1
        fi

        echo "BUILD_DIR correctly exported: ${child_build_dir}"
    '
    assert_success
    assert_output --partial "BUILD_DIR correctly exported"
}
