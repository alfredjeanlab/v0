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

# _mq_is_mergeq_process <pid>
# Check if a PID is a v0-mergeq process
# Returns 0 if it is, 1 if not
_mq_is_mergeq_process() {
    local pid="$1"
    local cmd
    cmd=$(ps -o command= -p "${pid}" 2>/dev/null || true)
    [[ "${cmd}" == *"v0-mergeq"* ]]
}

# mq_daemon_running
# Check if daemon is running (background process)
# Returns 0 if running, 1 if not
mq_daemon_running() {
    if [[ -f "${DAEMON_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${DAEMON_PID_FILE}")
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            # Verify it's actually a mergeq process (not PID reuse)
            if _mq_is_mergeq_process "${pid}"; then
                return 0
            fi
            # PID exists but isn't mergeq - stale
            v0_trace "mergeq:daemon" "PID ${pid} exists but is not mergeq, cleaning up"
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

# _mq_cleanup_orphan_daemons
# Kill any orphan v0-mergeq processes not tracked by our PID file
# This prevents zombie daemons from accumulating
# Only kills processes running in our project's workspace (not other projects)
_mq_cleanup_orphan_daemons() {
    local tracked_pid=""
    if [[ -f "${DAEMON_PID_FILE}" ]]; then
        tracked_pid=$(cat "${DAEMON_PID_FILE}")
    fi

    # Get our project's state directory to identify our daemons
    # Daemons run from V0_WORKSPACE_DIR which is under V0_STATE_DIR
    local our_state_dir="${V0_STATE_DIR:-}"
    if [[ -z "${our_state_dir}" ]]; then
        # Can't identify our project, skip cleanup to be safe
        return 0
    fi

    # Find v0-mergeq --watch processes and check their working directories
    # We use ps to get both PID and working directory info
    local orphan_count=0

    # Get list of v0-mergeq PIDs
    local pids
    pids=$(pgrep -f "v0-mergeq.*--watch" 2>/dev/null || true)

    for pid in ${pids}; do
        if [[ "${pid}" == "${tracked_pid}" ]]; then
            continue
        fi

        # Check if this process is for our project by checking its cwd
        # Use lsof which works on both macOS and Linux
        local pid_cwd
        pid_cwd=$(lsof -p "${pid}" -Fn 2>/dev/null | grep "^ncwd" | sed 's/^n//' || true)

        # Only kill if cwd is within our state directory
        if [[ -n "${pid_cwd}" ]] && [[ "${pid_cwd}" == "${our_state_dir}"* ]]; then
            v0_trace "mergeq:daemon" "Killing orphan daemon process: ${pid} (cwd: ${pid_cwd})"
            kill "${pid}" 2>/dev/null || true
            orphan_count=$((orphan_count + 1))
        fi
    done

    if [[ ${orphan_count} -gt 0 ]]; then
        echo "Cleaned up ${orphan_count} orphan daemon process(es)" >&2
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

    # Clean up any orphan daemon processes before starting
    _mq_cleanup_orphan_daemons

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
# Stop the running daemon and clean up any orphans
mq_stop_daemon() {
    local stopped_any=false

    # Stop tracked daemon if running
    if mq_daemon_running; then
        local pid
        pid=$(cat "${DAEMON_PID_FILE}")
        v0_trace "mergeq:daemon" "Stopping daemon (pid: ${pid})"
        echo "Stopping merge queue worker (pid: ${pid})..."
        kill "${pid}" 2>/dev/null || true
        rm -f "${DAEMON_PID_FILE}"
        stopped_any=true
    fi

    # Also clean up any orphan daemon processes
    _mq_cleanup_orphan_daemons

    if [[ "${stopped_any}" = true ]]; then
        v0_trace "mergeq:daemon" "Daemon stopped"
        echo "Worker stopped"
    else
        echo "Worker not running"
    fi
}

# mq_ensure_daemon_running
# Ensure daemon is running, start if not
mq_ensure_daemon_running() {
    if mq_daemon_running; then
        return 0
    fi
    mq_start_daemon
}
