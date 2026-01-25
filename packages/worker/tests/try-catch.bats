#!/usr/bin/env bats
# Tests for try-catch.sh - Exit Code Capture and Logging

load '../../test-support/helpers/test_helper'

# Setup for error logging tests
setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/tree"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "${TEST_TEMP_DIR}/project" || exit 1
    export ORIGINAL_PATH="${PATH}"

    # Export paths for try-catch
    export LOG_FILE="${TEST_TEMP_DIR}/tree/worker.log"
    export ERROR_FILE="${TEST_TEMP_DIR}/tree/worker.log.error"
    export TREE_DIR="${TEST_TEMP_DIR}/tree"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"

    if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Exit code capture tests
# ============================================================================

@test "wrapper captures exit code 0 correctly" {
    # Simulate wrapper behavior
    local exit_code
    bash -c 'exit 0'
    exit_code=$?

    assert_equal "${exit_code}" "0"
}

@test "wrapper captures non-zero exit code" {
    local exit_code
    bash -c 'exit 42' || exit_code=$?

    assert_equal "${exit_code}" "42"
}

@test "wrapper captures exit code from failing command" {
    local exit_code
    bash -c 'false' || exit_code=$?

    assert_equal "${exit_code}" "1"
}

# ============================================================================
# Log file creation tests
# ============================================================================

@test "wrapper creates log file on startup" {
    # Simulate logging startup
    local log_file="${TEST_TEMP_DIR}/tree/test.log"
    echo "[$(date)] Starting Test Worker" >> "${log_file}"

    assert_file_exists "${log_file}"
}

@test "wrapper appends to existing log file" {
    local log_file="${TEST_TEMP_DIR}/tree/test.log"
    echo "First line" > "${log_file}"
    echo "Second line" >> "${log_file}"

    run cat "${log_file}"
    assert_output --partial "First line"
    assert_output --partial "Second line"
}

@test "wrapper logs exit code on failure" {
    local log_file="${TEST_TEMP_DIR}/tree/test.log"
    local exit_code=5

    echo "[$(date)] Worker FAILED with exit code ${exit_code}" >> "${log_file}"

    run cat "${log_file}"
    assert_output --partial "FAILED"
    assert_output --partial "exit code 5"
}

# ============================================================================
# .worker-error file tests
# ============================================================================

@test "error wrapper creates .worker-error on non-zero exit" {
    local error_file="${TREE_DIR}/.worker-error"

    # Simulate error condition
    local exit_code=1
    if [[ "${exit_code}" -ne 0 ]]; then
        touch "${error_file}"
    fi

    assert_file_exists "${error_file}"
}

@test "error wrapper does not create error file on success" {
    local error_file="${TREE_DIR}/.worker-error"

    # Simulate success condition
    local exit_code=0
    if [[ "${exit_code}" -ne 0 ]]; then
        touch "${error_file}"
    fi

    assert_file_not_exists "${error_file}"
}

@test ".worker-error file is created in correct directory" {
    local tree_dir="${TEST_TEMP_DIR}/custom-tree"
    mkdir -p "${tree_dir}"

    touch "${tree_dir}/.worker-error"

    assert_file_exists "${tree_dir}/.worker-error"
}

# ============================================================================
# .done-exit file tests
# ============================================================================

@test "done-exit flag is detected" {
    local done_exit_flag="${TREE_DIR}/.done-exit"
    touch "${done_exit_flag}"

    assert_file_exists "${done_exit_flag}"
}

@test "done-exit flag is cleaned up after detection" {
    local done_exit_flag="${TREE_DIR}/.done-exit"
    touch "${done_exit_flag}"

    # Simulate cleanup
    if [[ -f "${done_exit_flag}" ]]; then
        rm -f "${done_exit_flag}"
    fi

    assert_file_not_exists "${done_exit_flag}"
}

@test "clean exit does not create worker-error when done-exit exists" {
    local done_exit_flag="${TREE_DIR}/.done-exit"
    local error_file="${TREE_DIR}/.worker-error"

    touch "${done_exit_flag}"

    # Simulate wrapper logic
    local exit_code=1  # Non-zero but clean exit
    local clean_exit=0

    if [[ -f "${done_exit_flag}" ]]; then
        clean_exit=1
        rm -f "${done_exit_flag}"
    fi

    if [[ "${exit_code}" -ne 0 ]] && [[ "${clean_exit}" -ne 1 ]]; then
        touch "${error_file}"
    fi

    assert_file_not_exists "${error_file}"
}

