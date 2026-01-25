#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# pull.sh - Pull agent changes into user branch
#
# Functions for merging changes from the agent branch (V0_DEVELOP_BRANCH)
# into the current/specified user branch.

# pp_get_agent_branch
# Returns the agent branch name (from V0_DEVELOP_BRANCH config)
pp_get_agent_branch() {
    echo "${V0_DEVELOP_BRANCH:-agent}"
}

# pp_resolve_target_branch [branch]
# Returns the target branch - specified branch or current branch
pp_resolve_target_branch() {
    local branch="${1:-}"
    if [[ -n "${branch}" ]]; then
        echo "${branch}"
    else
        git rev-parse --abbrev-ref HEAD
    fi
}

# pp_fetch_agent_branch
# Fetch latest from remote agent branch
# Returns 0 on success, 1 on failure
pp_fetch_agent_branch() {
    local agent_branch
    agent_branch=$(pp_get_agent_branch)
    git fetch "${V0_GIT_REMOTE:-origin}" "${agent_branch}" 2>/dev/null
}

# pp_has_conflicts <source_branch>
# Check if merge would have conflicts
# Returns 0 if conflicts exist, 1 if clean merge possible
pp_has_conflicts() {
    local source_branch="$1"
    ! git merge-tree --write-tree HEAD "${source_branch}" >/dev/null 2>&1
}

# pp_do_pull <agent_branch>
# Execute pull: fast-forward, then merge commit
# Returns 0 on success, 1 on failure (conflicts)
pp_do_pull() {
    local agent_branch="$1"
    local remote="${V0_GIT_REMOTE:-origin}"
    local remote_ref="${remote}/${agent_branch}"

    # Try fast-forward first
    if git merge --ff-only "${remote_ref}" 2>/dev/null; then
        echo "Fast-forward merge successful"
        return 0
    fi

    # Try merge commit
    if git merge --no-edit "${remote_ref}" 2>/dev/null; then
        echo "Merge commit created"
        return 0
    fi

    # Merge failed (conflicts)
    git merge --abort 2>/dev/null || true
    return 1
}

# pp_run_foreground_resolve <agent_branch> <target_branch>
# Run claude in foreground to resolve conflicts
# Returns 0 on success, 1 on failure
pp_run_foreground_resolve() {
    local agent_branch="$1"
    local target_branch="$2"
    local remote="${V0_GIT_REMOTE:-origin}"
    local remote_ref="${remote}/${agent_branch}"

    # Start the merge (which will stop at conflicts)
    git merge --no-commit "${remote_ref}" 2>/dev/null || true

    # Check we have conflicts to resolve
    if ! git status --porcelain | grep -q '^UU\|^AA\|^DD'; then
        echo "No conflicts detected"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    # Get context for prompt
    local base merge_commits branch_commits
    base=$(git merge-base HEAD "${remote_ref}")
    merge_commits=$(git log --oneline "${base}..${remote_ref}")
    branch_commits=$(git log --oneline "${base}..HEAD")

    # Create done script in current directory
    cat > ./done <<'DONE_SCRIPT'
#!/bin/bash
find_claude() {
  local pid=$1
  while [[ -n "${pid}" ]] && [[ "${pid}" != "1" ]]; do
    local cmd
    cmd=$(ps -o comm= -p "${pid}" 2>/dev/null)
    if [[ "${cmd}" == *"claude"* ]]; then
      echo "${pid}"
      return
    fi
    pid=$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')
  done
}
CLAUDE_PID=$(find_claude $$)
if [[ -n "${CLAUDE_PID}" ]]; then
  kill -TERM "${CLAUDE_PID}" 2>/dev/null || true
fi
exit 0
DONE_SCRIPT
    chmod +x ./done
    trap 'rm -f ./done' EXIT

    # Build prompt
    local prompt prompt_file
    prompt_file="${V0_DIR}/packages/cli/lib/prompts/pull-resolve.md"
    if [[ -f "${prompt_file}" ]]; then
        prompt="$(cat "${prompt_file}")"
    else
        prompt="Resolve the merge conflicts in this repository."
    fi

    prompt="${prompt}

Resolve the merge conflicts.

Commits from agent branch (${agent_branch}):
${merge_commits}

Commits on your branch (${target_branch}):
${branch_commits}

Run: git status"

    echo ""
    echo "=== Starting foreground conflict resolution ==="
    echo ""

    # Run claude in foreground (blocking)
    if ! claude --dangerously-skip-permissions \
         --allowedTools 'Bash(git *)' 'Bash(./done)' Read Edit Write \
         -p "${prompt}"; then
        echo "Claude exited with error"
        rm -f ./done
        git merge --abort 2>/dev/null || true
        return 1
    fi

    rm -f ./done

    # Verify resolution
    if git status --porcelain | grep -q '^UU\|^AA\|^DD'; then
        echo "Error: Conflicts still exist after resolution"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    return 0
}
