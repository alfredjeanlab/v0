# Session Leak Prevention

**Goal**: Prevent orphaned Claude processes by adding PID file tracking as a fallback cleanup mechanism.

**Problem**: Claude processes can become orphaned when:
1. Tmux session dies but Claude survives
2. State files are pruned while processes still run
3. Pattern-based process detection (`pgrep -f`) misses processes
4. Shutdown doesn't find all running sessions

**Solution**: Write a `.claude.pid` file on every Claude launch, then use it as a fallback in all cleanup paths.

---

## Phase 1: PID File on Claude Launch

**Goal**: Capture Claude PID every time a worker launches Claude.

**File**: `lib/worker-common.sh`

Modify `create_wrapper_script` to capture PID instead of using `exec`:

```bash
# Current approach (loses control after exec):
exec "${v0_dir}/lib/try-catch.sh" ... claude ...

# New approach (captures PID, waits for exit):
"${v0_dir}/lib/try-catch.sh" ... claude ... &
CLAUDE_PID=$!
echo "${CLAUDE_PID}" > "${tree_dir}/.claude.pid"
wait ${CLAUDE_PID}
EXIT_CODE=$?
rm -f "${tree_dir}/.claude.pid"
exit ${EXIT_CODE}
```

**Note**: The wrapper script itself runs inside tmux. We're capturing the PID of the try-catch/claude process tree.

**Verification**: After launching a worker, `.claude.pid` exists in tree_dir and contains valid PID.

---

## Phase 2: Safe Kill Helper Function

**Goal**: Add a helper function that safely kills Claude using the PID file, with cwd validation.

**File**: `lib/worker-common.sh`

Add new function:

```bash
# Kill Claude process using PID file with safety validation
# Args: $1 = tree_dir
# Returns: 0 on success, 1 if no pid file, 2 if validation failed
safe_kill_claude() {
  local tree_dir="$1"
  local pid_file="${tree_dir}/.claude.pid"

  [[ ! -f "${pid_file}" ]] && return 1

  local pid
  pid=$(cat "${pid_file}" 2>/dev/null)
  [[ -z "${pid}" ]] && { rm -f "${pid_file}"; return 1; }

  # Check if process still exists
  if ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${pid_file}"
    return 0  # Already dead, success
  fi

  # Validate: process cwd should be in our tree
  local cwd
  cwd=$(lsof -p "${pid}" 2>/dev/null | awk '/cwd/{print $NF}')

  if [[ -z "${cwd}" ]] || [[ "${cwd}" != "${tree_dir}"* ]]; then
    echo "Warning: PID ${pid} cwd '${cwd}' doesn't match tree '${tree_dir}', skipping" >&2
    rm -f "${pid_file}"  # Stale PID file
    return 2
  fi

  # Safe to kill
  kill -TERM "${pid}" 2>/dev/null || true

  # Wait briefly for graceful shutdown
  local i
  for i in 1 2 3; do
    sleep 0.5
    kill -0 "${pid}" 2>/dev/null || break
  done

  # Force kill if still alive
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi

  rm -f "${pid_file}"
  return 0
}
```

**Verification**: `safe_kill_claude /path/to/tree` kills the process and removes PID file.

---

## Phase 3: Update `done` Script

**Goal**: Add PID file cleanup as fallback after normal exit.

**File**: `lib/worker-common.sh` (in `create_done_script`)

The done script already kills Claude by walking up the process tree. Add fallback:

```bash
# After the existing find_claude/kill logic:

# Fallback: clean up via PID file if it exists
if [[ -f "${tree_dir}/.claude.pid" ]]; then
  pid=\$(cat "${tree_dir}/.claude.pid" 2>/dev/null)
  if [[ -n "\${pid}" ]] && kill -0 "\${pid}" 2>/dev/null; then
    kill -TERM "\${pid}" 2>/dev/null || true
  fi
  rm -f "${tree_dir}/.claude.pid"
fi
```