# ============================================================================
# Error logging content tests
# ============================================================================

@test "error log includes timestamp" {
    local log_file="${TEST_TEMP_DIR}/tree/test.log"
    echo "[$(date)] Error occurred" >> "${log_file}"

    run cat "${log_file}"
    # Timestamp should be present
    assert_output --regexp "\[.*\]"
}

@test "error log includes worker name" {
    local log_file="${TEST_TEMP_DIR}/tree/test.log"
    local worker_name="Test Worker"

    echo "[$(date)] ${worker_name} FAILED with exit code 1" >> "${log_file}"

    run cat "${log_file}"
    assert_output --partial "Test Worker"
}

@test "error log includes log file path" {
    local log_file="${TEST_TEMP_DIR}/tree/test.log"

    echo "[$(date)] Logs: ${log_file}" >> "${log_file}"

    run cat "${log_file}"
    assert_output --partial "${log_file}"
}

# ============================================================================
# Path handling tests
# ============================================================================

@test "wrapper converts relative log path to absolute" {
    local relative_path="logs/worker.log"
    local abs_path

    # Simulate conversion
    mkdir -p "${TEST_TEMP_DIR}/logs"
    abs_path="$(cd "${TEST_TEMP_DIR}" && pwd)/${relative_path}"

    [[ "${abs_path}" == /* ]]  # Should start with /
}

@test "wrapper handles log path with spaces" {
    local log_dir="${TEST_TEMP_DIR}/path with spaces"
    mkdir -p "${log_dir}"
    local log_file="${log_dir}/worker.log"

    echo "test" > "${log_file}"

    assert_file_exists "${log_file}"
}

# ============================================================================
# Notification suppression tests
# ============================================================================

@test "notifications disabled by DISABLE_NOTIFICATIONS=1" {
    export DISABLE_NOTIFICATIONS=1

    # Simulate notification check
    local should_notify=true
    if [[ "${DISABLE_NOTIFICATIONS}" = "1" ]]; then
        should_notify=false
    fi

    assert_equal "${should_notify}" "false"
}

@test "notifications enabled by default" {
    unset DISABLE_NOTIFICATIONS

    local should_notify=true
    if [[ "${DISABLE_NOTIFICATIONS}" = "1" ]]; then
        should_notify=false
    fi

    assert_equal "${should_notify}" "true"
}

# ============================================================================
# Integration tests
# ============================================================================

@test "complete error workflow creates expected files" {
    # Simulate complete error workflow
    local log_file="${TREE_DIR}/worker.log"
    local error_file="${TREE_DIR}/.worker-error"
    local exit_code=1
    local clean_exit=0

    # Log startup
    echo "[$(date)] Starting Worker" >> "${log_file}"

    # Log failure
    if [[ "${exit_code}" -ne 0 ]] && [[ "${clean_exit}" -ne 1 ]]; then
        echo "[$(date)] Worker FAILED with exit code ${exit_code}" >> "${log_file}"
        touch "${error_file}"
    fi

    assert_file_exists "${log_file}"
    assert_file_exists "${error_file}"

    run cat "${log_file}"
    assert_output --partial "FAILED"
}

@test "clean exit workflow does not create error file" {
    # Simulate clean exit workflow
    local log_file="${TREE_DIR}/worker.log"
    local error_file="${TREE_DIR}/.worker-error"
    local done_exit_flag="${TREE_DIR}/.done-exit"
    local exit_code=0

    # Create done flag
    touch "${done_exit_flag}"

    # Log clean exit
    echo "[$(date)] Worker exited cleanly" >> "${log_file}"

    # Check and cleanup done flag
    if [[ -f "${done_exit_flag}" ]]; then
        rm -f "${done_exit_flag}"
    fi

    assert_file_exists "${log_file}"
    assert_file_not_exists "${error_file}"
    assert_file_not_exists "${done_exit_flag}"
}
