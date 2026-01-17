#!/usr/bin/env bats
# Tests for v0-prune - Remove operation state

load '../helpers/test_helper'

# Setup for prune tests
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
    export BUILD_DIR="${TEST_TEMP_DIR}/project/.v0/build"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"

    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Help and Usage tests
# ============================================================================

@test "prune --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0-prune" --help
    # Help exits with code 1 (usage)
    assert_failure
    [[ "${output}" == *"v0 prune"* ]]
    [[ "${output}" == *"Remove operation state"* ]]
}

@test "prune -h shows usage" {
    run "${PROJECT_ROOT}/bin/v0-prune" -h
    # Help exits with code 1 (usage)
    assert_failure
    [[ "${output}" == *"v0 prune"* ]]
}

# ============================================================================
# Prune completed/cancelled operations (default behavior)
# ============================================================================

@test "prune removes merged operations" {
    mkdir -p "${BUILD_DIR}/operations/test-op"
    echo '{"phase": "merged", "name": "test-op"}' > "${BUILD_DIR}/operations/test-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/test-op" ]
    [[ "${output}" == *"Pruned: test-op"* ]]
}

@test "prune removes cancelled operations" {
    mkdir -p "${BUILD_DIR}/operations/cancelled-op"
    echo '{"phase": "cancelled", "name": "cancelled-op"}' > "${BUILD_DIR}/operations/cancelled-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/cancelled-op" ]
    [[ "${output}" == *"Pruned: cancelled-op"* ]]
}

@test "prune removes completed operations with merged status" {
    mkdir -p "${BUILD_DIR}/operations/completed-op"
    echo '{"phase": "completed", "name": "completed-op", "merge_status": "merged"}' > "${BUILD_DIR}/operations/completed-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/completed-op" ]
}

@test "prune removes pending_merge operations with merged status" {
    mkdir -p "${BUILD_DIR}/operations/pending-op"
    echo '{"phase": "pending_merge", "name": "pending-op", "merge_status": "merged"}' > "${BUILD_DIR}/operations/pending-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ ! -d "${BUILD_DIR}/operations/pending-op" ]
}

@test "prune skips executing operations" {
    mkdir -p "${BUILD_DIR}/operations/active-op"
    echo '{"phase": "executing", "name": "active-op"}' > "${BUILD_DIR}/operations/active-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ -d "${BUILD_DIR}/operations/active-op" ]
}

@test "prune skips init phase operations" {
    mkdir -p "${BUILD_DIR}/operations/init-op"
    echo '{"phase": "init", "name": "init-op"}' > "${BUILD_DIR}/operations/init-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ -d "${BUILD_DIR}/operations/init-op" ]
}

@test "prune skips completed operations without merged status" {
    mkdir -p "${BUILD_DIR}/operations/unmerged-op"
    echo '{"phase": "completed", "name": "unmerged-op"}' > "${BUILD_DIR}/operations/unmerged-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [ -d "${BUILD_DIR}/operations/unmerged-op" ]
}

@test "prune reports no operations when empty" {
    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"No completed or cancelled operations to prune"* ]]
}

@test "prune reports no operations when directory missing" {
    rmdir "${BUILD_DIR}/operations"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"No operations to prune"* ]]
}

@test "prune counts pruned operations" {
    mkdir -p "${BUILD_DIR}/operations/op1" "${BUILD_DIR}/operations/op2" "${BUILD_DIR}/operations/op3"
    echo '{"phase": "merged", "name": "op1"}' > "${BUILD_DIR}/operations/op1/state.json"
    echo '{"phase": "cancelled", "name": "op2"}' > "${BUILD_DIR}/operations/op2/state.json"
    echo '{"phase": "executing", "name": "op3"}' > "${BUILD_DIR}/operations/op3/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune"
    assert_success
    [[ "${output}" == *"Pruned 2 operation(s)"* ]]
    [ ! -d "${BUILD_DIR}/operations/op1" ]
    [ ! -d "${BUILD_DIR}/operations/op2" ]
    [ -d "${BUILD_DIR}/operations/op3" ]
}

# ============================================================================
# Prune specific operation by name
# ============================================================================

