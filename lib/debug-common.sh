#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# debug-common.sh - Shared debug collection utilities for v0 self debug
# Source this to get common debug report generation functions

# Ensure v0-common.sh is sourced first
if [[ -z "${V0_INSTALL_DIR:-}" ]]; then
    echo "Error: debug-common.sh requires v0-common.sh to be sourced first" >&2
    exit 1
fi

# ============================================================================
# Report Generation Functions
# ============================================================================

# Generate YAML-style frontmatter for debug report
# Usage: generate_frontmatter <op_name> [type] [phase] [status]
generate_frontmatter() {
    local op_name="$1"
    local type="${2:-unknown}"
    local phase="${3:-unknown}"
    local status="${4:-unknown}"
    local machine
    machine=$(hostname 2>/dev/null || echo "unknown")

    cat <<EOF
---
v0-debug-report: true
operation: ${op_name}
type: ${type}
phase: ${phase}
status: ${status}
machine: ${machine}
generated_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
---
EOF
}

# Generate report summary section
# Usage: generate_summary <op_name> [state_file]
generate_summary() {
    local op_name="$1"
    local state_file="${2:-}"

    echo "# Debug Report: ${op_name}"
    echo ""
    echo "## Summary"
    echo ""

    if [[ -f "${state_file}" ]]; then
        local status phase
        status=$(jq -r '.status // "unknown"' "${state_file}")
        phase=$(jq -r '.phase // "unknown"' "${state_file}")
        echo "Operation **${op_name}** is in phase \`${phase}\` with status \`${status}\`."
    else
        echo "Debug report for \`${op_name}\`."
    fi
}

# Generate operation state section
# Usage: generate_operation_state <state_file>
generate_operation_state() {
    local state_file="$1"

    echo "## Operation State"
    echo ""

    if [[ -f "${state_file}" ]]; then
        echo '```json'
        jq '.' "${state_file}" 2>/dev/null || cat "${state_file}"
        echo '```'
    else
        echo "*No state file found*"
    fi
}

# Include a log file safely (with truncation for large files)
# Filters out debug report frontmatter to avoid recursive inclusion of tmux captures
# Usage: include_log_file <log_file> [max_lines] [label]
include_log_file() {
    local log_file="$1"
    local max_lines="${2:-500}"
    local label="${3:-Log}"

    if [[ ! -f "${log_file}" ]]; then
        echo "*No ${label} found*"
        return
    fi

    local line_count
    line_count=$(wc -l < "${log_file}" | tr -d ' ')

    echo '```'
    if (( line_count > max_lines )); then
        echo "# [Truncated: showing last ${max_lines} of ${line_count} lines]"
        tail -n "${max_lines}" "${log_file}" | filter_debug_frontmatter
    else
        filter_debug_frontmatter < "${log_file}"
    fi
    echo '```'
}

# Filter out debug report YAML frontmatter from log content
# This prevents tmux captures containing debug output from being included in logs
filter_debug_frontmatter() {
    grep -v -E '^(---|v0-debug-report:|operation:|type:|phase:|status:|machine:|generated_at:)' 2>/dev/null || cat
}

