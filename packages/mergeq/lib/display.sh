#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/display.sh - Status and list formatting, event emission
#
# Depends on: io.sh (for mq_count_by_status, mq_is_lock_held, mq_get_lock_holder)
#             daemon.sh (for mq_daemon_running, mq_get_daemon_pid)
#             rules.sh (for status constants)
# IMPURE: Uses jq for formatting, file system operations

# Expected environment variables:
# V0_DIR - Path to v0 installation
# BUILD_DIR - Path to build directory
# QUEUE_FILE - Path to queue.json file
# DAEMON_PID_FILE - Path to daemon PID file

# mq_show_status
# Display queue status summary
mq_show_status() {
    mq_ensure_queue_exists

    local pending processing completed failed
    pending=$(mq_count_by_status "${MQ_STATUS_PENDING}")
    processing=$(mq_count_by_status "${MQ_STATUS_PROCESSING}")
    completed=$(mq_count_by_status "${MQ_STATUS_COMPLETED}")
    failed=$(jq "[.entries[] | select(.status == \"${MQ_STATUS_FAILED}\" or .status == \"${MQ_STATUS_CONFLICT}\")] | length" "${QUEUE_FILE}")

    if mq_daemon_running; then
        local pid
        pid=$(mq_get_daemon_pid)
        if [[ "${processing}" -gt 0 ]]; then
            echo "Merge Worker: Active (merging) [pid: ${pid}]"
        elif [[ "${pending}" -gt 0 ]]; then
            echo "Merge Worker: Active (pending) [pid: ${pid}]"
        else
            echo "Merge Worker: Polling [pid: ${pid}]"
        fi
    else
        echo "Merge Worker: Stopped"
    fi
    echo ""

    echo "Pending:    ${pending}"
    echo "Processing: ${processing}"
    echo "Completed:  ${completed}"
    echo "Failed:     ${failed}"

    if mq_is_lock_held; then
        echo ""
        echo "Lock held by: $(mq_get_lock_holder)"
    fi
}

# mq_list_entries
# List all queue entries
mq_list_entries() {
    mq_ensure_queue_exists

    local entries
    entries=$(jq -r '.entries[] | "\(.status)\t\(.operation)\t\(.priority)\t\(.enqueued_at)"' "${QUEUE_FILE}")

    if [[ -z "${entries}" ]]; then
        echo "Queue is empty"
        return 0
    fi

    echo "STATUS       OPERATION    PRIORITY  ENQUEUED"
    echo "------       ---------    --------  --------"
    echo "${entries}" | while IFS=$'\t' read -r status op priority enqueued; do
        printf "%-12s %-12s %-9s %s\n" "${status}" "${op}" "${priority}" "${enqueued}"
    done
}

# mq_emit_event <event> <operation>
# Emit event to notification hook
mq_emit_event() {
    local event="$1"
    local operation="$2"
    local hook="${BUILD_DIR}/hooks/on-event.sh"
    local template="${V0_DIR}/packages/cli/lib/templates/on-event.sh"

    # Install hook from template if missing
    if [[ ! -f "${hook}" ]] && [[ -f "${template}" ]]; then
        mkdir -p "$(dirname "${hook}")"
        cp "${template}" "${hook}"
        chmod +x "${hook}"
    fi

    if [[ -x "${hook}" ]]; then
        echo "{\"event\":\"${event}\",\"operation\":\"${operation}\"}" | "${hook}" 2>/dev/null || true
    fi
}

# mq_log_event <message>
# Log an event to the merges.log file
mq_log_event() {
    local message="$1"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${message}" >> "${MERGEQ_DIR}/logs/merges.log"
}
