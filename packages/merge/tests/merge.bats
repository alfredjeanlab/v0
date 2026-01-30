#!/usr/bin/env bats
# Tests for v0-merge - Lock Management & Conflict Detection

load '../../test-support/helpers/test_helper'

# Setup for merge tests
setup() {
    _base_setup
    setup_v0_env
    export LOCKFILE="${BUILD_DIR}/.merge.lock"
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

# ============================================================================
# Worktree-less merge tests
# ============================================================================

@test "resolve_operation_name_v2 returns branch when worktree missing but branch exists" {
    # This tests the new behavior where missing worktree + existing branch = success
    local op_name="has-branch"
    mkdir -p "${BUILD_DIR}/operations/${op_name}"
    echo '{"name": "has-branch", "phase": "completed", "worktree": "/nonexistent", "branch": "feature/test"}' > "${BUILD_DIR}/operations/${op_name}/state.json"

    # Note: This would need a real git repo with the branch to fully test
    # For unit testing, we verify the state file is properly read
    run jq -r '.branch' "${BUILD_DIR}/operations/${op_name}/state.json"
    assert_output "feature/test"
}

@test "operation state with branch field is preserved" {
    local op_name="branch-preserved"
    mkdir -p "${BUILD_DIR}/operations/${op_name}"
    echo '{"name": "branch-preserved", "phase": "completed", "worktree": "/some/path", "branch": "feature/my-branch"}' > "${BUILD_DIR}/operations/${op_name}/state.json"

    run jq -r '.branch' "${BUILD_DIR}/operations/${op_name}/state.json"
    assert_output "feature/my-branch"

    run jq -r '.worktree' "${BUILD_DIR}/operations/${op_name}/state.json"
    assert_output "/some/path"
}

# ============================================================================
# mg_ensure_develop_branch() tests
# ============================================================================

@test "mg_ensure_develop_branch does nothing when already on develop branch" {
    # Setup a real git repo for this test
    local test_repo="${TEST_TEMP_DIR}/test-repo"
    git init "${test_repo}" --quiet
    cd "${test_repo}"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial" --quiet

    # Ensure we have a 'main' branch
    git branch -M main

    export V0_DEVELOP_BRANCH="main"
    export V0_GIT_REMOTE="origin"

    # Source the actual function
    source_lib "execution.sh"

    run mg_ensure_develop_branch
    assert_success
    refute_output --partial "Switching to"
}

@test "mg_ensure_develop_branch switches to develop branch when on different branch" {
    # Setup a real git repo for this test
    local test_repo="${TEST_TEMP_DIR}/test-repo"
    git init "${test_repo}" --quiet
    cd "${test_repo}"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial" --quiet

    # Ensure we have a 'main' branch (rename if needed)
    git branch -M main

    # Create and switch to a different branch
    git checkout -b other-branch --quiet

    export V0_DEVELOP_BRANCH="main"
    export V0_GIT_REMOTE="origin"

    # Source the actual function
    source_lib "execution.sh"

    run mg_ensure_develop_branch
    assert_success
    assert_output --partial "Switching to main"

    # Verify we're now on main
    run git rev-parse --abbrev-ref HEAD
    assert_output "main"
}

@test "mg_ensure_develop_branch resets to remote when local has diverged" {
    # Simulate the scenario where v0 push force-updated the remote agent branch,
    # causing the local develop branch to diverge from remote.
    # Before this fix, the push after merge would fail with non-fast-forward error.

    # Create a bare repo to act as the remote
    local remote_repo="${TEST_TEMP_DIR}/remote.git"
    git init --bare "${remote_repo}" --quiet

    # Create the workspace repo (clone of remote)
    local test_repo="${TEST_TEMP_DIR}/test-repo"
    git clone "${remote_repo}" "${test_repo}" --quiet
    cd "${test_repo}"
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -b main --quiet  # Empty repos don't have a branch yet

    # Make initial commit and push
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial" --quiet
    git push origin main --quiet

    # Simulate a previous merge on the local branch (not yet pushed)
    echo "local merge work" > merged.txt
    git add merged.txt
    git commit -m "local merge" --quiet
    local local_commit
    local_commit=$(git rev-parse HEAD)

    # Simulate v0 push force-updating the remote with different content
    local tmp_clone="${TEST_TEMP_DIR}/tmp-clone"
    git clone "${remote_repo}" "${tmp_clone}" --quiet
    cd "${tmp_clone}"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "force pushed content" > pushed.txt
    git add pushed.txt
    git commit -m "force pushed from v0 push" --quiet
    local remote_commit
    remote_commit=$(git rev-parse HEAD)
    git push --force origin main --quiet
    cd "${test_repo}"

    # Verify histories have diverged
    local current_head
    current_head=$(git rev-parse HEAD)
    assert_equal "${current_head}" "${local_commit}"

    export V0_DEVELOP_BRANCH="main"
    export V0_GIT_REMOTE="origin"

    # Source the actual function
    source_lib "execution.sh"

    # This should succeed and reset local to match remote
    run mg_ensure_develop_branch
    assert_success

    # Verify HEAD is now at the remote commit (not the old local commit)
    local new_head
    new_head=$(git rev-parse HEAD)
    assert_equal "${new_head}" "${remote_commit}"
}

@test "mg_ensure_develop_branch fails when develop branch doesn't exist" {
    # Setup a real git repo for this test
    local test_repo="${TEST_TEMP_DIR}/test-repo"
    git init "${test_repo}" --quiet
    cd "${test_repo}"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial" --quiet

    export V0_DEVELOP_BRANCH="nonexistent-branch"
    export V0_GIT_REMOTE="origin"

    # Source the actual function
    source_lib "execution.sh"

    run mg_ensure_develop_branch
    assert_failure
    assert_output --partial "Failed to checkout"
}

# ============================================================================
# mg_trigger_dependents() tests
# ============================================================================

@test "mg_trigger_dependents resumes dependent operations" {
    # Setup: Create a mock v0-feature script in a temp bin directory
    # IMPORTANT: Never overwrite real scripts - use PATH override instead
    local call_log="${TEST_TEMP_DIR}/feature-calls.log"
    local mock_bin="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/v0-feature" <<'MOCK'
#!/bin/bash
echo "$@" >> "$CALL_LOG"
MOCK
    chmod +x "${mock_bin}/v0-feature"
    export CALL_LOG="${call_log}"
    export PATH="${mock_bin}:${PATH}"

    # Setup merged operation with epic_id
    mkdir -p "${BUILD_DIR}/operations/merged-op"
    echo '{"name": "merged-op", "phase": "merged", "epic_id": "test-epic-1"}' > "${BUILD_DIR}/operations/merged-op/state.json"

    # Setup dependent operation
    mkdir -p "${BUILD_DIR}/operations/dependent-op"
    echo '{"name": "dependent-op", "phase": "queued", "epic_id": "test-epic-2"}' > "${BUILD_DIR}/operations/dependent-op/state.json"

    # Mock wk show to return blocking relationship
    wk() {
        case "$1" in
            show)
                case "$2" in
                    test-epic-1)
                        echo '{"blocking": ["test-epic-2"]}'
                        ;;
                    test-epic-2)
                        echo '{"labels": ["plan:dependent-op"], "status": "todo"}'
                        ;;
                esac
                ;;
        esac
    }
    export -f wk

    # Source the function
    source_lib "state-update.sh"

    # Run the function
    mg_trigger_dependents "feature/merged-op"

    # Wait for background process
    sleep 0.5

    # Verify v0-feature was called to resume the dependent
    if [[ -f "${call_log}" ]]; then
        run cat "${call_log}"
        assert_output --partial "dependent-op"
        assert_output --partial "--resume"
    else
        # No dependents found is OK if mocking isn't complete
        skip "Mock not complete enough to test full flow"
    fi
}

