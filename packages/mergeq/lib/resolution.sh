#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# mergeq/resolution.sh - Conflict resolution via claude
#
# Depends on: rules.sh, io.sh, display.sh
# IMPURE: Uses tmux, claude, git

# Expected environment variables:
# V0_DIR - Path to v0 installation
# V0_ROOT - Path to project root
# V0_WORKSPACE_DIR - Path to workspace directory
# V0_GIT_REMOTE - Git remote name
# V0_DEVELOP_BRANCH - Main development branch name
# MERGEQ_DIR - Directory for merge queue state

# mq_launch_branch_conflict_resolution <branch>
# Launch claude in tmux session to resolve branch merge conflicts
# Returns 0 if resolution launched, 1 on error
mq_launch_branch_conflict_resolution() {
    local branch="$1"

    local resolve_session
    resolve_session=$(v0_session_name "$(echo "${branch}" | tr '/' '-')" "mergeq-resolve")

    # Kill existing session if any
    tmux kill-session -t "${resolve_session}" 2>/dev/null || true

    # Create resolve script
    local resolve_script="${MERGEQ_DIR}/resolve-${branch//\//-}.sh"
    cat > "${resolve_script}" <<RESOLVE_EOF
#!/bin/bash
set -e
cd "${V0_WORKSPACE_DIR}"

# Clean up any incomplete merge/rebase state from previous failed attempts
if [[ -d ".git/rebase-merge" ]] || [[ -d ".git/rebase-apply" ]]; then
  echo "Aborting incomplete rebase..."
  git rebase --abort 2>/dev/null || true
fi
if [[ -f ".git/MERGE_HEAD" ]]; then
  echo "Aborting incomplete merge..."
  git merge --abort 2>/dev/null || true
fi

# Re-attempt the merge to get conflict state
git fetch "${V0_GIT_REMOTE}" "${branch}"
git merge --no-edit "${V0_GIT_REMOTE}/${branch}" || true

# Run claude to resolve conflicts
claude --model opus --dangerously-skip-permissions --allow-dangerously-skip-permissions "\$(cat '${V0_DIR}/packages/cli/lib/prompts/merge.md')

Resolve the merge conflicts in the current directory.

This is a branch merge of '${branch}' into main.

Run: git status"

# Check if conflicts were resolved
if git status --porcelain | grep -q '^UU\|^AA\|^DD'; then
  echo "Conflicts still exist after resolution attempt"
  git merge --abort 2>/dev/null || true
  exit 1
fi

# Commit the merge
git commit --no-verify --no-edit || true

# Push the result to develop branch explicitly (HEAD may track a worker branch)
git push "${V0_GIT_REMOTE}" HEAD:"${V0_DEVELOP_BRANCH}"

# Delete the merged branch
git push "${V0_GIT_REMOTE}" --delete "${branch}" 2>/dev/null || true

echo "0" > "${MERGEQ_DIR}/resolve-${branch//\//-}.exit"
RESOLVE_EOF
    chmod +x "${resolve_script}"

    # Launch in tmux (from workspace directory)
    echo "[$(date +%H:%M:%S)] Launching claude in tmux session: ${resolve_session}"
    tmux new-session -d -s "${resolve_session}" -c "${V0_WORKSPACE_DIR}" "${resolve_script}; echo \$? > '${MERGEQ_DIR}/resolve-${branch//\//-}.exit'"

    echo "${resolve_session}"
}

# mq_wait_for_resolution <branch> <session_name> <max_wait_seconds>
# Wait for resolution session to complete
# Returns 0 if completed successfully, 1 if failed or timed out
mq_wait_for_resolution() {
    local branch="$1"
    local resolve_session="$2"
    local max_wait="${3:-300}"  # 5 minutes default

    local wait_count=0
    local safe_branch="${branch//\//-}"

    while tmux has-session -t "${resolve_session}" 2>/dev/null && [[ ${wait_count} -lt ${max_wait} ]]; do
        sleep 2
        wait_count=$((wait_count + 2))
        # Check if exit file exists
        if [[ -f "${MERGEQ_DIR}/resolve-${safe_branch}.exit" ]]; then
            tmux kill-session -t "${resolve_session}" 2>/dev/null || true
            break
        fi
    done

    # Check result
    if [[ -f "${MERGEQ_DIR}/resolve-${safe_branch}.exit" ]]; then
        local resolve_exit
        resolve_exit=$(cat "${MERGEQ_DIR}/resolve-${safe_branch}.exit")
        rm -f "${MERGEQ_DIR}/resolve-${safe_branch}.exit" "${MERGEQ_DIR}/resolve-${safe_branch}.sh"

        if [[ "${resolve_exit}" = "0" ]]; then
            return 0
        fi
    fi

    # Resolution failed or timed out - cleanup
    git merge --abort 2>/dev/null || true
    rm -f "${MERGEQ_DIR}/resolve-${safe_branch}.exit" "${MERGEQ_DIR}/resolve-${safe_branch}.sh"
    tmux kill-session -t "${resolve_session}" 2>/dev/null || true

    return 1
}

# mq_cleanup_resolution <branch>
# Clean up resolution artifacts
mq_cleanup_resolution() {
    local branch="$1"
    local safe_branch="${branch//\//-}"
    local resolve_session
    resolve_session=$(v0_session_name "${safe_branch}" "mergeq-resolve")

    rm -f "${MERGEQ_DIR}/resolve-${safe_branch}.exit"
    rm -f "${MERGEQ_DIR}/resolve-${safe_branch}.sh"
    tmux kill-session -t "${resolve_session}" 2>/dev/null || true
}
