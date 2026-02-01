#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Common functions for background workers (fix, chore, mergeq)
# Source this file to get shared utility functions
#
# Required variables (must be set before sourcing):
#   WORKER_SESSION - tmux session name (e.g., "v0-fix-worker")
#   POLLING_LOG - polling daemon log file path

# Source nudge-common for session monitoring
V0_DIR="${V0_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${V0_DIR}/packages/worker/lib/nudge-common.sh"

# Check if worker tmux session is running
worker_running() {
  tmux has-session -t "${WORKER_SESSION}" 2>/dev/null
}

# Check if polling daemon is running
polling_running() {
  pgrep -f "while true.*${WORKER_SESSION}" > /dev/null 2>&1
}

# Clean up worktree: remove git worktree, delete branch, and state directory
# Args: $1 = worktree path, $2 = git branch name
cleanup_worktree() {
  local tree_dir="$1"
  local branch="$2"
  local git_root

  if [[ -z "${tree_dir}" ]] || [[ ! -d "${tree_dir}" ]]; then
    return 0
  fi

  # Get the actual git repository path
  # Use git rev-parse --git-dir to handle worktrees correctly
  local git_dir
  git_dir=$(cd "${tree_dir}" && git rev-parse --git-dir 2>/dev/null)

  if [[ -z "${git_dir}" ]]; then
    echo "Warning: Could not determine git directory for ${tree_dir}"
    return 1
  fi

  # git-dir returns a relative or absolute path; convert to absolute and get repo root
  if [[ "${git_dir#/}" = "${git_dir}" ]]; then
    # Relative path
    git_dir="$(cd "${tree_dir}" && pwd)/${git_dir}"
  fi

  # Remove /.git or /.git/worktrees/* to get the repository root
  if [[ "${git_dir}" == *"/.git"* ]]; then
    git_root="${git_dir%/.git*}"
  else
    git_root="${git_dir}"
  fi

  # Remove the git worktree FIRST (use --force to handle missing .git files)
  echo "Removing worktree: ${tree_dir}"
  git -C "${git_root}" worktree remove --force "${tree_dir}" 2>/dev/null || {
    # Fallback if worktree remove fails
    echo "Warning: git worktree remove failed, attempting force remove"
    rm -rf "${tree_dir}" 2>/dev/null || true
  }

  # Delete the branch AFTER removing worktree (worktree may hold a reference)
  # Protect the configured develop branch plus common defaults (main, master)
  if [[ -n "${branch}" ]] && [[ "${branch}" != "${V0_DEVELOP_BRANCH:-main}" ]] && [[ "${branch}" != "main" ]] && [[ "${branch}" != "master" ]]; then
    echo "Deleting branch: ${branch}"
    git -C "${git_root}" branch -D "${branch}" 2>/dev/null || true
  fi
}

# Stop worker: kill tmux session, polling daemon, and clean up worktree
# Args: $1 = worktree path, $2 = git branch name (typically $WORKER_SESSION)
stop_worker_clean() {
  local tree_dir="${1:-}"
  local branch="${2:-}"

  # Kill tmux session
  if [[ -n "${WORKER_SESSION}" ]]; then
    tmux kill-session -t "${WORKER_SESSION}" 2>/dev/null || true
  fi

  # Kill polling daemon
  if [[ -n "${WORKER_SESSION}" ]]; then
    pkill -f "while true.*${WORKER_SESSION}" 2>/dev/null || true
  fi

  # Clean up worktree if path provided
  if [[ -n "${tree_dir}" ]] && [[ -n "${branch}" ]]; then
    cleanup_worktree "${tree_dir}" "${branch}"
  fi
}

# View worker stdout/stderr logs
show_logs() {
  local tree_dir
  tree_dir=$(find_worker_state_dir "${WORKER_SESSION}") || {
    echo "Worker not found"
    return 1
  }
  local log_file="${tree_dir}/claude-worker.log"

  if [[ ! -f "${log_file}" ]]; then
    echo "No logs found: ${log_file}"
    return 1
  fi

  echo "${log_file}"
  tail -30 "${log_file}"
}