**Verification**: `./done` exits Claude and removes `.claude.pid`.

---

## Phase 4: Update `fixed` Script

**Goal**: Add PID file cleanup as fallback after normal exit.

**Files**: `bin/v0-fix`, `bin/v0-chore` (in the generated `fixed` script)

Same pattern as done script - add fallback after existing kill logic:

```bash
# After existing find_claude/kill logic:

# Fallback: clean up via PID file if it exists
if [[ -f "${tree_dir}/.claude.pid" ]]; then
  pid=\$(cat "${tree_dir}/.claude.pid" 2>/dev/null)
  if [[ -n "\${pid}" ]] && kill -0 "\${pid}" 2>/dev/null; then
    kill -TERM "\${pid}" 2>/dev/null || true
  fi
  rm -f "${tree_dir}/.claude.pid"
fi
```

**Verification**: `./fixed <id>` exits Claude and removes `.claude.pid`.

---

## Phase 5: Update Shutdown

**Goal**: Kill Claude processes via PID files during shutdown.

**File**: `bin/v0-shutdown`

After killing tmux sessions (line ~110), add PID file cleanup:

```bash
# Kill any remaining Claude processes via PID files
echo ""
echo "Cleaning up Claude processes..."
for tree_root in "${XDG_TREE_ROOT}" "${GIT_TREE_ROOT}"; do
  [[ ! -d "${tree_root}" ]] && continue

  for pid_file in "${tree_root}"/*/.claude.pid "${tree_root}"/*/*/.claude.pid; do
    [[ ! -f "${pid_file}" ]] && continue

    local tree_dir
    tree_dir=$(dirname "${pid_file}")

    if [[ -n "${DRY_RUN}" ]]; then
      echo "Would kill Claude in: ${tree_dir}"
    else
      # Source helper if not already available
      source "${V0_DIR}/lib/worker-common.sh" 2>/dev/null || true
      if type safe_kill_claude &>/dev/null; then
        safe_kill_claude "${tree_dir}"
      else
        # Inline fallback
        pid=$(cat "${pid_file}" 2>/dev/null)
        if [[ -n "${pid}" ]]; then
          kill -TERM "${pid}" 2>/dev/null || true
        fi
        rm -f "${pid_file}"
      fi
    fi
  done
done
```

**Verification**: `v0 shutdown` kills Claude processes even if tmux sessions are already dead.

---

## Phase 6: Update Prune

**Goal**: Kill associated processes before removing state.

**File**: `bin/v0-prune`

In `prune_operation()`, before removing the operation directory, add process cleanup:

```bash
prune_operation() {
  local name="$1"
  local op_dir="${BUILD_DIR}/operations/${name}"

  # ... existing session check ...

  # NEW: Kill Claude process if PID file exists
  if sm_state_exists "${name}"; then
    local worktree
    worktree=$(sm_read_state "${name}" "worktree")
    if [[ -n "${worktree}" ]] && [[ "${worktree}" != "null" ]]; then
      local tree_dir
      tree_dir=$(dirname "${worktree}")

      # Source helper and kill Claude
      source "${V0_DIR}/lib/worker-common.sh" 2>/dev/null || true
      if type safe_kill_claude &>/dev/null; then
        safe_kill_claude "${tree_dir}" 2>/dev/null || true
      fi
    fi
  fi

  # ... existing rm -rf ...
}
```

**Verification**: `v0 prune <name>` kills Claude before removing state.

---

## Phase 7: Update Nudge (Fallback)

**Goal**: Use PID file as fallback when terminating idle sessions.

**File**: `bin/v0-nudge`

In `handle_session_complete` and `handle_session_error`, add fallback:

