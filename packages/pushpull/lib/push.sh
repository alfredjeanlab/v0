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
# Check if agent branch has commits we haven't incorporated
# Returns 0 if diverged (has commits not in HEAD), 1 if not
pp_agent_has_diverged() {
    local agent_branch remote_ref
    local remote="${V0_GIT_REMOTE:-origin}"
    agent_branch=$(pp_get_agent_branch)
    remote_ref="${remote}/${agent_branch}"

    # Fetch latest state
    git fetch "${remote}" "${agent_branch}" 2>/dev/null || true

    # If remote ref doesn't exist, we haven't diverged (nothing to diverge from)
    if ! git rev-parse --verify "${remote_ref}" >/dev/null 2>&1; then
        return 1  # Not diverged
    fi

    # If agent is an ancestor of HEAD, we've already incorporated all agent commits
    # (either via pull, merge, or local commits that include the agent's work)
    if git merge-base --is-ancestor "${remote_ref}" HEAD 2>/dev/null; then
        return 1  # Not diverged - we have all agent commits
    fi

    # Agent has commits not in HEAD
    return 0  # Diverged
}

# pp_show_divergence
# Show commits on agent branch not yet in HEAD
pp_show_divergence() {
    local agent_branch remote_ref
    local remote="${V0_GIT_REMOTE:-origin}"
    agent_branch=$(pp_get_agent_branch)
    remote_ref="${remote}/${agent_branch}"

    echo "Commits on agent not in current branch:"
    git log --oneline "HEAD..${remote_ref}"
}

# pp_do_push <source_branch>
# Reset agent branch to source_branch
pp_do_push() {
    local source_branch="$1"
    local agent_branch source_commit
    local remote="${V0_GIT_REMOTE:-origin}"
    agent_branch=$(pp_get_agent_branch)
    source_commit=$(git rev-parse "${source_branch}")

    # Push with force to reset remote agent branch
    if git push "${remote}" "${source_branch}:${agent_branch}" --force; then
        pp_set_last_push_commit "${source_commit}"

        # Also update local agent branch if it exists and isn't in use
        if git rev-parse --verify "${agent_branch}" >/dev/null 2>&1; then
            # Check if branch is checked out in a worktree
            local worktree_path
            worktree_path=$(git worktree list --porcelain | grep -A1 "^worktree " | grep -B1 "branch refs/heads/${agent_branch}$" | head -1 | sed 's/^worktree //')
            if [[ -n "${worktree_path}" ]]; then
                # Branch is in use by a worktree; skip local update (remote was already updated)
                true
            else
                git branch -f "${agent_branch}" "${source_commit}"
            fi
        fi

        echo "Agent branch ${agent_branch} reset to ${source_branch}"
        return 0
    fi

    echo "Error: Push failed"
    return 1
}