# View worker error logs
show_errors() {
  local tree_dir
  tree_dir=$(find_worker_state_dir "${WORKER_SESSION}") || {
    echo "Worker not found"
    return 1
  }
  local error_file="${tree_dir}/claude-worker.log.error"
  local log_file="${tree_dir}/claude-worker.log"

  if [[ ! -f "${error_file}" ]]; then
    echo "No error logs found: ${error_file}"
    return 1
  fi

  echo "${error_file}"
  if [[ -s "${error_file}" ]]; then
    tail -30 "${error_file}"
  else
    echo "(error file empty - showing main log)"
    echo ""
    if [[ -f "${log_file}" ]]; then
      tail -30 "${log_file}"
    fi
  fi
}

# Create done script that marks clean exit with flag before killing worker
# Args: $1 = tree_dir, $2 = worker description (e.g., "bug", "chore")
create_done_script() {
  local tree_dir="$1"
  local worker_type="$2"

  cat > "${tree_dir}/done" <<DONE_SCRIPT
#!/bin/bash
# Signal worker is done - clean exit
echo "Exiting ${worker_type} worker..."

# Mark that this is a clean done exit (not an error)
touch "${tree_dir}/.done-exit"

# Find and kill claude process
find_claude() {
  local pid=\$1
  while [[ -n "\${pid}" ]] && [[ "\${pid}" != "1" ]]; do
    local cmd
    cmd=\$(ps -o comm= -p "\${pid}" 2>/dev/null)
    if [[ "\${cmd}" == *"claude"* ]]; then
      echo "\${pid}"
      return
    fi
    pid=\$(ps -o ppid= -p "\${pid}" 2>/dev/null | tr -d ' ')
  done
}

CLAUDE_PID=\$(find_claude \$\$)
if [[ -n "\${CLAUDE_PID}" ]]; then
  kill -TERM "\${CLAUDE_PID}" 2>/dev/null || true
fi
exit 0
DONE_SCRIPT
  chmod +x "${tree_dir}/done"
}

# Create wrapper script that uses try-catch for a worker
# Args: $1 = tree_dir, $2 = log_file, $3 = worker_name, $4 = command_suggestion, $5 = v0_dir (toolkit root), $6... = command to run
create_wrapper_script() {
  local tree_dir="$1"
  local log_file="$2"
  local worker_name="$3"
  local command_suggestion="$4"
  local v0_dir="$5"
  shift 5

  local wrapper_script="${tree_dir}/claude-worker.sh"

  # Build command arguments with proper quoting
  local cmd_args=""
  for arg in "$@"; do
    cmd_args+=" $(printf '%q' "${arg}")"
  done

  # Write the wrapper script with v0_dir embedded
  cat > "${wrapper_script}" <<WRAPPER_SCRIPT
#!/bin/bash
# Wrapper script for try-catch
# This script ensures proper argument quoting when invoking Claude worker

exec "${v0_dir}/packages/worker/lib/try-catch.sh" "${log_file}" "${worker_name}" "${command_suggestion}"${cmd_args}
WRAPPER_SCRIPT

  chmod +x "${wrapper_script}"
}

# Initialize shared workspace if needed
# Args: $1 = root_dir (path to repo with .wok database)
ensure_shared_workspace() {
  local root_dir="$1"
  if [[ ! -d "${root_dir}/.wok" ]]; then
    wk init --path "${root_dir}" 2>/dev/null || true
  fi
}

# Link worktree to shared workspace
# Args: $1 = tree_dir (worktree path), $2 = root_dir (path with .wok)
# Uses ISSUE_PREFIX from v0_load_config if available
link_to_workspace() {
  local tree_dir="$1"
  local root_dir="$2"

  if [[ -n "${ISSUE_PREFIX:-}" ]]; then
    wk init --workspace "${root_dir}/.wok" --prefix "${ISSUE_PREFIX}" --path "${tree_dir}" >/dev/null 2>&1 || true
  else
    wk init --workspace "${root_dir}/.wok" --path "${tree_dir}" >/dev/null 2>&1 || true
  fi
}