```bash
handle_session_complete() {
  local session="$1"
  local tree_dir="$2"

  # ... existing logging ...

  # Primary: Kill tmux session
  tmux kill-session -t "${session}" 2>/dev/null || true

  # Fallback: Kill via PID file
  if [[ -n "${tree_dir}" ]] && [[ -f "${tree_dir}/.claude.pid" ]]; then
    local pid
    pid=$(cat "${tree_dir}/.claude.pid" 2>/dev/null)
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
    fi
    rm -f "${tree_dir}/.claude.pid"
  fi

  # ... rest of function ...
}
```

Apply same pattern to `handle_session_error`.

**Verification**: Nudge cleans up PID files when terminating sessions.

---

## Phase 8: Update Feature Worker

**Goal**: Add PID file tracking to feature worker Claude sessions.

**File**: `bin/v0-feature-worker`

The feature worker launches Claude directly in the tmux command (~line 585-588).
Modify to wrap Claude and capture PID:

```bash
# Current:
tmux new-session -d -s "${SESSION}" -c "${TREE_DIR}" \
  "V0_OP='${NAME}' ... claude ${CLAUDE_ARGS} '...'; \
   '${TREE_DIR}/.claude/on-complete.sh'; \
   echo ''; echo 'Session complete...'; sleep 5"

# New:
tmux new-session -d -s "${SESSION}" -c "${TREE_DIR}" \
  "V0_OP='${NAME}' ... claude ${CLAUDE_ARGS} '...' & \
   CLAUDE_PID=\$!; \
   echo \"\${CLAUDE_PID}\" > '${TREE_DIR}/.claude.pid'; \
   wait \${CLAUDE_PID}; \
   rm -f '${TREE_DIR}/.claude.pid'; \
   '${TREE_DIR}/.claude/on-complete.sh'; \
   echo ''; echo 'Session complete...'; sleep 5"
```

Also update the on-complete.sh script (~line 549) to include PID fallback cleanup:

```bash
# Add to on-complete.sh before find_claude():
# Fallback: clean up via PID file if it exists
if [[ -f "${TREE_DIR}/.claude.pid" ]]; then
  pid=$(cat "${TREE_DIR}/.claude.pid" 2>/dev/null)
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
  fi
  rm -f "${TREE_DIR}/.claude.pid"
fi
```

**Verification**: Feature worker creates `.claude.pid`, on-complete removes it.

---

## Phase 9: Update Merge Resolve

**Goal**: Add PID file tracking to `v0 merge --resolve` sessions.

**File**: `bin/v0-merge`

The merge command launches Claude directly in a resolve script (not via worker-common.sh).
Update both resolve script generators to write PID files.

For uncommitted changes resolution (~line 280):

```bash
cat > "${resolve_script}" <<RESOLVE_EOF
#!/bin/bash
set -e

# Write Claude PID for cleanup
claude --model opus ... &
CLAUDE_PID=\$!
echo "\${CLAUDE_PID}" > "${TREE_DIR}/.claude.pid"
wait \${CLAUDE_PID}
EXIT_CODE=\$?
rm -f "${TREE_DIR}/.claude.pid"
exit \${EXIT_CODE}
RESOLVE_EOF
```

For conflict resolution (~line 470):

```bash
cat > "${RESOLVE_SCRIPT}" <<'RESOLVE_SCRIPT_EOF'
#!/bin/bash
# ... existing setup ...

# Write Claude PID for cleanup
claude --model opus ... &
CLAUDE_PID=$!
echo "${CLAUDE_PID}" > "${TREE_DIR}/.claude.pid"
wait ${CLAUDE_PID}
EXIT_CODE=$?
rm -f "${TREE_DIR}/.claude.pid"
exit ${EXIT_CODE}
RESOLVE_SCRIPT_EOF
```

Update the done script in merge (~line 407) to include PID fallback:

