#!/usr/bin/env bats
# Tests for v0-merge - Lock Management & Conflict Detection

load '../helpers/test_helper'

# Setup for merge tests
setup() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "${TEST_TEMP_DIR}/project" || return 1
    export ORIGINAL_PATH="${PATH}"

    # Create valid v0 config
    create_v0rc "testproject" "testp"

    # Export paths
    export V0_ROOT="${TEST_TEMP_DIR}/project"
    export PROJECT="testproject"
    export ISSUE_PREFIX="testp"
    export BUILD_DIR="${TEST_TEMP_DIR}/project/.v0/build"
    export LOCKFILE="${BUILD_DIR}/.merge.lock"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"

    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# acquire_lock() / release_lock() tests
# ============================================================================

acquire_lock() {
    if [ -f "${LOCKFILE}" ]; then
        local holder
        holder=$(cat "${LOCKFILE}")
        echo "Error: Merge lock held by: ${holder}" >&2
        return 1
    fi
    mkdir -p "${BUILD_DIR}"
    echo "test-branch (pid $$)" > "${LOCKFILE}"
}

release_lock() {
    rm -f "${LOCKFILE}"
}

@test "acquire_lock creates lock file with PID" {
    run acquire_lock
    assert_success
    assert_file_exists "${LOCKFILE}"
    run cat "${LOCKFILE}"
    assert_output --partial "pid $$"
}

@test "acquire_lock fails when lock held by another process" {
    # Create existing lock
    mkdir -p "${BUILD_DIR}"
    echo "other-branch (pid 12345)" > "${LOCKFILE}"

    run acquire_lock
    assert_failure
    assert_output --partial "lock held by"
}

@test "release_lock removes lock file" {
    mkdir -p "${BUILD_DIR}"
    echo "test-branch (pid $$)" > "${LOCKFILE}"
    assert_file_exists "${LOCKFILE}"

    release_lock
    assert_file_not_exists "${LOCKFILE}"
}

@test "release_lock succeeds even if no lock exists" {
    run release_lock
    assert_success
}

@test "acquire_lock after release succeeds" {
    acquire_lock
    release_lock

    run acquire_lock
    assert_success
}

# ============================================================================
# has_conflicts() tests (with mock git)
# ============================================================================

# Mock has_conflicts function
has_conflicts() {
    local branch="$1"
    if [ "${MOCK_GIT_CONFLICT}" = "true" ]; then
        return 0  # Has conflicts
    fi
    return 1  # No conflicts
}

@test "has_conflicts returns true when git reports conflict" {
    export MOCK_GIT_CONFLICT=true

    run has_conflicts "test-branch"
    assert_success  # success means conflicts exist
}

@test "has_conflicts returns false when merge is clean" {
    export MOCK_GIT_CONFLICT=false

    run has_conflicts "test-branch"
    assert_failure  # failure means no conflicts
}

# ============================================================================
# worktree_has_conflicts() tests
# ============================================================================

# Check if worktree has unresolved conflicts
worktree_has_conflicts() {
    local worktree="$1"
    local status_output="${MOCK_GIT_STATUS:-}"

    # Check for conflict markers in status
    echo "${status_output}" | grep -q '^UU\|^AA\|^DD'
}

@test "worktree_has_conflicts detects UU conflicts" {
    export MOCK_GIT_STATUS="UU conflicted-file.txt"

    run worktree_has_conflicts "${TEST_TEMP_DIR}/worktree"
    assert_success
}

@test "worktree_has_conflicts detects AA conflicts" {
    export MOCK_GIT_STATUS="AA both-added.txt"

    run worktree_has_conflicts "${TEST_TEMP_DIR}/worktree"
    assert_success
}

@test "worktree_has_conflicts detects DD conflicts" {
    export MOCK_GIT_STATUS="DD both-deleted.txt"

    run worktree_has_conflicts "${TEST_TEMP_DIR}/worktree"
    assert_success
}

@test "worktree_has_conflicts returns false for clean status" {
    export MOCK_GIT_STATUS="M  modified-file.txt"

    run worktree_has_conflicts "${TEST_TEMP_DIR}/worktree"
    assert_failure
}