# Reset worktree to latest develop branch
# Tries to fetch from remote first, falls back to local branch, then creates from main
# Args: $1 = git_dir (path to run git commands in, optional - uses cwd if not provided)
v0_reset_to_develop() {
  local git_dir="${1:-}"
  local git_cmd=(git)
  if [[ -n "${git_dir}" ]]; then
    git_cmd=(git -C "${git_dir}")
  fi

  # Try remote develop branch first
  if "${git_cmd[@]}" fetch "${V0_GIT_REMOTE}" "${V0_DEVELOP_BRANCH}" 2>/dev/null; then
    "${git_cmd[@]}" reset --hard "${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}" >/dev/null
  # Try local develop branch
  elif "${git_cmd[@]}" rev-parse --verify "${V0_DEVELOP_BRANCH}" 2>/dev/null; then
    echo "Note: Remote branch '${V0_DEVELOP_BRANCH}' not found, using local" >&2
    "${git_cmd[@]}" reset --hard "${V0_DEVELOP_BRANCH}" >/dev/null
  # Create develop branch from main and reset to it
  else
    echo "Note: Branch '${V0_DEVELOP_BRANCH}' not found, creating from main" >&2
    "${git_cmd[@]}" fetch "${V0_GIT_REMOTE}" main 2>/dev/null || true
    # Try to create branch with fallbacks: remote main -> local main -> HEAD
    if ! "${git_cmd[@]}" branch -f "${V0_DEVELOP_BRANCH}" "${V0_GIT_REMOTE}/main" 2>/dev/null; then
      if ! "${git_cmd[@]}" branch -f "${V0_DEVELOP_BRANCH}" main 2>/dev/null; then
        "${git_cmd[@]}" branch -f "${V0_DEVELOP_BRANCH}" HEAD >/dev/null
      fi
    fi
    "${git_cmd[@]}" reset --hard "${V0_DEVELOP_BRANCH}" >/dev/null
  fi
}

# Save worker state markers to worktree directory
# Args: $1 = tree_dir, $2 = git_dir, $3 = branch_name, $4 = project_root (optional, defaults to pwd)
setup_worker_markers() {
  local tree_dir="$1"
  local git_dir="$2"
  local branch_name="$3"
  local project_root="${4:-$(pwd)}"

  echo "${git_dir}" > "${tree_dir}/.worker-git-dir"
  echo "${branch_name}" > "${tree_dir}/.worker-branch"
  echo "${project_root}" > "${tree_dir}/.worker-project-root"
}