```bash
# After existing find_claude/kill logic:
if [[ -f "${TREE_DIR}/.claude.pid" ]]; then
  pid=\$(cat "${TREE_DIR}/.claude.pid" 2>/dev/null)
  if [[ -n "\${pid}" ]] && kill -0 "\${pid}" 2>/dev/null; then
    kill -TERM "\${pid}" 2>/dev/null || true
  fi
  rm -f "${TREE_DIR}/.claude.pid"
fi
```

**Verification**: `v0 merge <tree> --resolve` creates `.claude.pid`, cleanup removes it.

---

## Phase 10: Add Polling Daemon PID File

**Goal**: Track polling daemon PID for reliable cleanup.

**File**: `lib/worker-common.sh`

In `create_polling_loop`, write PID from inside the nohup:

```bash
nohup bash -c "
  # Write our PID immediately
  echo \$\$ > '${tree_dir}/.polling-daemon.pid'

  # ... rest of polling loop ...
" > "${polling_log}" 2>&1 &
```

Update `stop_worker_clean` and `generic_stop_worker` to use PID file:

```bash
# Kill polling daemon via PID file
if [[ -f "${tree_dir}/.polling-daemon.pid" ]]; then
  local pid
  pid=$(cat "${tree_dir}/.polling-daemon.pid" 2>/dev/null)
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
  fi
  rm -f "${tree_dir}/.polling-daemon.pid"
fi

# Fallback: pattern-based kill (existing behavior)
pkill -f "while true.*${WORKER_SESSION}" 2>/dev/null || true
```

**Verification**: `v0 fix stop` reliably kills polling daemon.

---

## Summary

| File | Change |
|------|--------|
| `lib/worker-common.sh` | Add `safe_kill_claude()`, update `create_wrapper_script`, `create_done_script`, `create_polling_loop` |
| `bin/v0-fix` | Add PID cleanup to generated `fixed` script |
| `bin/v0-chore` | Add PID cleanup to generated `fixed` script |
| `bin/v0-feature-worker` | Add PID file to tmux launch, fallback in on-complete.sh |
| `bin/v0-merge` | Add PID file to resolve scripts, fallback in done script |
| `bin/v0-shutdown` | Add PID file scan after tmux cleanup |
| `bin/v0-prune` | Kill processes before removing state |
| `bin/v0-nudge` | Add PID file fallback in handlers |

## Testing

### Unit Tests

**File**: `tests/unit/pid-cleanup.bats`

```bash
#!/usr/bin/env bats
# Tests for PID file cleanup functionality

load '../test_helper'

setup() {
  setup_test_project
  source "${V0_DIR}/lib/worker-common.sh"
}

teardown() {
  teardown_test_project
}

@test "safe_kill_claude: kills process with matching cwd" {
  local tree_dir="${TEST_TREE_DIR}"
  mkdir -p "${tree_dir}"

  # Start a mock process in tree_dir
  (cd "${tree_dir}" && sleep 60) &
  local pid=$!
  echo "${pid}" > "${tree_dir}/.claude.pid"

  # Should kill the process
  run safe_kill_claude "${tree_dir}"
  assert_success

  # Process should be dead
  ! kill -0 "${pid}" 2>/dev/null

  # PID file should be removed
  [[ ! -f "${tree_dir}/.claude.pid" ]]
}

@test "safe_kill_claude: skips process with non-matching cwd" {
  local tree_dir="${TEST_TREE_DIR}"
  local other_dir="${TEST_TMP}/other"
  mkdir -p "${tree_dir}" "${other_dir}"

  # Start a process in a different directory
  (cd "${other_dir}" && sleep 60) &
  local pid=$!
  echo "${pid}" > "${tree_dir}/.claude.pid"

  # Should not kill the process (cwd doesn't match)
  run safe_kill_claude "${tree_dir}"
  assert_output --partial "doesn't match"

  # Process should still be alive
  kill -0 "${pid}" 2>/dev/null

  # Clean up
  kill "${pid}" 2>/dev/null || true
}

@test "safe_kill_claude: handles missing PID file" {
  local tree_dir="${TEST_TREE_DIR}"
  mkdir -p "${tree_dir}"

  run safe_kill_claude "${tree_dir}"
  assert_failure 1  # Returns 1 for missing file
}

@test "safe_kill_claude: handles stale PID (process already dead)" {
  local tree_dir="${TEST_TREE_DIR}"
  mkdir -p "${tree_dir}"

  # Write a PID that doesn't exist
  echo "99999999" > "${tree_dir}/.claude.pid"

  run safe_kill_claude "${tree_dir}"
  assert_success

  # PID file should be removed
  [[ ! -f "${tree_dir}/.claude.pid" ]]
}

@test "create_wrapper_script: writes PID file" {
  local tree_dir="${TEST_TREE_DIR}"
  mkdir -p "${tree_dir}"

  create_wrapper_script "${tree_dir}" "test.log" "test-worker" "test cmd" "${V0_DIR}" echo "hello"

  # Verify wrapper script exists and contains PID logic
  [[ -f "${tree_dir}/claude-worker.sh" ]]
  grep -q ".claude.pid" "${tree_dir}/claude-worker.sh"
}

@test "create_done_script: includes PID cleanup fallback" {
  local tree_dir="${TEST_TREE_DIR}"
  mkdir -p "${tree_dir}"

  create_done_script "${tree_dir}" "test"

  # Verify done script exists and contains PID fallback
  [[ -f "${tree_dir}/done" ]]
  grep -q ".claude.pid" "${tree_dir}/done"
}
```

