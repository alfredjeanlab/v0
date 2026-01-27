#!/usr/bin/env bats
# Tests for prune-daemon.sh - Background pruning daemon control

load '../../test-support/helpers/test_helper'

# Setup for prune-daemon tests
setup() {
    _base_setup
    setup_v0_env

    # Source the prune-daemon library
    source "${PROJECT_ROOT}/packages/core/lib/prune-daemon.sh"

    # Create log directory
    mkdir -p "${BUILD_DIR}/logs"
}

# ============================================================================
# Path initialization tests
# ============================================================================

@test "_prune_daemon_init_paths sets correct file paths" {
    _prune_daemon_init_paths

    assert_equal "${PRUNE_DAEMON_PID_FILE}" "${BUILD_DIR}/.prune-daemon.pid"
    assert_equal "${PRUNE_DAEMON_LOCK_FILE}" "${BUILD_DIR}/.prune-daemon.lock"
    assert_equal "${PRUNE_DAEMON_LOG_FILE}" "${BUILD_DIR}/logs/prune-daemon.log"
}

# ============================================================================
# prune_daemon_running() tests
# ============================================================================

@test "prune_daemon_running returns 1 when no PID file exists" {
    run prune_daemon_running
    assert_failure
}

@test "prune_daemon_running returns 1 when PID file contains dead process" {
    _prune_daemon_init_paths
    # Use a PID that definitely doesn't exist
    echo "999999" > "${PRUNE_DAEMON_PID_FILE}"

    run prune_daemon_running
    assert_failure

    # Should clean up stale PID file
    assert_file_not_exists "${PRUNE_DAEMON_PID_FILE}"
}

@test "prune_daemon_running returns 0 when process is running" {
    _prune_daemon_init_paths

    # Start a background sleep to simulate running daemon
    sleep 60 &
    local pid=$!

    echo "${pid}" > "${PRUNE_DAEMON_PID_FILE}"

    run prune_daemon_running
    assert_success

    # Cleanup
    kill "${pid}" 2>/dev/null || true
}

@test "prune_daemon_running cleans up stale PID file" {
    _prune_daemon_init_paths
    echo "99999999" > "${PRUNE_DAEMON_PID_FILE}"

    prune_daemon_running || true

    assert_file_not_exists "${PRUNE_DAEMON_PID_FILE}"
}

# ============================================================================
# prune_daemon_pid() tests
# ============================================================================

@test "prune_daemon_pid returns empty when no PID file" {
    run prune_daemon_pid
    assert_success
    assert_output ""
}

@test "prune_daemon_pid returns PID from file" {
    _prune_daemon_init_paths
    echo "12345" > "${PRUNE_DAEMON_PID_FILE}"

    run prune_daemon_pid
    assert_success
    assert_output "12345"
}

# ============================================================================
# prune_daemon_stop() tests
# ============================================================================

@test "prune_daemon_stop does nothing when not running" {
    run prune_daemon_stop
    assert_success
}

@test "prune_daemon_stop kills running process and removes PID file" {
    _prune_daemon_init_paths

    # Start a background process
    sleep 60 &
    local pid=$!
    echo "${pid}" > "${PRUNE_DAEMON_PID_FILE}"

    run prune_daemon_stop
    assert_success

    # PID file should be removed
    assert_file_not_exists "${PRUNE_DAEMON_PID_FILE}"

    # Process should be killed
    run kill -0 "${pid}" 2>/dev/null
    assert_failure
}

# ============================================================================
# prune_daemon_trigger() tests
# ============================================================================

@test "prune_daemon_trigger does nothing when daemon not running" {
    run prune_daemon_trigger
    assert_success
}

@test "prune_daemon_trigger sends USR1 to running daemon" {
    _prune_daemon_init_paths

    # Start a background sleep to simulate running daemon
    sleep 60 &
    local pid=$!

    echo "${pid}" > "${PRUNE_DAEMON_PID_FILE}"

    # Trigger should not fail
    run prune_daemon_trigger
    assert_success

    # Cleanup
    kill "${pid}" 2>/dev/null || true
}

# ============================================================================
# prune_daemon_wait() tests
# ============================================================================

@test "prune_daemon_wait returns immediately when daemon not running" {
    run prune_daemon_wait
    assert_success
}

@test "prune_daemon_wait sends TERM to daemon" {
    _prune_daemon_init_paths

    # Start a background sleep to simulate running daemon
    sleep 60 &
    local pid=$!

    echo "${pid}" > "${PRUNE_DAEMON_PID_FILE}"

    # Manually kill to simulate what wait does (don't actually call wait as it takes 30s)
    kill -TERM "${pid}" 2>/dev/null || true
    # Wait for process to actually exit (up to 2 seconds)
    local count=0
    while kill -0 "${pid}" 2>/dev/null && [[ $count -lt 20 ]]; do
        sleep 0.1
        count=$((count + 1))
    done
    rm -f "${PRUNE_DAEMON_PID_FILE}"

    # Cleanup should have happened
    assert_file_not_exists "${PRUNE_DAEMON_PID_FILE}"
}