# Create polling loop with exponential backoff
# Args: $1 = tree_dir, $2 = item_type (bug/chore), $3 = polling_log
create_polling_loop() {
  local tree_dir="$1"
  local item_type="$2"
  local polling_log="$3"

  # Ensure nudge worker is running to monitor for idle sessions
  ensure_nudge_running

  # Write session marker for nudge worker to find this session
  write_session_marker "${tree_dir}" "${WORKER_SESSION}"

  nohup bash -c "
    cd \"${tree_dir}\" || exit 1
    echo \"[\$(date)] Polling daemon started for ${WORKER_SESSION}\" >> \"${polling_log}\"
    echo \"[\$(date)] Tree dir: ${tree_dir}\" >> \"${polling_log}\"
    echo \"[\$(date)] Item type: ${item_type}\" >> \"${polling_log}\"

    failure_count=0
    backoff=5
    max_backoff=300
    prev_items_file=\"${tree_dir}/.prev-items-list\"

    while true; do
      # Check if worker exited due to error (not clean done exit)
      if [[ -f \"${tree_dir}/.worker-error\" ]]; then
        # Worker failed - increment failure counter
        failure_count=\$((failure_count + 1))
        rm -f \"${tree_dir}/.worker-error\"

        # Calculate exponential backoff: 5s, 10s, 20s, 40s, etc, capped at 5min
        backoff=\$((5 * (2 ** (failure_count - 1))))
        if [[ \${backoff} -gt 300 ]]; then
          backoff=300
        fi
        echo \"[\$(date)] Worker error (attempt \${failure_count}). Backing off for \${backoff}s\" >> \"${polling_log}\"
        sleep \${backoff}
      else
        # Reset failure count on successful runs
        failure_count=0
        backoff=5
      fi

      # Check if there are items waiting
      current_items=\$(wk list --type ${item_type} --status todo 2>&1)
      # Count items properly: empty or whitespace-only means 0 items
      if [[ -z \"\$(echo \"\${current_items}\" | tr -d '[:space:]')\" ]]; then
        items_count=0
      else
        items_count=\$(echo \"\${current_items}\" | wc -l | tr -d ' ')
      fi
      echo \"[\$(date)] Checked for items: \${items_count} found\" >> \"${polling_log}\"

      if [[ \${items_count} -gt 0 ]]; then
        # Items available and Claude not running - launch Claude
        echo \"[\$(date)] Items available, checking for active session...\" >> \"${polling_log}\"
        has_session_result=\$(tmux has-session -t \"${WORKER_SESSION}\" 2>&1)
        has_session_exit=\$?
        echo \"[\$(date)] tmux has-session exit code: \${has_session_exit}\" >> \"${polling_log}\"

        if [[ \${has_session_exit} -ne 0 ]]; then
          # Worker session is not running
          # Check if this was a clean exit (done script called) or unexpected exit
          if [[ ! -f \"${tree_dir}/.done-exit\" ]]; then
            # Not a clean exit - worker crashed/exited unexpectedly
            # Check if the item list is unchanged (indicating no progress was made)
            items_changed=false
            if [[ -f \"\${prev_items_file}\" ]]; then
              if ! diff -q <(echo \"\${current_items}\") \"\${prev_items_file}\" >/dev/null 2>&1; then
                items_changed=true
              fi
            else
              # First run, no previous list to compare
              items_changed=true
            fi

            if [[ \"\${items_changed}\" = false ]]; then
              # Item list didn't change - worker made no progress before crashing

              # Check if we've already alerted about this crash
              if [[ ! -f \"${tree_dir}/.worker-crash-alert\" ]]; then
                # First alert - log, notify, and mark that we've alerted
                echo \"[\$(date)] ERROR: Worker exited without making progress (list unchanged)\" >> \"${polling_log}\"

                # Send OS notification if available (skip in test mode)
                if [[ \"\${V0_TEST_MODE:-}\" != \"1\" ]] && command -v osascript >/dev/null 2>&1; then
                  osascript -e \"display notification \\\"Worker exited without progress\\\" with title \\\"${WORKER_SESSION} crashed\\\"\" 2>/dev/null || true
                fi

                # Mark that we've sent the alert
                touch \"${tree_dir}/.worker-crash-alert\"
              else
                # Second time we detect this - stop the polling loop
                echo \"[\$(date)] ERROR: Worker still not running and still no progress. Stopping polling (logs preserved in ${tree_dir})\" >> \"${polling_log}\"
                exit 1
              fi
            else
              # Item list changed - worker was making progress, but then crashed
              # This is less critical, just log it and continue
              echo \"[\$(date)] Worker exited but made progress\" >> \"${polling_log}\"
              rm -f \"${tree_dir}/.worker-crash-alert\"
            fi
          else
            # Clean exit detected - reset crash alert flag for next cycle
            rm -f \"${tree_dir}/.worker-crash-alert\"
          fi

          # Remove stale done-exit flag before relaunching
          rm -f \"${tree_dir}/.done-exit\"

          # Reset worktree to latest main before relaunching
          if [[ -f \"${tree_dir}/.worker-git-dir\" ]] && [[ -f \"${tree_dir}/.worker-branch\" ]]; then
            git_dir=\$(cat \"${tree_dir}/.worker-git-dir\")
            worker_branch=\$(cat \"${tree_dir}/.worker-branch\")
            if [[ -d \"\${git_dir}\" ]]; then
              echo \"[\$(date)] Resetting worktree to latest develop branch...\" >> \"${polling_log}\"
              git -C \"\${git_dir}\" fetch \"\${V0_GIT_REMOTE:-origin}\" \"\${V0_DEVELOP_BRANCH:-main}\" >> \"${polling_log}\" 2>&1 || true
              git -C \"\${git_dir}\" checkout \"\${worker_branch}\" >> \"${polling_log}\" 2>&1 || true
              git -C \"\${git_dir}\" reset --hard \"\${V0_GIT_REMOTE:-origin}/\${V0_DEVELOP_BRANCH:-main}\" >> \"${polling_log}\" 2>&1 || true
              echo \"[\$(date)] Worktree reset complete\" >> \"${polling_log}\"
            fi
          fi

          echo \"[\$(date)] No active session, attempting to launch Claude...\" >> \"${polling_log}\"
          wrapper_script=\"${tree_dir}/claude-worker.sh\"

          # Try to create session and capture both stdout and stderr
          tmux_out=\$(tmux new-session -d -s \"${WORKER_SESSION}\" -c \"${tree_dir}\" \"\${wrapper_script}\" 2>&1)
          tmux_exit=\$?

          if [[ \${tmux_exit} -eq 0 ]]; then
            echo \"[\$(date)] Successfully launched Claude worker session\" >> \"${polling_log}\"
          else
            # Tmux launch failed - log error and notify
            echo \"[\$(date)] TMUX ERROR: Failed to start worker. Exit code: \${tmux_exit}. Output: \${tmux_out}\" >> \"${polling_log}\"

            # Send notification if osascript is available (skip in test mode)
            if [[ \"\${V0_TEST_MODE:-}\" != \"1\" ]] && command -v osascript >/dev/null 2>&1; then
              tmux_msg=\$(echo \"\${tmux_out}\" | head -1)
              osascript -e \"display notification \\\"Exit \${tmux_exit}: \${tmux_msg}\\\" with title \\\"${WORKER_SESSION} failed to start\\\"\" 2>/dev/null || true
            fi

            # Try to recover by reinitializing tmux
            echo \"[\$(date)] Attempting tmux recovery...\" >> \"${polling_log}\"
            tmux new-session -d -s _init 'sleep 1' 2>/dev/null
            sleep 0.5
            tmux kill-session -t _init 2>/dev/null || true

            # Try again
            tmux_out=\$(tmux new-session -d -s \"${WORKER_SESSION}\" -c \"${tree_dir}\" \"\${wrapper_script}\" 2>&1)
            tmux_exit=\$?

            if [[ \${tmux_exit} -eq 0 ]]; then
              echo \"[\$(date)] Tmux recovery successful\" >> \"${polling_log}\"
            else
              echo \"[\$(date)] TMUX ERROR: Recovery failed. Exit code: \${tmux_exit}. Output: \${tmux_out}\" >> \"${polling_log}\"
            fi
          fi
        fi
      fi

      # Save current item list for next iteration (to detect if progress was made)
      echo \"\${current_items}\" > \"\${prev_items_file}\"

      # Check every 5 seconds when things are normal
      sleep 5
    done
  " > "${polling_log}" 2>&1 &
}

# Find worker state directory by searching for .worker-git-dir file
# Returns the tree state directory if found
find_worker_state_dir() {
  local target_session="$1"
  local preferred_root="${2:-}"

  # Try preferred root first if provided
  if [[ -n "${preferred_root}" ]]; then
    local root_name
    root_name=$(basename "${preferred_root}")
    local tree_state_dir="${HOME}/.local/state/v0/${root_name}/tree/${target_session}"
    if [[ -f "${tree_state_dir}/.worker-git-dir" ]]; then
      echo "${tree_state_dir}"
      return 0
    fi
  fi

  # Search in all project directories under .local/state/v0
  for dir in "${HOME}/.local/state/v0"/*; do
    if [[ -d "${dir}" ]] && [[ -f "${dir}/tree/${target_session}/.worker-git-dir" ]]; then
      echo "${dir}/tree/${target_session}"
      return 0
    fi
  done

  return 1
}

# Generic stop worker function that finds and cleans up any worker session
# Args: $1 = target session name, $2 = branch name, $3 = preferred root (optional)
generic_stop_worker() {
  local target_session="$1"
  local branch="$2"
  local preferred_root="${3:-}"

  if ! tmux has-session -t "${target_session}" 2>/dev/null && ! pgrep -f "while true.*${target_session}" > /dev/null 2>&1; then
    echo "Worker not running"
    return 0
  fi

  echo "Stopping worker..."

  # Find the worker state directory
  local tree_state_dir
  if tree_state_dir=$(find_worker_state_dir "${target_session}" "${preferred_root}"); then
    # Load git dir from file
    local git_dir=""
    if [[ -f "${tree_state_dir}/.worker-git-dir" ]]; then
      git_dir=$(cat "${tree_state_dir}/.worker-git-dir")
    fi

    # Kill tmux session
    tmux kill-session -t "${target_session}" 2>/dev/null || true

    # Kill polling daemon
    pkill -f "while true.*${target_session}" 2>/dev/null || true

    # Clean up worktree if path provided
    if [[ -n "${git_dir}" ]] && [[ -n "${branch}" ]]; then
      cleanup_worktree "${git_dir}" "${branch}"
    fi
  else
    echo "Warning: Could not find worker state directory"
    # Still kill the tmux session and polling daemon
    tmux kill-session -t "${target_session}" 2>/dev/null || true
    pkill -f "while true.*${target_session}" 2>/dev/null || true
  fi

  echo "Worker stopped"
}

# Create done script for feature workers (with optional exit file)
# Args: $1 = target_dir, $2 = exit_file (optional)
# This is different from create_done_script() which is for background workers
create_feature_done_script() {
  local target_dir="$1"
  local exit_file="${2:-}"

  if [[ -n "${exit_file}" ]]; then
    cat > "${target_dir}/done" <<DONE_SCRIPT
#!/bin/bash
echo "0" > '${exit_file}'
find_claude() {
  local pid=\$1
  while [[ -n "\${pid}" ]] && [[ "\${pid}" != "1" ]]; do
    local cmd=\$(ps -o comm= -p \${pid} 2>/dev/null)
    if [[ "\${cmd}" == *"claude"* ]]; then
      echo "\${pid}"
      return
    fi
    pid=\$(ps -o ppid= -p \${pid} 2>/dev/null | tr -d ' ')
  done
}
CLAUDE_PID=\$(find_claude \$\$)
if [[ -n "\${CLAUDE_PID}" ]]; then
  kill -TERM "\${CLAUDE_PID}" 2>/dev/null || true
fi
exit 0
DONE_SCRIPT
  else
    cat > "${target_dir}/done" <<'DONE_SCRIPT'
#!/bin/bash
# Signal session completion - issues are closed by on-complete.sh

find_claude() {
  local pid=$1
  while [[ -n "${pid}" ]] && [[ "${pid}" != "1" ]]; do
    local cmd=$(ps -o comm= -p ${pid} 2>/dev/null)
    if [[ "${cmd}" == *"claude"* ]]; then
      echo "${pid}"
      return
    fi
    pid=$(ps -o ppid= -p ${pid} 2>/dev/null | tr -d ' ')
  done
}
CLAUDE_PID=$(find_claude $$)
if [[ -n "${CLAUDE_PID}" ]]; then
  kill -TERM "${CLAUDE_PID}" 2>/dev/null || true
fi
exit 0
DONE_SCRIPT
  fi
  chmod +x "${target_dir}/done"
}

# Create incomplete script for feature workers
# Args: $1 = target_dir, $2 = op_name, $3 = v0_root (toolkit root)
create_incomplete_script() {
  local target_dir="$1"
  local op_name="${2:-}"
  local v0_root="${3:-}"

  cat > "${target_dir}/incomplete" <<INCOMPLETE_SCRIPT
#!/bin/bash
# Exit session marking work as incomplete - generates debug report

echo "Generating debug report..."

# Generate debug report if v0 is available
if [[ -n "${v0_root}" ]] && [[ -x "${v0_root}/bin/v0" ]]; then
  "${v0_root}/bin/v0" self debug "${op_name}" 2>/dev/null || true
fi

# Log incomplete status
if [[ -n "\${V0_PLAN_LABEL}" ]]; then
  # Count remaining work for the note
  OPEN_COUNT=\$(wk list --label "\${V0_PLAN_LABEL}" -s todo 2>/dev/null | wc -l | tr -d ' ')
  IN_PROGRESS_COUNT=\$(wk list --label "\${V0_PLAN_LABEL}" -s in_progress 2>/dev/null | wc -l | tr -d ' ')

  # Add note to any in-progress issues
  IN_PROGRESS_IDS=\$(wk list --label "\${V0_PLAN_LABEL}" -s in_progress 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+')
  for id in \${IN_PROGRESS_IDS}; do
    wk note "\${id}" "Session ended incomplete. \${OPEN_COUNT} todo, \${IN_PROGRESS_COUNT} in progress remaining." 2>/dev/null || true
  done
fi

echo "Debug report generated. Session ending as incomplete."
echo "Resume with: v0 feature ${op_name} --resume"

find_claude() {
  local pid=\$1
  while [[ -n "\${pid}" ]] && [[ "\${pid}" != "1" ]]; do
    local cmd=\$(ps -o comm= -p \${pid} 2>/dev/null)
    if [[ "\${cmd}" == *"claude"* ]]; then
      echo "\${pid}"
      return
    fi
    pid=\$(ps -o ppid= -p \${pid} 2>/dev/null | tr -d ' ')
  done
}
CLAUDE_PID=\$(find_claude \$\$)
if [[ -n "\${CLAUDE_PID}" ]]; then
  kill -TERM "\${CLAUDE_PID}" 2>/dev/null || true
fi
exit 1
INCOMPLETE_SCRIPT
  chmod +x "${target_dir}/incomplete"
}

# Detect if a bug has a note but no fix commits
# This indicates the worker documented why they couldn't fix it
# Args: $1 = bug_id, $2 = git_dir (optional, defaults to pwd)
# Returns 0 (true) if bug has a note but no commits, 1 otherwise
detect_note_without_fix() {
  local bug_id="$1"
  local git_dir="${2:-$(pwd)}"

  # Check for notes on the bug (wk show returns JSON with notes array)
  local notes_count
  notes_count=$(wk show "${bug_id}" -o json 2>/dev/null | jq '.notes | length' 2>/dev/null || echo "0")

  if [[ "${notes_count}" -eq 0 ]]; then
    return 1  # No notes, normal exit
  fi

  # Check for commits beyond develop branch
  local commits_ahead
  commits_ahead=$(git -C "${git_dir}" rev-list --count "${V0_GIT_REMOTE:-origin}/${V0_DEVELOP_BRANCH:-main}..HEAD" 2>/dev/null || echo "0")

  if [[ "${commits_ahead}" -gt 0 ]]; then
    return 1  # Has commits, normal fix
  fi

  return 0  # Note exists but no commits
}

# Reopen in-progress issues assigned to a worker
# Args: $1 = worker assignee (e.g., "worker:chore", "worker:fix")
reopen_worker_issues() {
  local worker_assignee="$1"

  # Find in-progress issues assigned to this worker
  local issues
  issues=$(wk list --status in_progress --assignee "${worker_assignee}" -o json 2>/dev/null | jq -r '.[].id' || true)

  if [[ -z "${issues}" ]]; then
    return 0
  fi

  while IFS= read -r issue_id; do
    [[ -z "${issue_id}" ]] && continue
    echo "Reopening: ${issue_id} (was assigned to ${worker_assignee})"
    wk reopen "${issue_id}" 2>/dev/null || true
    wk edit "${issue_id}" assignee none 2>/dev/null || true
  done <<< "${issues}"
}
