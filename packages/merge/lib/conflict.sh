#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# merge/conflict.sh - Conflict detection and resolution launching
#
# Depends on: resolve.sh
# IMPURE: Uses git, tmux, claude

# Source grep wrapper for fast pattern matching
_MERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packages/core/lib/grep.sh
source "${_MERGE_DIR}/../../core/lib/grep.sh"

# Expected environment variables:
# V0_DIR - Path to v0 installation
# V0_GIT_REMOTE - Git remote name
# V0_DEVELOP_BRANCH - Main development branch name
# BUILD_DIR - Path to build directory
# REPO_NAME - Name of the repository

# Source grep wrapper for better performance
_MERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_MERGE_DIR}/../../core/lib/grep.sh"

# mg_has_conflicts <branch>
# Check if merge would have conflicts (run from main repo)
# Returns 0 if conflicts, 1 if no conflicts
mg_has_conflicts() {
    local branch="$1"
    ! git merge-tree --write-tree HEAD "${branch}" >/dev/null 2>&1
}

# mg_worktree_has_conflicts <worktree>
# Check if worktree has unresolved conflicts
# Returns 0 if has conflicts, 1 if no conflicts
mg_worktree_has_conflicts() {
    local worktree="$1"
    git -C "${worktree}" status --porcelain | v0_grep_quiet '^UU|^AA|^DD'
}

# mg_worktree_has_uncommitted <worktree>
# Check if worktree has uncommitted changes (ignoring untracked files)
# Returns 0 if has uncommitted, 1 if clean
mg_worktree_has_uncommitted() {
    local worktree="$1"
    git -C "${worktree}" status --porcelain | v0_grep_invert '^??' | v0_grep_quiet .
}

# mg_commits_on_main <branch>
# Get commits on main since merge base
# Outputs: One commit per line (oneline format)
mg_commits_on_main() {
    local branch="$1"
    local base
    base=$(git merge-base HEAD "${branch}")
    git log --oneline "${base}..HEAD"
}

# mg_commits_on_branch <branch>
# Get commits on branch since merge base
# Outputs: One commit per line (oneline format)
mg_commits_on_branch() {
    local branch="$1"
    local base
    base=$(git merge-base HEAD "${branch}")
    git log --oneline "${base}..${branch}"
}

# mg_abort_incomplete_rebase <worktree>
# Clean up any incomplete rebase state
mg_abort_incomplete_rebase() {
    local worktree="$1"
    local git_dir
    git_dir=$(mg_get_worktree_git_dir "${worktree}")

    if [[ -d "${git_dir}/rebase-merge" ]] || [[ -d "${git_dir}/rebase-apply" ]]; then
        echo "Detected incomplete rebase, aborting..."
        git -C "${worktree}" rebase --abort 2>/dev/null || true
    fi
}