@test "worktree_has_conflicts returns false for empty status" {
    export MOCK_GIT_STATUS=""

    run worktree_has_conflicts "${TEST_TEMP_DIR}/worktree"
    assert_failure
}

# ============================================================================
# update_operation_state() tests
# ============================================================================

update_operation_state() {
    local branch="$1"
    # Try full branch name first (e.g., "my-feature")
    local state_file="${BUILD_DIR}/operations/${branch}/state.json"
    if [ ! -f "${state_file}" ]; then
        # Branch may have prefix like "feature/my-feature" - try just the basename
        local op_name
        op_name=$(basename "${branch}")
        state_file="${BUILD_DIR}/operations/${op_name}/state.json"
        if [ ! -f "${state_file}" ]; then
            return 0  # No operation state to update
        fi
    fi

    local merged_at
    merged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp
    tmp=$(mktemp)
    jq ".merge_status = \"merged\" | .merged_at = \"${merged_at}\" | .phase = \"merged\"" "${state_file}" > "${tmp}" && mv "${tmp}" "${state_file}"
}

@test "update_operation_state updates merge_status" {
    local branch="test-feature"
    mkdir -p "${BUILD_DIR}/operations/${branch}"
    echo '{"name": "test-feature", "phase": "completed"}' > "${BUILD_DIR}/operations/${branch}/state.json"

    update_operation_state "${branch}"

    run jq -r '.merge_status' "${BUILD_DIR}/operations/${branch}/state.json"
    assert_output "merged"
}

@test "update_operation_state sets phase to merged" {
    local branch="test-feature"
    mkdir -p "${BUILD_DIR}/operations/${branch}"
    echo '{"name": "test-feature", "phase": "completed"}' > "${BUILD_DIR}/operations/${branch}/state.json"

    update_operation_state "${branch}"

    run jq -r '.phase' "${BUILD_DIR}/operations/${branch}/state.json"
    assert_output "merged"
}

