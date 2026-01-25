#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/locking.sh - Queue file locking
#
# Depends on: (none)
# IMPURE: Uses file system operations, process signals

# Expected environment variables:
# QUEUE_LOCK - Path to queue lock file

# mq_acquire_lock
# Acquire the queue lock with stale detection
# Returns 0 on success, 1 if lock held by another process
mq_acquire_lock() {
    if [[ -f "${QUEUE_LOCK}" ]]; then
        # Stale check: if PID in lock is dead, remove it
        local holder_pid
        holder_pid=$(grep -oE 'pid [0-9]+' "${QUEUE_LOCK}" 2>/dev/null | grep -oE '[0-9]+' || true)
        if [[ -n "${holder_pid}" ]] && ! kill -0 "${holder_pid}" 2>/dev/null; then
            rm -f "${QUEUE_LOCK}"
        else
            local holder
            holder=$(cat "${QUEUE_LOCK}" 2>/dev/null || echo "unknown")
            echo "Error: Queue lock held by: ${holder}" >&2
            return 1
        fi
    fi
    echo "mergeq (pid $$)" > "${QUEUE_LOCK}"
    trap 'rm -f "${QUEUE_LOCK}"' EXIT
}

# mq_release_lock
# Release the queue lock
mq_release_lock() {
    rm -f "${QUEUE_LOCK}"
    trap - EXIT
}

# mq_is_lock_held
# Check if the queue lock is currently held
# Returns 0 if held, 1 if not
mq_is_lock_held() {
    [[ -f "${QUEUE_LOCK}" ]]
}

# mq_get_lock_holder
# Get information about who holds the lock
# Outputs: Lock holder info or empty if not locked
mq_get_lock_holder() {
    if [[ -f "${QUEUE_LOCK}" ]]; then
        cat "${QUEUE_LOCK}" 2>/dev/null || echo "unknown"
    fi
}

# mq_acquire_lock_with_retry <max_retries> <initial_delay>
# Acquire lock with exponential backoff retry
# Returns 0 on success, 1 if all retries exhausted
mq_acquire_lock_with_retry() {
    local max_retries="${1:-5}"
    local retry_delay="${2:-1}"

    for i in $(seq 1 "${max_retries}"); do
        if mq_acquire_lock 2>/dev/null; then
            return 0
        fi
        if [[ ${i} -lt ${max_retries} ]]; then
            sleep "${retry_delay}"
            retry_delay=$((retry_delay * 2))
        fi
    done

    echo "Error: Could not acquire queue lock after ${max_retries} attempts" >&2
    return 1
}

# mq_with_lock <command...>
# Execute a command with the lock held
# Returns the exit code of the command
mq_with_lock() {
    mq_acquire_lock || return 1
    "$@"
    local exit_code=$?
    mq_release_lock
    return ${exit_code}
}
