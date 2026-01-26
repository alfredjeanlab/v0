#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq-common.sh - Compatibility shim for merge queue functionality
#
# This file provides backward compatibility for scripts that source
# merge queue functions. It sources the new modular queue.sh orchestrator.

_MERGEQ_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_MERGEQ_COMMON_DIR}/queue.sh"

# Compatibility aliases for old function names
# These map to the new mq_* prefixed functions

# Locking functions
acquire_queue_lock() { mq_acquire_lock "$@"; }
release_queue_lock() { mq_release_lock "$@"; }

# I/O functions
ensure_queue_exists() { mq_ensure_queue_exists "$@"; }
atomic_queue_update() { mq_atomic_queue_update "$@"; }

# Daemon functions
daemon_running() { mq_daemon_running "$@"; }
start_daemon() { mq_start_daemon "$@"; }
stop_daemon() { mq_stop_daemon "$@"; }
ensure_daemon_running() { mq_ensure_daemon_running "$@"; }

# Display functions
show_status() { mq_show_status "$@"; }
list_entries() { mq_list_entries "$@"; }
emit_event() { mq_emit_event "$@"; }

# Queue operations
enqueue_merge() { mq_enqueue "$@"; }
dequeue_merge() { mq_dequeue_merge "$@"; }
update_entry() { mq_update_entry_status "$@"; }
get_issue_id() { mq_get_issue_id "$@"; }

# Readiness checks
is_stale() { mq_is_stale "$@"; }
is_branch_merge() { mq_is_branch_merge "$@"; }
is_branch_ready() { mq_is_branch_ready "$@"; }
is_merge_ready() { mq_is_merge_ready "$@"; }
get_all_pending() { mq_get_all_pending "$@"; }
get_all_conflicts() { mq_get_all_conflicts "$@"; }

# Processing functions
process_merge() { mq_process_merge "$@"; }
process_branch_merge() { mq_process_branch_merge "$@"; }
process_once() { mq_process_once "$@"; }
process_watch() { mq_process_watch "$@"; }