# mg_launch_resolve_session <worktree> <tree_dir> <branch>
# Launch claude in tmux session to resolve conflicts
# Returns: Session name
mg_launch_resolve_session() {
    local worktree="$1"
    local tree_dir="$2"
    local branch="$3"

    local main_commits branch_commits
    main_commits=$(mg_commits_on_main "${branch}")
    branch_commits=$(mg_commits_on_branch "${branch}")

    # Start rebase to trigger conflicts
    git -C "${worktree}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null || true
    git -C "${worktree}" rebase "${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}" || true

    local resolve_session
    resolve_session=$(v0_session_name "$(echo "${branch}" | tr '/' '-')" "merge-resolve")

    # Kill existing session if any
    tmux kill-session -t "${resolve_session}" 2>/dev/null || true

    # Create done script that terminates the claude process
    cat > "${tree_dir}/done" <<'DONE_SCRIPT'
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
    chmod +x "${tree_dir}/done"

    # Create settings with Stop hook
    local hook_script="${V0_DIR}/packages/hooks/lib/stop-merge.sh"
    mkdir -p "${tree_dir}/.claude"
    cat > "${tree_dir}/.claude/settings.local.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "MERGE_WORKTREE='${worktree}' ${hook_script}"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

    # Write prompt to temp file
    local prompt_file
    prompt_file=$(mktemp)
    cat > "${prompt_file}" <<PROMPT_EOF
$(cat "${V0_DIR}/packages/cli/lib/prompts/merge.md")

Resolve the merge conflicts in ${REPO_NAME}/.

Commits on main since divergence:
${main_commits}

Commits on this branch:
${branch_commits}

Run: cd ${REPO_NAME} && git status
PROMPT_EOF

    # Create resolve script with logging
    local resolve_script resolve_log
    resolve_script=$(mktemp)
    resolve_log="${tree_dir}/.merge-resolve.log"
    cat > "${resolve_script}" <<RESOLVE_EOF
#!/bin/bash
set -e
cd "${tree_dir}"
{
  echo "=== Merge resolve started at \$(date) ==="
  echo "Working directory: \$(pwd)"
} >> "${resolve_log}" 2>&1

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude command not found" >> "${resolve_log}" 2>&1
  exit 1
fi

claude --model opus --dangerously-skip-permissions --allow-dangerously-skip-permissions "\$(cat '${prompt_file}')" 2>> "${resolve_log}"
EXIT_CODE=\$?
echo "=== Claude exited with code \$EXIT_CODE at \$(date) ===" >> "${resolve_log}" 2>&1
rm -f "${prompt_file}"
exit \$EXIT_CODE
RESOLVE_EOF
    chmod +x "${resolve_script}"

    # Launch in tmux
    echo ""
    echo "=== Launching claude in tmux session: ${resolve_session} ==="
    echo ""
    echo "Attach to monitor/assist:"
    echo "  tmux attach -t ${resolve_session}"
    echo "  (Ctrl-B D to detach)"
    echo ""
    echo "Log file: ${resolve_log}"
    echo ""

    if ! tmux new-session -d -s "${resolve_session}" -c "${tree_dir}" "${resolve_script}"; then
        echo "Error: Failed to create tmux session"
        rm -f "${prompt_file}" "${resolve_script}"
        return 1
    fi

    # Verify session was created
    sleep 0.5
    if ! tmux has-session -t "${resolve_session}" 2>/dev/null; then
        echo "Error: tmux session failed to start"
        echo "Check log file: ${resolve_log}"
        if [[ -f "${resolve_log}" ]]; then
            echo ""
            echo "=== Log contents ==="
            cat "${resolve_log}"
        fi
        rm -f "${prompt_file}" "${resolve_script}"
        return 1
    fi

    MG_RESOLVE_SESSION="${resolve_session}"
    MG_RESOLVE_SCRIPT="${resolve_script}"
    MG_RESOLVE_LOG="${resolve_log}"
    MG_PROMPT_FILE="${prompt_file}"

    return 0
}

# mg_wait_for_resolve_session <session_name>
# Wait for resolution session to complete
mg_wait_for_resolve_session() {
    local session_name="$1"

    echo "Waiting for claude to resolve conflicts..."
    while tmux has-session -t "${session_name}" 2>/dev/null; do
        sleep 2
    done
}

# mg_cleanup_resolve_session <tree_dir>
# Clean up resolve session artifacts
mg_cleanup_resolve_session() {
    local tree_dir="$1"

    rm -f "${MG_PROMPT_FILE:-}" "${MG_RESOLVE_SCRIPT:-}" "${tree_dir}/done"
}

# mg_create_temp_worktree_for_resolution <branch>
# Creates a temporary worktree for conflict resolution
# Sets: MG_TEMP_WORKTREE, MG_TEMP_TREE_DIR
mg_create_temp_worktree_for_resolution() {
    local branch="$1"

    local temp_tree_dir
    temp_tree_dir="${BUILD_DIR}/temp-merge-$(date +%s)"
    local temp_worktree="${temp_tree_dir}/${REPO_NAME}"

    mkdir -p "${temp_tree_dir}"

    if ! git worktree add "${temp_worktree}" "${branch}" 2>/dev/null; then
        echo "Error: Failed to create temporary worktree for ${branch}" >&2
        rm -rf "${temp_tree_dir}"
        return 1
    fi

    MG_TEMP_WORKTREE="${temp_worktree}"
    MG_TEMP_TREE_DIR="${temp_tree_dir}"

    echo "Created temporary worktree: ${temp_worktree}"
}

# mg_cleanup_temp_worktree
# Clean up temporary worktree after resolution
mg_cleanup_temp_worktree() {
    if [[ -n "${MG_TEMP_WORKTREE:-}" ]] && [[ -d "${MG_TEMP_WORKTREE}" ]]; then
        git worktree remove "${MG_TEMP_WORKTREE}" --force 2>/dev/null || true
        rm -rf "${MG_TEMP_TREE_DIR:-}"
        MG_TEMP_WORKTREE=""
        MG_TEMP_TREE_DIR=""
    fi
}

