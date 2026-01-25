#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# prune-daemon.sh - Background pruning daemon control
#
# Depends on: pruning.sh (for v0_prune_logs, v0_prune_mergeq)
# IMPURE: Uses process management, signal handling, file system operations

# Expected environment variables:
# V0_DIR - Path to v0 installation
# BUILD_DIR - Path to build directory

# PID/Lock/Log file locations
# These are set when BUILD_DIR is available
_prune_daemon_init_paths() {
    PRUNE_DAEMON_PID_FILE="${BUILD_DIR}/.prune-daemon.pid"
    PRUNE_DAEMON_LOCK_FILE="${BUILD_DIR}/.prune-daemon.lock"
    PRUNE_DAEMON_LOG_DIR="${BUILD_DIR}/logs"
    PRUNE_DAEMON_LOG_FILE="${PRUNE_DAEMON_LOG_DIR}/prune-daemon.log"
}

# prune_daemon_running
# Check if daemon is running (background process)
# Returns 0 if running, 1 if not
prune_daemon_running() {
    _prune_daemon_init_paths
    if [[ -f "${PRUNE_DAEMON_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PRUNE_DAEMON_PID_FILE}")
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        # Stale PID file
        rm -f "${PRUNE_DAEMON_PID_FILE}"
    fi
    return 1
}

# prune_daemon_pid
# Get the PID of the running daemon
# Outputs: PID if running, empty if not
prune_daemon_pid() {
    _prune_daemon_init_paths
    if [[ -f "${PRUNE_DAEMON_PID_FILE}" ]]; then
        cat "${PRUNE_DAEMON_PID_FILE}"
    fi
}

# prune_daemon_start
# Start the daemon as background process
# Returns 0 on success, 1 on failure
prune_daemon_start() {
    _prune_daemon_init_paths
    if prune_daemon_running; then
        return 0
    fi

    # Ensure log directory exists
    mkdir -p "${PRUNE_DAEMON_LOG_DIR}"

    # Start the daemon in background
    nohup "${V0_DIR}/bin/v0-prune-daemon" >> "${PRUNE_DAEMON_LOG_FILE}" 2>&1 &
    local daemon_pid=$!

    # Write PID file
    echo "${daemon_pid}" > "${PRUNE_DAEMON_PID_FILE}"

    # Wait briefly to ensure daemon started
    sleep 0.2
    if ! prune_daemon_running; then
        rm -f "${PRUNE_DAEMON_PID_FILE}"
        return 1
    fi

    return 0
}

# prune_daemon_stop
# Stop the running daemon gracefully
prune_daemon_stop() {
    _prune_daemon_init_paths
    if ! prune_daemon_running; then
        return 0
    fi

    local pid
    pid=$(cat "${PRUNE_DAEMON_PID_FILE}")
    kill -TERM "${pid}" 2>/dev/null || true
    rm -f "${PRUNE_DAEMON_PID_FILE}"
}

# prune_daemon_wait
# Wait for daemon to complete current run and exit (for shutdown)
# Sends SIGTERM and waits up to 30 seconds
prune_daemon_wait() {
    _prune_daemon_init_paths
    if ! prune_daemon_running; then
        return 0
    fi

    local pid
    pid=$(prune_daemon_pid)
    kill -TERM "${pid}" 2>/dev/null

    # Wait up to 30 seconds for daemon to exit
    local count=0
    while [[ -f "${PRUNE_DAEMON_PID_FILE}" ]] && [[ $count -lt 30 ]]; do
        # Check if process is still running
        if ! kill -0 "${pid}" 2>/dev/null; then
            rm -f "${PRUNE_DAEMON_PID_FILE}"
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    # Force kill if still running after timeout
    if kill -0 "${pid}" 2>/dev/null; then
        kill -9 "${pid}" 2>/dev/null || true
        rm -f "${PRUNE_DAEMON_PID_FILE}"
    fi
}

# prune_daemon_trigger
# Signal daemon to run immediately (skip to next cycle)
prune_daemon_trigger() {
    _prune_daemon_init_paths
    if prune_daemon_running; then
        local pid
        pid=$(prune_daemon_pid)
        kill -USR1 "${pid}" 2>/dev/null || true
    fi
}