**File**: `tests/unit/polling-daemon-pid.bats`

```bash
#!/usr/bin/env bats
# Tests for polling daemon PID file functionality

load '../test_helper'

setup() {
  setup_test_project
  export WORKER_SESSION="v0-test-worker"
}

teardown() {
  # Clean up any test daemons
  pkill -f "while true.*v0-test-worker" 2>/dev/null || true
  teardown_test_project
}

@test "polling daemon writes PID file" {
  skip "Requires full integration test environment"
  # Would test that create_polling_loop writes .polling-daemon.pid
}

@test "stop_worker_clean uses PID file" {
  local tree_dir="${TEST_TREE_DIR}"
  mkdir -p "${tree_dir}"

  # Create mock PID file
  echo "$$" > "${tree_dir}/.polling-daemon.pid"

  # Verify the function reads PID file
  source "${V0_DIR}/lib/worker-common.sh"
  # Test would verify PID file is checked
}
```

### Manual Integration Tests

1. **Fix worker lifecycle**:
   ```bash
   v0 fix start
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should exist
   # In worker: ./done
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should not exist
   ```

2. **Chore worker lifecycle**:
   ```bash
   v0 chore start
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should exist
   # In worker: ./fixed <id>
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should not exist
   ```

3. **Feature worker lifecycle**:
   ```bash
   v0 feature my-feature
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should exist
   # Wait for completion or cancel
   v0 shutdown
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should not exist
   ```

4. **Merge resolve lifecycle**:
   ```bash
   # Create conflict scenario
   v0 merge <tree> --resolve
   ls <tree>/.claude.pid  # Should exist
   # Complete resolution
   ls <tree>/.claude.pid  # Should not exist
   ```

5. **Shutdown cleans all PIDs**:
   ```bash
   v0 fix start && v0 chore start
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Multiple files
   v0 shutdown
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should not exist
   ```

6. **Prune cleans PIDs**:
   ```bash
   v0 feature test-prune
   v0 prune test-prune
   ls ~/.local/state/v0/*/tree/*/.claude.pid  # Should not exist
   ps aux | grep claude  # No orphaned processes
   ```

7. **Orphan detection**:
   ```bash
   v0 fix start
   tmux kill-session -t v0-*-fix-worker  # Kill tmux but not claude
   v0 shutdown  # Should still find and kill via PID file
   ps aux | grep claude  # No orphaned processes
   ```
