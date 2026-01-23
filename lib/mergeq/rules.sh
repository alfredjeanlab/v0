#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/rules.sh - Pure business logic for merge queue
#
# This module contains no I/O operations (no jq, git, tmux, etc.)
# All functions here operate on values passed as arguments.

# Queue entry status values
readonly MQ_STATUS_PENDING="pending"
readonly MQ_STATUS_PROCESSING="processing"
readonly MQ_STATUS_COMPLETED="completed"
readonly MQ_STATUS_FAILED="failed"
readonly MQ_STATUS_CONFLICT="conflict"
readonly MQ_STATUS_RESUMED="resumed"

# mq_is_active_status <status>
# Check if status represents an active (in-progress) state
# Returns 0 (true) if active, 1 (false) if not
mq_is_active_status() {
    local status="$1"
    [[ "${status}" = "${MQ_STATUS_PENDING}" ]] || [[ "${status}" = "${MQ_STATUS_PROCESSING}" ]]
}

# mq_is_terminal_status <status>
# Check if status represents a terminal (finished) state
# Returns 0 (true) if terminal, 1 (false) if not
mq_is_terminal_status() {
    local status="$1"
    [[ "${status}" = "${MQ_STATUS_COMPLETED}" ]] || \
    [[ "${status}" = "${MQ_STATUS_FAILED}" ]] || \
    [[ "${status}" = "${MQ_STATUS_CONFLICT}" ]]
}

# mq_is_pending_status <status>
# Check if status is pending (ready to process)
# Returns 0 (true) if pending, 1 (false) if not
mq_is_pending_status() {
    local status="$1"
    [[ "${status}" = "${MQ_STATUS_PENDING}" ]]
}

# mq_is_retriable_status <status>
# Check if status allows retry (can be re-enqueued)
# Returns 0 (true) if retriable, 1 (false) if not
mq_is_retriable_status() {
    local status="$1"
    [[ "${status}" = "${MQ_STATUS_RESUMED}" ]] || \
    [[ "${status}" = "${MQ_STATUS_COMPLETED}" ]] || \
    [[ "${status}" = "${MQ_STATUS_FAILED}" ]] || \
    [[ "${status}" = "${MQ_STATUS_CONFLICT}" ]]
}

# mq_compare_priority <priority1> <time1> <priority2> <time2>
# Compare two queue entries by priority (lower is higher priority), then by time (earlier first)
# Outputs: -1 if entry1 comes first, 1 if entry2 comes first, 0 if equal
mq_compare_priority() {
    local priority1="$1"
    local time1="$2"
    local priority2="$3"
    local time2="$4"

    # Compare by priority first (lower number = higher priority)
    if [[ "${priority1}" -lt "${priority2}" ]]; then
        echo "-1"
        return
    elif [[ "${priority1}" -gt "${priority2}" ]]; then
        echo "1"
        return
    fi

    # Same priority - compare by time (earlier = higher priority)
    # ISO 8601 timestamps can be compared lexicographically
    if [[ "${time1}" < "${time2}" ]]; then
        echo "-1"
    elif [[ "${time1}" > "${time2}" ]]; then
        echo "1"
    else
        echo "0"
    fi
}

# mq_is_branch_pattern <operation>
# Check if operation name looks like a branch (contains a slash)
# This is a heuristic check - actual branch verification requires git
# Returns 0 (true) if looks like a branch, 1 (false) if not
mq_is_branch_pattern() {
    local op="$1"
    [[ "${op}" == */* ]]
}

# mq_default_merge_type <operation>
# Determine default merge type based on operation name pattern
# Outputs: "branch" if looks like a branch, "operation" otherwise
mq_default_merge_type() {
    local op="$1"
    if mq_is_branch_pattern "${op}"; then
        echo "branch"
    else
        echo "operation"
    fi
}