@test "prune specific operation by name" {
    mkdir -p "${BUILD_DIR}/operations/specific-op"
    echo '{"phase": "executing", "name": "specific-op"}' > "${BUILD_DIR}/operations/specific-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --force specific-op
    assert_success
    [ ! -d "${BUILD_DIR}/operations/specific-op" ]
    [[ "${output}" == *"Pruned operation 'specific-op'"* ]]
}

@test "prune nonexistent operation fails" {
    run "${PROJECT_ROOT}/bin/v0-prune" nonexistent
    assert_failure
    [[ "${output}" == *"not found"* ]]
}

# ============================================================================
# Dry-run mode
# ============================================================================

@test "prune --dry-run shows preview without removing" {
    mkdir -p "${BUILD_DIR}/operations/dry-run-op"
    echo '{"phase": "merged", "name": "dry-run-op"}' > "${BUILD_DIR}/operations/dry-run-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --dry-run
    assert_success
    [ -d "${BUILD_DIR}/operations/dry-run-op" ]  # Still exists
    [[ "${output}" == *"Would prune"* ]]
}

@test "prune -n is alias for --dry-run" {
    mkdir -p "${BUILD_DIR}/operations/dry-run-op"
    echo '{"phase": "merged", "name": "dry-run-op"}' > "${BUILD_DIR}/operations/dry-run-op/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" -n
    assert_success
    [ -d "${BUILD_DIR}/operations/dry-run-op" ]
    [[ "${output}" == *"Would prune"* ]]
}

@test "prune --dry-run with specific operation" {
    mkdir -p "${BUILD_DIR}/operations/specific-dry"
    echo '{"phase": "executing", "name": "specific-dry"}' > "${BUILD_DIR}/operations/specific-dry/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --dry-run specific-dry
    assert_success
    [ -d "${BUILD_DIR}/operations/specific-dry" ]
    [[ "${output}" == *"Would prune: specific-dry"* ]]
}

# ============================================================================
# Prune all operations
# ============================================================================

@test "prune --all --force removes everything" {
    mkdir -p "${BUILD_DIR}/operations/op1"
    mkdir -p "${BUILD_DIR}/operations/op2"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/op1/state.json"
    echo '{"phase": "init"}' > "${BUILD_DIR}/operations/op2/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --all --force
    assert_success
    [ ! -d "${BUILD_DIR}/operations" ]
    [[ "${output}" == *"Pruned all operations"* ]]
}

@test "prune -a -f removes everything" {
    mkdir -p "${BUILD_DIR}/operations/op1"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/op1/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" -a -f
    assert_success
    [ ! -d "${BUILD_DIR}/operations" ]
}

@test "prune --all reports no operations when empty" {
    rmdir "${BUILD_DIR}/operations"

    run "${PROJECT_ROOT}/bin/v0-prune" --all --force
    assert_success
    [[ "${output}" == *"No operations to prune"* ]]
}

@test "prune --all --dry-run shows preview" {
    mkdir -p "${BUILD_DIR}/operations/op1"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/op1/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --all --dry-run
    assert_success
    [ -d "${BUILD_DIR}/operations" ]
    [[ "${output}" == *"Would remove"* ]]
}

# ============================================================================
# Error handling
# ============================================================================

@test "prune unknown option shows usage" {
    run "${PROJECT_ROOT}/bin/v0-prune" --unknown
    assert_failure
    [[ "${output}" == *"Unknown option"* ]]
}

@test "prune accepts multiple operation names" {
    mkdir -p "${BUILD_DIR}/operations/op1" "${BUILD_DIR}/operations/op2" "${BUILD_DIR}/operations/op3"
    echo '{"phase": "executing", "name": "op1"}' > "${BUILD_DIR}/operations/op1/state.json"
    echo '{"phase": "executing", "name": "op2"}' > "${BUILD_DIR}/operations/op2/state.json"
    echo '{"phase": "executing", "name": "op3"}' > "${BUILD_DIR}/operations/op3/state.json"

    run "${PROJECT_ROOT}/bin/v0-prune" --force op1 op2
    assert_success
    [ ! -d "${BUILD_DIR}/operations/op1" ]
    [ ! -d "${BUILD_DIR}/operations/op2" ]
    [ -d "${BUILD_DIR}/operations/op3" ]  # op3 should still exist
    [[ "${output}" == *"Pruned operation 'op1'"* ]]
    [[ "${output}" == *"Pruned operation 'op2'"* ]]
}