# mg_resolve_uncommitted_changes <worktree> <tree_dir> <branch>
# Resolve uncommitted changes by launching claude agent
mg_resolve_uncommitted_changes() {
    local worktree="$1"
    local tree_dir="$2"
    local branch="$3"

    local session_name
    session_name=$(v0_session_name "$(echo "${branch}" | tr '/' '-')" "uncommitted")

    # Kill existing session if any
    tmux kill-session -t "${session_name}" 2>/dev/null || true

    # Gather context
    local plan_label=""
    local op_state_file="${BUILD_DIR}/operations/${branch}/state.json"
    if [[ ! -f "${op_state_file}" ]]; then
        op_state_file="${BUILD_DIR}/operations/$(basename "${branch}")/state.json"
    fi
    if [[ -f "${op_state_file}" ]]; then
        plan_label=$(jq -r '.plan_label // empty' "${op_state_file}" 2>/dev/null || echo "")
    fi

    local wk_context=""
    if [[ -n "${plan_label}" ]]; then
        wk_context="Related wk issues (label: ${plan_label}):
$(wk list --label "${plan_label}" --status in_progress 2>/dev/null || echo "  (none in progress)")
$(wk list --label "${plan_label}" --status todo 2>/dev/null | head -5 || echo "  (none todo)")"
    fi

    local v0_context=""
    if [[ -f "${op_state_file}" ]]; then
        v0_context="v0 operation state:
$(jq -r '"  Phase: \(.phase // "unknown")\n  Epic: \(.epic_id // "none")"' "${op_state_file}" 2>/dev/null || echo "  (no state)")"
    fi

    # Create done script
    cat > "${tree_dir}/done" <<'DONE_SCRIPT'
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
    chmod +x "${tree_dir}/done"

    # Create settings with stop hook
    local hook_script="${V0_DIR}/packages/hooks/lib/stop-uncommitted.sh"
    mkdir -p "${tree_dir}/.claude"
    cat > "${tree_dir}/.claude/settings.local.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "UNCOMMITTED_WORKTREE='${worktree}' ${hook_script}"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

    # Build prompt
    local prompt_file
    prompt_file=$(mktemp)
    cat > "${prompt_file}" <<PROMPT_EOF
$(sed "s/__V0_GIT_REMOTE__/${V0_GIT_REMOTE}/g" "${V0_DIR}/packages/cli/lib/prompts/uncommitted.md")

## Current Situation

Worktree: ${REPO_NAME}/
Branch: ${branch}

Current git status:
$(git -C "${worktree}" status)

${wk_context}

${v0_context}

Start by reviewing: cd ${REPO_NAME} && git diff
PROMPT_EOF

    # Create wrapper script
    local resolve_script resolve_log
    resolve_script=$(mktemp)
    resolve_log="${tree_dir}/.uncommitted-resolve.log"
    cat > "${resolve_script}" <<RESOLVE_EOF
#!/bin/bash
set -e
cd "${tree_dir}"
{
  echo "=== Uncommitted changes resolution started at \$(date) ==="
} >> "${resolve_log}" 2>&1
claude --model opus --dangerously-skip-permissions --allow-dangerously-skip-permissions "\$(cat '${prompt_file}')" 2>> "${resolve_log}"
EXIT_CODE=\$?
echo "=== Claude exited with code \$EXIT_CODE at \$(date) ===" >> "${resolve_log}" 2>&1
rm -f "${prompt_file}"
exit \$EXIT_CODE
RESOLVE_EOF
    chmod +x "${resolve_script}"

    # Launch agent
    echo ""
    echo "=== Launching claude in tmux session: ${session_name} ==="
    echo ""
    echo "Attach to monitor: tmux attach -t ${session_name}"
    echo "Log file: ${resolve_log}"
    echo ""

    if ! tmux new-session -d -s "${session_name}" -c "${tree_dir}" "${resolve_script}"; then
        echo "Error: Failed to create tmux session"
        rm -f "${prompt_file}" "${resolve_script}"
        return 1
    fi

    # Wait for completion
    echo "Waiting for claude to handle uncommitted changes..."
    while tmux has-session -t "${session_name}" 2>/dev/null; do
        sleep 2
    done

    # Cleanup
    rm -f "${prompt_file}" "${resolve_script}" "${tree_dir}/done"
    rm -f "${resolve_log}"
}