@test "update_operation_state sets merged_at timestamp" {
    local branch="test-feature"
    mkdir -p "${BUILD_DIR}/operations/${branch}"
    echo '{"name": "test-feature", "phase": "completed"}' > "${BUILD_DIR}/operations/${branch}/state.json"

    update_operation_state "${branch}"

    run jq -r '.merged_at' "${BUILD_DIR}/operations/${branch}/state.json"
    assert_success
    # Should be a valid timestamp
    [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "update_operation_state handles missing state file" {
    run update_operation_state "nonexistent-feature"
    assert_success
}

@test "update_operation_state preserves other fields" {
    local branch="test-feature"
    mkdir -p "${BUILD_DIR}/operations/${branch}"
    echo '{"name": "test-feature", "phase": "completed", "prompt": "Original prompt"}' > "${BUILD_DIR}/operations/${branch}/state.json"

    update_operation_state "${branch}"

    run jq -r '.prompt' "${BUILD_DIR}/operations/${branch}/state.json"
    assert_output "Original prompt"
}

@test "update_operation_state handles branch with prefix like feature/name" {
    # Operation is named "my-feature" but branch is "feature/my-feature"
    local op_name="my-feature"
    local branch="feature/my-feature"
    mkdir -p "${BUILD_DIR}/operations/${op_name}"
    echo '{"name": "my-feature", "phase": "completed"}' > "${BUILD_DIR}/operations/${op_name}/state.json"

    # Call with the full branch name (includes prefix)
    update_operation_state "${branch}"

    # Verify the state was updated correctly
    run jq -r '.merge_status' "${BUILD_DIR}/operations/${op_name}/state.json"
    assert_output "merged"

    run jq -r '.phase' "${BUILD_DIR}/operations/${op_name}/state.json"
    assert_output "merged"
}

@test "update_operation_state handles branch with fix/ prefix" {
    # Operation is named "bug-123" but branch is "fix/bug-123"
    local op_name="bug-123"
    local branch="fix/bug-123"
    mkdir -p "${BUILD_DIR}/operations/${op_name}"
    echo '{"name": "bug-123", "phase": "completed"}' > "${BUILD_DIR}/operations/${op_name}/state.json"

    update_operation_state "${branch}"

    run jq -r '.merge_status' "${BUILD_DIR}/operations/${op_name}/state.json"
    assert_output "merged"
}

# ============================================================================
# Lock contention integration tests
# ============================================================================

@test "multiple acquire attempts fail with existing lock" {
    # First acquire
    acquire_lock
    assert_file_exists "${LOCKFILE}"

    # Create a temporary file to check if second acquire was attempted from subshell
    # We need to simulate another process trying to acquire
    run bash -c 'export LOCKFILE="'"${LOCKFILE}"'"; if [ -f "${LOCKFILE}" ]; then echo "Error: Lock held" >&2; exit 1; fi'
    assert_failure
    assert_output --partial "Lock held"
}

@test "lock file contains process info" {
    acquire_lock

    run cat "${LOCKFILE}"
    assert_output --regexp "test-branch.*pid [0-9]+"
}

# ============================================================================
# Merge workflow simulation tests
# ============================================================================

@test "complete merge workflow updates state correctly" {
    local branch="complete-feature"
    mkdir -p "${BUILD_DIR}/operations/${branch}"
    echo '{"name": "complete-feature", "phase": "completed", "worktree": "/some/path"}' > "${BUILD_DIR}/operations/${branch}/state.json"

    # Simulate merge workflow
    run acquire_lock
    assert_success

    update_operation_state "${branch}"
    release_lock

    # Verify final state
    run jq -r '.phase' "${BUILD_DIR}/operations/${branch}/state.json"
    assert_output "merged"

    run jq -r '.merge_status' "${BUILD_DIR}/operations/${branch}/state.json"
    assert_output "merged"

    assert_file_not_exists "${LOCKFILE}"
}

# ============================================================================
# Operation name resolution tests
# ============================================================================

# Helper to resolve operation name to tree dir (mirrors v0-merge logic)
resolve_operation_name() {
    local input="$1"
    if [[ "${input}" != /* ]] && [[ "${input}" != .* ]]; then
        local state_file="${BUILD_DIR}/operations/${input}/state.json"
        if [ ! -f "${state_file}" ]; then
            echo "Error: No operation found for '${input}'" >&2
            return 1
        fi
        local worktree
        worktree=$(jq -r '.worktree // empty' "${state_file}")
        if [ -z "${worktree}" ] || [ "${worktree}" = "null" ]; then
            echo "Error: Operation '${input}' has no worktree" >&2
            return 1
        fi
        dirname "${worktree}"
    else
        echo "${input}"
    fi
}

@test "resolve_operation_name returns path unchanged for absolute paths" {
    run resolve_operation_name "/some/absolute/path"
    assert_success
    assert_output "/some/absolute/path"
}

@test "resolve_operation_name returns path unchanged for relative paths starting with ." {
    run resolve_operation_name "./relative/path"
    assert_success
    assert_output "./relative/path"
}

@test "resolve_operation_name looks up operation state for simple names" {
    local op_name="my-feature"
    mkdir -p "${BUILD_DIR}/operations/${op_name}"
    echo '{"name": "my-feature", "worktree": "/some/tree/my-feature/repo"}' > "${BUILD_DIR}/operations/${op_name}/state.json"

    run resolve_operation_name "${op_name}"
    assert_success
    assert_output "/some/tree/my-feature"
}

@test "resolve_operation_name fails for non-existent operation" {
    run resolve_operation_name "nonexistent-op"
    assert_failure
    assert_output --partial "No operation found"
}

@test "resolve_operation_name fails for operation without worktree" {
    local op_name="no-worktree"
    mkdir -p "${BUILD_DIR}/operations/${op_name}"
    echo '{"name": "no-worktree", "phase": "init"}' > "${BUILD_DIR}/operations/${op_name}/state.json"

    run resolve_operation_name "${op_name}"
    assert_failure
    assert_output --partial "has no worktree"
}
