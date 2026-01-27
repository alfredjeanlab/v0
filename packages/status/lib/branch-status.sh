#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
#
# Branch status display functions
# Shows ahead/behind status for V0_DEVELOP_BRANCH from agent's perspective

# Show ahead/behind status line for develop branch
# Displays status from agent branch perspective:
#   ⇡N (green) = agent is N commits ahead of current branch
#   ⇣N (red) = agent is N commits behind current branch
# Suggests v0 pull (if agent ahead) or v0 push (if agent strictly behind)
#
# Returns: 0 if status line was displayed, 1 if nothing to display
show_branch_status() {
    local develop_branch="${V0_DEVELOP_BRANCH:-main}"
    local remote="${V0_GIT_REMOTE:-origin}"
    local current_branch

    # Get current branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1

    # Skip if we're on the develop branch itself (worktree mode only)
    # In clone mode, user is expected to be on the develop branch (e.g., main)
    # and we still want to show ahead/behind vs origin
    if [[ "${V0_WORKSPACE_MODE}" != "clone" ]]; then
        [[ "${current_branch}" = "${develop_branch}" ]] && return 1
    fi

    # Fetch to ensure we have latest remote info (quiet, don't fail on error)
    git fetch "${remote}" "${develop_branch}" --quiet 2>/dev/null || true

    # Get ahead/behind counts between current branch and remote develop branch
    # Format: left<tab>right (left = commits in remote, right = commits in HEAD)
    local counts
    counts=$(git rev-list --left-right --count "${remote}/${develop_branch}...HEAD" 2>/dev/null) || return 1

    # From agent's perspective:
    # - agent_ahead = commits agent has that current doesn't (left side)
    # - agent_behind = commits current has that agent doesn't (right side)
    local agent_ahead agent_behind
    agent_ahead=$(echo "${counts}" | cut -f1)
    agent_behind=$(echo "${counts}" | cut -f2)

    # Nothing to display if in sync
    [[ "${agent_ahead}" = "0" ]] && [[ "${agent_behind}" = "0" ]] && return 1

    # Check if TTY for colors (or force color enabled)
    local is_tty=""
    { [[ -t 1 ]] || [[ -n "${V0_FORCE_COLOR:-}" ]]; } && is_tty=1

    # Build display string from agent's perspective
    local display=""
    local state_label=""
    local suggestion=""

    if [[ "${agent_ahead}" != "0" ]]; then
        if [[ -n "${is_tty}" ]]; then
            display="${C_GREEN}⇡${agent_ahead}${C_RESET}"
        else
            display="⇡${agent_ahead}"
        fi
        state_label="ahead"
    fi

    if [[ "${agent_behind}" != "0" ]]; then
        if [[ -n "${is_tty}" ]]; then
            [[ -n "${display}" ]] && display="${display} "
            display="${display}${C_RED}⇣${agent_behind}${C_RESET}"
        else
            [[ -n "${display}" ]] && display="${display} "
            display="${display}⇣${agent_behind}"
        fi
        # Only set "behind" label if not already "ahead" (ahead takes priority)
        [[ -z "${state_label}" ]] && state_label="behind"
    fi

    # Build the branch display name
    # For common branch names (main, develop, master) that might be confused with
    # local branches, show full remote ref (remote/branch) for clarity
    local branch_display="${develop_branch}"
    case "${develop_branch}" in
        main|develop|master)
            branch_display="${remote}/${develop_branch}"
            ;;
    esac

    # Determine suggestion based on agent's status
    if [[ "${agent_ahead}" != "0" ]]; then
        # Agent has commits to pull
        if [[ -n "${is_tty}" ]]; then
            suggestion="${C_DIM}(use${C_RESET} ${C_CYAN}v0 pull${C_RESET} ${C_DIM}to merge them to${C_RESET} ${C_GREEN}${current_branch}${C_RESET}${C_DIM})${C_RESET}"
        else
            suggestion="(use v0 pull to merge them to ${current_branch})"
        fi
    elif [[ "${agent_behind}" != "0" ]]; then
        # Agent is strictly behind, suggest push
        if [[ -n "${is_tty}" ]]; then
            suggestion="${C_DIM}(use${C_RESET} ${C_CYAN}v0 push${C_RESET} ${C_DIM}to send them to${C_RESET} ${C_GREEN}${branch_display}${C_RESET}${C_DIM})${C_RESET}"
        else
            suggestion="(use v0 push to send them to ${branch_display})"
        fi
    fi

    # Output from agent's perspective
    if [[ -n "${is_tty}" ]]; then
        echo -e "Changes: ${C_GREEN}${branch_display}${C_RESET} is ${display} ${state_label} ${suggestion}"
    else
        echo -e "Changes: ${branch_display} is ${display} ${state_label} ${suggestion}"
    fi
    return 0
}
