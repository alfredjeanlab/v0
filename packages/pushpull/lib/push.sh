#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# push.sh - Push user branch to agent branch
#
# Functions for resetting the agent branch (V0_DEVELOP_BRANCH)
# to match the current/specified user branch state.

# pp_get_last_push_commit
# Get the commit hash from last v0 push (stored in .v0/last-push)
pp_get_last_push_commit() {
    local marker_file="${V0_ROOT}/.v0/last-push"
    if [[ -f "${marker_file}" ]]; then
        cat "${marker_file}"
    fi
}

# pp_set_last_push_commit <commit>
# Record the commit hash of current push
pp_set_last_push_commit() {
    local commit="$1"
    mkdir -p "${V0_ROOT}/.v0"
    echo "${commit}" > "${V0_ROOT}/.v0/last-push"
}

# pp_agent_has_diverged
# Check if agent branch has commits since last push
# Returns 0 if diverged (has new commits), 1 if not
pp_agent_has_diverged() {
    local agent_branch remote_ref last_push current_agent
    local remote="${V0_GIT_REMOTE:-origin}"
    agent_branch=$(pp_get_agent_branch)
    remote_ref="${remote}/${agent_branch}"

    # Fetch latest state
    git fetch "${remote}" "${agent_branch}" 2>/dev/null || true

    last_push=$(pp_get_last_push_commit)
    if [[ -z "${last_push}" ]]; then
        # No record of last push - check if agent has any commits not on current branch
        # If agent is ancestor of HEAD, no divergence
        if git merge-base --is-ancestor "${remote_ref}" HEAD 2>/dev/null; then
            return 1  # Not diverged
        fi
        return 0  # Diverged (agent has commits not in HEAD)
    fi

    current_agent=$(git rev-parse "${remote_ref}" 2>/dev/null || echo "")
    if [[ "${current_agent}" == "${last_push}" ]]; then
        return 1  # Not diverged
    fi

    # Agent has moved - check if there are commits on agent since our last push
    local new_commits
    new_commits=$(git log --oneline "${last_push}..${remote_ref}" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${new_commits}" -gt 0 ]]; then
        return 0  # Diverged
    fi

    return 1  # Not diverged
}

# pp_show_divergence
# Show commits on agent branch since last push
pp_show_divergence() {
    local agent_branch remote_ref last_push
    local remote="${V0_GIT_REMOTE:-origin}"
    agent_branch=$(pp_get_agent_branch)
    remote_ref="${remote}/${agent_branch}"
    last_push=$(pp_get_last_push_commit)

    if [[ -n "${last_push}" ]]; then
        echo "Commits on agent since last push:"
        git log --oneline "${last_push}..${remote_ref}"
    else
        echo "Commits on agent not in current branch:"
        git log --oneline "HEAD..${remote_ref}"
    fi
}

# pp_do_push <source_branch>
# Reset agent branch to source_branch
pp_do_push() {
    local source_branch="$1"
    local agent_branch source_commit
    local remote="${V0_GIT_REMOTE:-origin}"
    agent_branch=$(pp_get_agent_branch)
    source_commit=$(git rev-parse "${source_branch}")

    # Push with force to reset agent branch
    if git push "${remote}" "${source_branch}:${agent_branch}" --force; then
        pp_set_last_push_commit "${source_commit}"
        echo "Agent branch ${agent_branch} reset to ${source_branch}"
        return 0
    fi

    echo "Error: Push failed"
    return 1
}
