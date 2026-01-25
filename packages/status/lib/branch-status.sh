#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
#
# Branch status display functions
# Shows ahead/behind status for V0_DEVELOP_BRANCH vs current branch

# Show ahead/behind status line for develop branch
# Displays ⇡N (green) for ahead, ⇣N (red) for behind
# Suggests v0 push (if strictly ahead) or v0 pull (if any behind)
#
# Returns: 0 if status line was displayed, 1 if nothing to display
show_branch_status() {
    local develop_branch="${V0_DEVELOP_BRANCH:-agent}"
    local remote="${V0_GIT_REMOTE:-origin}"
    local current_branch

    # Get current branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1

    # Skip if we're on the develop branch itself
    [[ "${current_branch}" = "${develop_branch}" ]] && return 1

    # Fetch to ensure we have latest remote info (quiet, don't fail on error)
    git fetch "${remote}" "${develop_branch}" --quiet 2>/dev/null || true

    # Get ahead/behind counts between current branch and remote develop branch
    # Format: ahead<tab>behind
    local counts
    counts=$(git rev-list --left-right --count "${remote}/${develop_branch}...HEAD" 2>/dev/null) || return 1

    local behind ahead
    behind=$(echo "${counts}" | cut -f1)
    ahead=$(echo "${counts}" | cut -f2)

    # Nothing to display if in sync
    [[ "${behind}" = "0" ]] && [[ "${ahead}" = "0" ]] && return 1

    # Check if TTY for colors
    local is_tty=""
    [[ -t 1 ]] && is_tty=1

    # Build display string
    local display=""
    local suggestion=""

    if [[ "${ahead}" != "0" ]]; then
        if [[ -n "${is_tty}" ]]; then
            display="${C_GREEN}⇡${ahead}${C_RESET}"
        else
            display="⇡${ahead}"
        fi
    fi

    if [[ "${behind}" != "0" ]]; then
        if [[ -n "${is_tty}" ]]; then
            [[ -n "${display}" ]] && display="${display} "
            display="${display}${C_RED}⇣${behind}${C_RESET}"
        else
            [[ -n "${display}" ]] && display="${display} "
            display="${display}⇣${behind}"
        fi
    fi

    # Determine suggestion
    if [[ "${behind}" != "0" ]]; then
        # Any behind means we should pull first
        if [[ -n "${is_tty}" ]]; then
            suggestion="${C_DIM}(v0 pull)${C_RESET}"
        else
            suggestion="(v0 pull)"
        fi
    elif [[ "${ahead}" != "0" ]]; then
        # Strictly ahead, suggest push
        if [[ -n "${is_tty}" ]]; then
            suggestion="${C_DIM}(v0 push)${C_RESET}"
        else
            suggestion="(v0 push)"
        fi
    fi

    echo -e "${current_branch} ${display} ${suggestion}"
    return 0
}