# Generate operation logs section
# Usage: generate_operation_logs <op_dir> [verbose]
generate_operation_logs() {
    local op_dir="$1"
    local verbose="${2:-false}"
    local logs_dir="${op_dir}/logs"

    echo "## Operation Logs"
    echo ""

    if [[ ! -d "${logs_dir}" ]]; then
        echo "*No logs directory found*"
        return
    fi

    # Feature log
    if [[ -f "${logs_dir}/feature.log" ]]; then
        echo "### Feature Log"
        echo ""
        include_log_file "${logs_dir}/feature.log" 500 "feature log"
        echo ""
    fi

    # Events log
    if [[ -f "${logs_dir}/events.log" ]]; then
        echo "### Events Log"
        echo ""
        include_log_file "${logs_dir}/events.log" 200 "events log"
        echo ""
    fi

    # Claude log
    if [[ -f "${logs_dir}/claude.log" ]]; then
        echo "### Claude Log"
        echo ""
        include_log_file "${logs_dir}/claude.log" 300 "claude log"
        echo ""
    fi

    # Verbose: include all other logs
    if [[ "${verbose}" = "true" ]]; then
        for log in "${logs_dir}"/*.log; do
            [[ -f "${log}" ]] || continue
            local basename
            basename=$(basename "${log}")
            # Skip already included
            [[ "${basename}" = "feature.log" ]] && continue
            [[ "${basename}" = "events.log" ]] && continue
            [[ "${basename}" = "claude.log" ]] && continue

            echo "### ${basename}"
            echo ""
            include_log_file "${log}" 200 "${basename}"
            echo ""
        done
    fi
}

# Generate git state section
# Usage: generate_git_state <repo_dir> [worktree_dir]
generate_git_state() {
    local repo_dir="$1"
    local worktree_dir="${2:-}"

    echo "## Git State"
    echo ""
    echo "### Main Repository"
    echo ""

    if [[ -d "${repo_dir}/.git" ]] || [[ -f "${repo_dir}/.git" ]]; then
        echo '```'
        echo "# git status"
        git -C "${repo_dir}" status --short 2>/dev/null || echo "(git status failed)"
        echo ""
        echo "# git log --oneline -5"
        git -C "${repo_dir}" log --oneline -5 2>/dev/null || echo "(git log failed)"
        echo ""
        echo "# git branch"
        git -C "${repo_dir}" branch 2>/dev/null || echo "(git branch failed)"
        echo '```'
    else
        echo "*Not a git repository*"
    fi

    # Worktree state if provided
    if [[ -n "${worktree_dir}" ]] && [[ -d "${worktree_dir}" ]]; then
        echo ""
        echo "### Worktree"
        echo ""
        if [[ -d "${worktree_dir}/.git" ]] || [[ -f "${worktree_dir}/.git" ]]; then
            echo '```'
            echo "# Path: ${worktree_dir}"
            echo ""
            echo "# git status"
            git -C "${worktree_dir}" status --short 2>/dev/null || echo "(git status failed)"
            echo ""
            echo "# git log --oneline -5"
            git -C "${worktree_dir}" log --oneline -5 2>/dev/null || echo "(git log failed)"
            echo ""
            echo "# git branch"
            git -C "${worktree_dir}" branch 2>/dev/null || echo "(git branch failed)"
            echo '```'
        else
            echo "*Worktree not initialized*"
        fi
    fi
}

# ============================================================================
# Type Detection Functions
# ============================================================================

# Detect operation type from name or state
# Usage: detect_operation_type <name>
# Returns: feature, plan, worker, daemon, phase, or unknown
detect_operation_type() {
    local name="$1"
    local state_file="${BUILD_DIR}/operations/${name}/state.json"

    # Check if it's a named operation with state
    if [[ -f "${state_file}" ]]; then
        jq -r '.type // "unknown"' "${state_file}"
        return
    fi

    # Check for worker/daemon types
    case "${name}" in
        fix|chore)
            echo "worker"
            ;;
        mergeq|merge|nudge)
            echo "daemon"
            ;;
        plan|decompose)
            echo "phase"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Find most recent operation by type
# Usage: find_most_recent_by_type <type>
find_most_recent_by_type() {
    local type="$1"
    local ops_dir="${BUILD_DIR}/operations"

    [[ ! -d "${ops_dir}" ]] && return 1

    local latest=""
    local latest_time=""

    for state_file in "${ops_dir}"/*/state.json; do
        [[ -f "${state_file}" ]] || continue

        local op_type
        op_type=$(jq -r '.type // "unknown"' "${state_file}")
        [[ "${op_type}" != "${type}" ]] && continue

        local created
        created=$(jq -r '.created_at // ""' "${state_file}")
        local op_name
        op_name=$(jq -r '.name' "${state_file}")

        if [[ -z "${latest_time}" ]] || [[ "${created}" > "${latest_time}" ]]; then
            latest_time="${created}"
            latest="${op_name}"
        fi
    done

    [[ -n "${latest}" ]] && echo "${latest}"
}

# Find most recent operation in a specific phase (or blocked_phase)
# Usage: find_most_recent_by_phase <phase>
find_most_recent_by_phase() {
    local phase="$1"
    local ops_dir="${BUILD_DIR}/operations"

    [[ ! -d "${ops_dir}" ]] && return 1

    local latest=""
    local latest_time=""

    for state_file in "${ops_dir}"/*/state.json; do
        [[ -f "${state_file}" ]] || continue

        local op_phase blocked_phase
        op_phase=$(jq -r '.phase // ""' "${state_file}")
        blocked_phase=$(jq -r '.blocked_phase // ""' "${state_file}")

        [[ "${op_phase}" != "${phase}" && "${blocked_phase}" != "${phase}" ]] && continue

        local created
        created=$(jq -r '.created_at // ""' "${state_file}")
        local op_name
        op_name=$(jq -r '.name' "${state_file}")

        if [[ -z "${latest_time}" ]] || [[ "${created}" > "${latest_time}" ]]; then
            latest_time="${created}"
            latest="${op_name}"
        fi
    done

    [[ -n "${latest}" ]] && echo "${latest}"
}

# Find worktree path for an operation
# Usage: find_worktree_path <op_name>
find_worktree_path() {
    local op_name="$1"

    # Check state for worktree path
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"
    if [[ -f "${state_file}" ]]; then
        local worktree
        worktree=$(jq -r '.worktree // empty' "${state_file}")
        if [[ -n "${worktree}" ]] && [[ -d "${worktree}" ]]; then
            echo "${worktree}"
            return
        fi
    fi

    # Check standard worktree location
    local worktree_path="${V0_STATE_DIR}/tree/${op_name}"
    if [[ -d "${worktree_path}" ]]; then
        echo "${worktree_path}"
        return
    fi

    # Check feature worktree location
    worktree_path="${V0_STATE_DIR}/tree/feature/${op_name}"
    if [[ -d "${worktree_path}" ]]; then
        echo "${worktree_path}"
        return
    fi
}

# ============================================================================
# Context Collection Functions
# ============================================================================

# Check if operation should include merge context
# Usage: should_include_merge_context <op_name>
should_include_merge_context() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    [[ ! -f "${state_file}" ]] && return 1

    local merge_queued
    merge_queued=$(jq -r '.merge_queued // false' "${state_file}")
    [[ "${merge_queued}" = "true" ]]
}

# Check if operation has dependencies
# Usage: has_dependencies <op_name>
has_dependencies() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    [[ ! -f "${state_file}" ]] && return 1

    local after
    after=$(jq -r '.after // empty' "${state_file}")
    [[ -n "${after}" ]]
}

# Get dependency name
# Usage: get_dependency <op_name>
get_dependency() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    [[ ! -f "${state_file}" ]] && return

    jq -r '.after // empty' "${state_file}"
}