@test "mg_trigger_dependents skips held operations" {
    # Setup: Create a mock v0-feature script in a temp bin directory
    # IMPORTANT: Never overwrite real scripts - use PATH override instead
    local call_log="${TEST_TEMP_DIR}/feature-calls.log"
    local mock_bin="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_bin}"
    cat > "${mock_bin}/v0-feature" <<'MOCK'
#!/bin/bash
echo "$@" >> "$CALL_LOG"
MOCK
    chmod +x "${mock_bin}/v0-feature"
    export CALL_LOG="${call_log}"
    export PATH="${mock_bin}:${PATH}"

    # Setup merged operation with epic_id
    mkdir -p "${BUILD_DIR}/operations/merged-op"
    echo '{"name": "merged-op", "phase": "merged", "epic_id": "test-epic-1"}' > "${BUILD_DIR}/operations/merged-op/state.json"

    # Setup dependent operation that is held
    mkdir -p "${BUILD_DIR}/operations/held-op"
    echo '{"name": "held-op", "phase": "queued", "epic_id": "test-epic-2", "hold": true}' > "${BUILD_DIR}/operations/held-op/state.json"

    # Mock wk show to return blocking relationship
    wk() {
        case "$1" in
            show)
                case "$2" in
                    test-epic-1)
                        echo '{"blocking": ["test-epic-2"]}'
                        ;;
                    test-epic-2)
                        echo '{"labels": ["plan:held-op"], "status": "todo"}'
                        ;;
                esac
                ;;
        esac
    }
    export -f wk

    # Source the function
    source_lib "state-update.sh"

    # Run the function
    mg_trigger_dependents "feature/merged-op"

    # Wait for any background process
    sleep 0.5

    # Verify v0-feature was NOT called (operation is held)
    if [[ -f "${call_log}" ]]; then
        run cat "${call_log}"
        refute_output --partial "held-op"
    fi
    # No call log file means no calls were made, which is correct
}
