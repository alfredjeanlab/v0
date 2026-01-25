#!/usr/bin/env bats
# Integration tests for background pruning daemon
# Tests: v0 prune quick exit, background pruning, shutdown wait

load '../packages/test-support/helpers/test_helper'

# Longer timeout for daemon tests
BATS_TEST_TIMEOUT=30

# Setup for daemon integration tests
setup() {
    _base_setup
    setup_v0_env

    # Initialize git repo (needed for some operations)
    init_mock_git_repo

    # Source v0-common to get all functions including daemon control
    source "${PROJECT_ROOT}/packages/cli/lib/v0-common.sh"

    # Set V0_DIR for daemon binary
    export V0_DIR="${PROJECT_ROOT}"

    # Create log directory
    mkdir -p "${BUILD_DIR}/logs"

    # Create mergeq directory with empty queue
    mkdir -p "${BUILD_DIR}/mergeq"
    echo '{"version":1,"entries":[]}' > "${BUILD_DIR}/mergeq/queue.json"
}

teardown() {
    # Stop any running daemon
    if [[ -f "${BUILD_DIR}/.prune-daemon.pid" ]]; then
        local pid
        pid=$(cat "${BUILD_DIR}/.prune-daemon.pid")
        kill "${pid}" 2>/dev/null || true
        rm -f "${BUILD_DIR}/.prune-daemon.pid"
    fi

    # Standard teardown
    [[ -n "${REAL_HOME:-}" ]] && export HOME="$REAL_HOME"
    [[ -n "${ORIGINAL_PATH:-}" ]] && export PATH="$ORIGINAL_PATH"
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        /bin/rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Daemon lifecycle tests
# ============================================================================

@test "prune_daemon_start creates daemon process" {
    run prune_daemon_start
    assert_success

    # PID file should exist
    assert_file_exists "${BUILD_DIR}/.prune-daemon.pid"

    # Daemon should be running
    run prune_daemon_running
    assert_success
}

@test "prune_daemon_start is idempotent" {
    prune_daemon_start
    local pid1
    pid1=$(prune_daemon_pid)

    prune_daemon_start
    local pid2
    pid2=$(prune_daemon_pid)

    # Same PID - didn't start a new daemon
    assert_equal "${pid1}" "${pid2}"
}

@test "prune_daemon_stop terminates running daemon" {
    prune_daemon_start
    local pid
    pid=$(prune_daemon_pid)

    run prune_daemon_stop
    assert_success

    # PID file should be removed
    assert_file_not_exists "${BUILD_DIR}/.prune-daemon.pid"

    # Give process time to exit
    sleep 0.5

    # Process should be gone
    run kill -0 "${pid}" 2>/dev/null
    assert_failure
}

@test "prune_daemon_trigger wakes sleeping daemon" {
    prune_daemon_start

    # Wait for daemon to start sleeping (initial prune should be quick with empty queues)
    sleep 1

    # Trigger immediate run
    run prune_daemon_trigger
    assert_success

    # Check log shows the wake-up
    sleep 0.5
    run grep -c "SIGUSR1\|waking" "${BUILD_DIR}/logs/prune-daemon.log"
    assert_success
}

# ============================================================================
# Daemon logging tests
# ============================================================================

@test "daemon writes to log file" {
    prune_daemon_start

    # Give daemon time to run initial prune
    sleep 1

    # Log file should exist with content
    assert_file_exists "${BUILD_DIR}/logs/prune-daemon.log"

    run cat "${BUILD_DIR}/logs/prune-daemon.log"
    assert_success
    assert_output --partial "Prune daemon starting"
}

@test "daemon logs pruning activity" {
    prune_daemon_start

    # Give daemon time to complete initial prune
    sleep 1

    run cat "${BUILD_DIR}/logs/prune-daemon.log"
    assert_output --partial "Starting pruning"
    assert_output --partial "Pruning complete"
}

# ============================================================================
# Prune daemon wait tests
# ============================================================================

@test "prune_daemon_wait blocks until daemon exits" {
    prune_daemon_start
    local pid
    pid=$(prune_daemon_pid)

    # Wait should complete and daemon should exit
    run prune_daemon_wait
    assert_success

    # PID file should be gone
    assert_file_not_exists "${BUILD_DIR}/.prune-daemon.pid"

    # Process should be terminated
    run kill -0 "${pid}" 2>/dev/null
    assert_failure
}

@test "prune_daemon_wait is safe to call when daemon not running" {
    run prune_daemon_wait
    assert_success
}

# ============================================================================
# Lock file tests
# ============================================================================

@test "daemon acquires lock during pruning" {
    prune_daemon_start

    # Give daemon time to run
    sleep 0.5

    # Lock file should exist
    assert_file_exists "${BUILD_DIR}/.prune-daemon.lock"
}

# ============================================================================
# Signal handling tests
# ============================================================================

@test "daemon exits gracefully on SIGTERM" {
    prune_daemon_start
    local pid
    pid=$(prune_daemon_pid)

    # Send SIGTERM
    kill -TERM "${pid}"

    # Give daemon time to exit
    sleep 1

    # Check log shows graceful shutdown
    run cat "${BUILD_DIR}/logs/prune-daemon.log"
    assert_output --partial "shutting down"

    # Process should be gone
    run kill -0 "${pid}" 2>/dev/null
    assert_failure
}
