#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/daemon.sh - Daemon process control
#
# Depends on: io.sh (for mq_ensure_queue_exists)
# IMPURE: Uses process management, nohup, file system operations

# Expected environment variables:
# V0_DIR - Path to v0 installation
# V0_WORKSPACE_DIR - Path to workspace directory (replaces MAIN_REPO)
# MERGEQ_DIR - Directory for merge queue state
# DAEMON_PID_FILE - Path to daemon PID file (typically ${MERGEQ_DIR}/.daemon.pid)
# DAEMON_LOG_FILE - Path to daemon log file (typically ${MERGEQ_DIR}/logs/daemon.log)
# C_GREEN, C_DIM, C_BOLD, C_RESET - Color codes from v0-common.sh

# mq_daemon_running
# Check if daemon is running (background process)
# Returns 0 if running, 1 if not
mq_daemon_running() {
    if [[ -f "${DAEMON_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${DAEMON_PID_FILE}")
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        # Stale PID file
        rm -f "${DAEMON_PID_FILE}"
    fi
    return 1
}

# mq_get_daemon_pid
# Get the PID of the running daemon
# Outputs: PID if running, empty if not
mq_get_daemon_pid() {
    if [[ -f "${DAEMON_PID_FILE}" ]]; then
        cat "${DAEMON_PID_FILE}"
    fi
}

# mq_start_daemon
# Start the daemon as background process
# Returns 0 on success, 1 on failure
mq_start_daemon() {
    if mq_daemon_running; then
        echo "Worker already running (pid: $(cat "${DAEMON_PID_FILE}"))"
        return 0
    fi

    v0_trace "mergeq:daemon" "Starting merge queue daemon"
    mq_ensure_queue_exists
    echo "Starting merge queue worker..."

    # Ensure workspace exists for merge operations
    if ! ws_ensure_workspace; then
        v0_trace "mergeq:daemon:failed" "Failed to create workspace for merge operations"
        echo "Error: Failed to create workspace for merge operations" >&2
        return 1
    fi

    # Start the daemon from the workspace directory
    # The workspace is dedicated to merge operations and is always on V0_DEVELOP_BRANCH
    #
    # IMPORTANT: Export key variables so the child process inherits them.
    # The v0-mergeq script checks if these are already set and skips recomputation.
    # Without this:
    # - BUILD_DIR/MERGEQ_DIR: if workspace becomes invalid, v0_find_main_repo()
    #   would return workspace path instead of main repo, causing state files
    #   to be written to wrong location
    # - V0_DEVELOP_BRANCH: workspace doesn't have .v0.profile.rc (gitignored),
    #   so config loading defaults to "main" instead of user's branch, causing
    #   workspace mismatch detection and failed recreation attempts
    export MERGEQ_DIR
    export BUILD_DIR
    export V0_DEVELOP_BRANCH
    local old_pwd="${PWD}"
    cd "${V0_WORKSPACE_DIR}"
    nohup "${V0_DIR}/bin/v0-mergeq" --watch >> "${DAEMON_LOG_FILE}" 2>&1 &
    local daemon_pid=$!
    cd "${old_pwd}"

    # Write PID file
    echo "${daemon_pid}" > "${DAEMON_PID_FILE}"

    # Wait briefly to ensure daemon started
    sleep 0.5
    if ! mq_daemon_running; then
        echo "Error: Daemon failed to start"
        rm -f "${DAEMON_PID_FILE}"
        return 1
    fi

    v0_trace "mergeq:daemon" "Daemon started (pid: ${daemon_pid})"
    echo -e "${C_GREEN}Worker started${C_RESET} ${C_DIM}(pid: ${daemon_pid})${C_RESET}"
    echo ""
    echo -e "Status:    ${C_BOLD}v0 mergeq --status${C_RESET}"
    echo -e "View logs: ${C_BOLD}tail -f ${DAEMON_LOG_FILE}${C_RESET}"
}

# mq_stop_daemon
# Stop the running daemon
mq_stop_daemon() {
    if ! mq_daemon_running; then
        echo "Worker not running"
        return 0
    fi

    local pid
    pid=$(cat "${DAEMON_PID_FILE}")
    v0_trace "mergeq:daemon" "Stopping daemon (pid: ${pid})"
    echo "Stopping merge queue worker (pid: ${pid})..."
    kill "${pid}" 2>/dev/null || true
    rm -f "${DAEMON_PID_FILE}"
    v0_trace "mergeq:daemon" "Daemon stopped"
    echo "Worker stopped"
}

# mq_ensure_daemon_running
# Ensure daemon is running, start if not
mq_ensure_daemon_running() {
    if mq_daemon_running; then
        return 0
    fi
    mq_start_daemon
}
