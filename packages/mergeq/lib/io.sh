#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/io.sh - Queue file I/O operations
#
# Depends on: rules.sh (for status constants)
# IMPURE: Uses jq, mktemp, mv, mkdir

# Expected environment variables:
# MERGEQ_DIR - Directory for merge queue state
# QUEUE_FILE - Path to queue.json file

# mq_ensure_queue_exists
# Create queue directory and file if missing
mq_ensure_queue_exists() {
    mkdir -p "${MERGEQ_DIR}/logs"
    if [[ ! -f "${QUEUE_FILE}" ]]; then
        echo '{"version":1,"entries":[]}' > "${QUEUE_FILE}"
    fi
}

# mq_atomic_queue_update <jq_filter>
# Atomic file update using write-to-temp + rename pattern
# Returns 0 on success, 1 on failure
mq_atomic_queue_update() {
    local jq_filter="$1"
    local tmp
    tmp=$(mktemp)

    if ! jq "${jq_filter}" "${QUEUE_FILE}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        echo "Error: Failed to update queue" >&2
        return 1
    fi

    mv "${tmp}" "${QUEUE_FILE}"
}

# mq_read_queue
# Read entire queue JSON
# Outputs: Queue JSON
mq_read_queue() {
    cat "${QUEUE_FILE}"
}

# mq_read_entry <operation>
# Read a single entry from the queue
# Outputs: Entry JSON or empty if not found
mq_read_entry() {
    local operation="$1"
    jq -r ".entries[] | select(.operation == \"${operation}\")" "${QUEUE_FILE}"
}

# mq_read_entry_field <operation> <field>
# Read a specific field from a queue entry
# Outputs: Field value or "null" if not found
mq_read_entry_field() {
    local operation="$1"
    local field="$2"
    jq -r ".entries[] | select(.operation == \"${operation}\") | .${field} // \"null\"" "${QUEUE_FILE}"
}

# mq_entry_exists <operation>
# Check if an entry exists in the queue
# Returns 0 if exists, 1 if not
mq_entry_exists() {
    local operation="$1"
    local exists
    exists=$(jq -r ".entries[] | select(.operation == \"${operation}\") | .operation" "${QUEUE_FILE}")
    [[ -n "${exists}" ]]
}

# mq_get_entry_status <operation>
# Get the status of a queue entry
# Outputs: Status string or empty if not found
mq_get_entry_status() {
    local operation="$1"
    jq -r ".entries[] | select(.operation == \"${operation}\") | .status // empty" "${QUEUE_FILE}"
}

# mq_add_entry <operation> <worktree> <priority> <merge_type> [issue_id]
# Add a new entry to the queue
# Returns 0 on success, 1 on failure
mq_add_entry() {
    local operation="$1"
    local worktree="$2"
    local priority="${3:-0}"
    local merge_type="${4:-operation}"
    local issue_id="${5:-}"

    local enqueued_at
    enqueued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build the entry with optional issue_id
    local issue_id_field=""
    if [[ -n "${issue_id}" ]]; then
        issue_id_field="\"issue_id\": \"${issue_id}\","
    fi

    mq_atomic_queue_update ".entries += [{
        \"operation\": \"${operation}\",
        \"worktree\": \"${worktree}\",
        \"priority\": ${priority},
        \"enqueued_at\": \"${enqueued_at}\",
        \"status\": \"${MQ_STATUS_PENDING}\",
        \"merge_type\": \"${merge_type}\",
        ${issue_id_field}
        \"_\": null
    }] | .entries[-1] |= del(._)"
}

# mq_update_entry_status <operation> <status>
# Update the status of a queue entry
# Returns 0 on success, 1 on failure
mq_update_entry_status() {
    local operation="$1"
    local status="$2"

    if [[ -z "${operation}" ]] || [[ -z "${status}" ]]; then
        echo "Error: Operation and status required" >&2
        return 1
    fi

    # Check if entry exists
    if ! mq_entry_exists "${operation}"; then
        echo "Error: Operation '${operation}' not found in queue" >&2
        return 1
    fi

    local updated_at
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mq_atomic_queue_update "(.entries[] | select(.operation == \"${operation}\")) |= . + {
        \"status\": \"${status}\",
        \"updated_at\": \"${updated_at}\"
    }"
}

# mq_reenqueue_entry <operation> <priority>
# Re-enqueue an existing entry (reset status to pending)
# Returns 0 on success, 1 on failure
mq_reenqueue_entry() {
    local operation="$1"
    local priority="${2:-0}"

    local enqueued_at
    enqueued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mq_atomic_queue_update "(.entries[] | select(.operation == \"${operation}\")) |= . + {
        \"status\": \"${MQ_STATUS_PENDING}\",
        \"enqueued_at\": \"${enqueued_at}\",
        \"priority\": ${priority}
    }"
}

# mq_get_pending_operations
# Get all pending operations sorted by priority, then by enqueue time
# Outputs: One operation name per line
mq_get_pending_operations() {
    jq -r "[.entries[] | select(.status == \"${MQ_STATUS_PENDING}\")] | sort_by(.priority, .enqueued_at) | .[].operation" "${QUEUE_FILE}"
}

# mq_get_next_pending
# Get the next pending operation (highest priority, oldest)
# Outputs: Operation name or empty if none pending
mq_get_next_pending() {
    jq -r "[.entries[] | select(.status == \"${MQ_STATUS_PENDING}\")] | sort_by(.priority, .enqueued_at) | .[0].operation // empty" "${QUEUE_FILE}"
}

# mq_get_operations_by_status <status>
# Get all operations with a specific status
# Outputs: One operation name per line
mq_get_operations_by_status() {
    local status="$1"
    jq -r ".entries[] | select(.status == \"${status}\") | .operation" "${QUEUE_FILE}"
}

# mq_count_by_status <status>
# Count entries with a specific status
# Outputs: Count number
mq_count_by_status() {
    local status="$1"
    jq "[.entries[] | select(.status == \"${status}\")] | length" "${QUEUE_FILE}"
}

# mq_get_issue_id <operation>
# Get the issue_id associated with a queue entry (if any)
# Outputs: Issue ID or empty if not set
mq_get_issue_id() {
    local operation="$1"
    jq -r ".entries[] | select(.operation == \"${operation}\") | .issue_id // empty" "${QUEUE_FILE}"
}

# mq_update_entry_field <operation> <field> <value>
# Update a custom field on a queue entry
# Value should be a valid JSON value (e.g., "true", "\"string\"", "123")
# Returns 0 on success, 1 on failure
mq_update_entry_field() {
    local operation="$1"
    local field="$2"
    local value="$3"

    if [[ -z "${operation}" ]] || [[ -z "${field}" ]]; then
        echo "Error: Operation and field required" >&2
        return 1
    fi

    # Check if entry exists
    if ! mq_entry_exists "${operation}"; then
        echo "Error: Operation '${operation}' not found in queue" >&2
        return 1
    fi

    mq_atomic_queue_update "(.entries[] | select(.operation == \"${operation}\")) |= . + {
        \"${field}\": ${value}
    }"
}
