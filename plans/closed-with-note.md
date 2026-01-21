# Closed-with-Note Handling for v0 fix

## Overview

Implement proper handling when a fix worker adds a note to a bug but doesn't actually commit a fix. This covers scenarios where the agent cannot reproduce the bug, determines it's invalid, or cannot fix it. Instead of allowing the bug to be silently closed or abandoned, the system should redirect it to human review.

## Project Structure

Files to be modified or created:
```
lib/
  hooks/
    stop-fix.sh           # Modify: detect note-without-fix scenario
  worker-common.sh        # Add: helper function for note-without-fix detection
bin/
  v0-fix                  # Modify: handle note-without-fix in fixed/done scripts
tests/
  unit/
    stop-fix-hook.bats    # New: tests for stop-fix.sh hook logic
    worker-common.bats    # Extend: tests for new helper functions
docs/
  debug/
    fix.md                # Update: document new behavior
  technical/
    operations-state-machine.md  # Update: note human handoff flow
```

## Dependencies

- `wk` CLI tool (already in use): `wk note`, `wk edit`, `wk close`, `wk reopen`
- `jq` for JSON manipulation (already in use)
- `git` for detecting commits (already in use)

## Implementation Phases

### Phase 1: Core Detection Logic

**Goal**: Create helper functions to detect the note-without-fix scenario.

**Files**: `lib/worker-common.sh`

Add a new function `detect_note_without_fix` that:
1. Checks if the bug has a recent note (from this session)
2. Checks if there are any commits beyond the develop branch
3. Returns true if note exists but no commits

```bash
# detect_note_without_fix <bug_id>
# Returns 0 (true) if bug has a note but no commits, 1 otherwise
detect_note_without_fix() {
  local bug_id="$1"
  local git_dir="${2:-$(pwd)}"

  # Check for notes on the bug (wk show returns JSON with notes array)
  local notes_count
  notes_count=$(wk show "$bug_id" -f json 2>/dev/null | jq '.notes | length' 2>/dev/null || echo "0")

  if [[ "$notes_count" -eq 0 ]]; then
    return 1  # No notes, normal exit
  fi

  # Check for commits beyond develop branch
  local commits_ahead
  commits_ahead=$(git -C "$git_dir" rev-list --count "${V0_GIT_REMOTE:-origin}/${V0_DEVELOP_BRANCH:-main}..HEAD" 2>/dev/null || echo "0")

  if [[ "$commits_ahead" -gt 0 ]]; then
    return 1  # Has commits, normal fix
  fi

  return 0  # Note exists but no commits
}
```

**Verification**: Unit tests pass for the detection function.

### Phase 2: Modify Stop Hook

**Goal**: Update `stop-fix.sh` to detect and handle the note-without-fix scenario.

**Files**: `lib/hooks/stop-fix.sh`

Modify the hook to:
1. Check for in-progress bugs with notes but no commits
2. When detected:
   - Log the scenario appropriately
   - Reassign to `worker:human`
   - Block the stop to ensure bug stays in_progress
   - Provide clear guidance message

```bash
# After checking for IN_PROGRESS bugs, add this logic:
for bug_id in $(wk list --type bug --status in_progress -f json 2>/dev/null | jq -r '.issues[].id'); do
  if detect_note_without_fix "$bug_id" "$REPO_DIR"; then
    # Log the handoff
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Bug $bug_id has note but no fix - handing to human" >> "$LOG_FILE"

    # Reassign to human
    wk edit "$bug_id" assignee "worker:human" 2>/dev/null || true

    # Block with helpful message
    echo "{\"decision\": \"block\", \"reason\": \"Bug $bug_id has a note but no fix. Reassigned to human for review. Use 'wk show $bug_id' to see the note, then either fix it or close with 'wk close $bug_id -r reason'.\"}"
    exit 0
  fi
done
```

**Verification**: Hook correctly detects and handles the scenario in integration tests.

### Phase 3: Modify Helper Scripts

**Goal**: Update the `fixed` and `done` scripts to handle edge cases gracefully.

**Files**: `bin/v0-fix` (the generated `fixed` script)

Modify the `fixed` script to:
1. Check for commits before attempting to push
2. If no commits but bug has notes, trigger the handoff flow instead of failing

```bash
# In the fixed script, before the push section:
COMMITS_AHEAD=$(git rev-list --count "${V0_GIT_REMOTE}/${V0_DEVELOP_BRANCH}..HEAD" 2>/dev/null || echo "0")

if [[ "$COMMITS_AHEAD" -eq 0 ]]; then
  # No commits - check if there's a note
  NOTES_COUNT=$(wk show "$BUG_ID" -f json 2>/dev/null | jq '.notes | length' 2>/dev/null || echo "0")

  if [[ "$NOTES_COUNT" -gt 0 ]]; then
    echo "Bug has note but no fix commits - handing to human for review"
    wk edit "$BUG_ID" assignee "worker:human" 2>/dev/null || true
    echo "Assigned $BUG_ID to worker:human"
    # Exit cleanly without pushing or closing
    touch "${tree_dir}/.done-exit"
    exit 0
  else
    echo "Error: No commits to push and no notes explaining why"
    exit 1
  fi
fi
```

**Verification**: `./fixed` handles the no-commit scenario gracefully.

### Phase 4: Test Suite

**Goal**: Comprehensive tests for the new behavior.

**Files**: `tests/unit/stop-fix-hook.bats` (new), `tests/unit/worker-common.bats` (extend)

New test file `stop-fix-hook.bats`:

```bash
# Test cases:
# 1. Normal exit with no in-progress bugs -> approve
# 2. In-progress bug with commits -> block (normal flow)
# 3. In-progress bug with note but no commits -> block with reassignment
# 4. In-progress bug with no note and no commits -> block (normal flow)
# 5. System stop reason (auth/credit) -> approve immediately
# 6. Stop hook already active -> approve
```

Extend `worker-common.bats`:

```bash
# Test cases for detect_note_without_fix:
# 1. Bug with note and no commits -> returns 0
# 2. Bug with note and commits -> returns 1
# 3. Bug without note -> returns 1
# 4. Invalid bug ID -> returns 1
# 5. wk command fails gracefully
```

**Verification**: All tests pass with `make test`.

### Phase 5: Documentation Updates

**Goal**: Update technical documentation to reflect the new behavior.

**Files**:
- `docs/debug/fix.md`
- `docs/technical/operations-state-machine.md`

Updates to `docs/debug/fix.md`:
- Add new state diagram branch for "note without fix"
- Document the `worker:human` handoff flow
- Add troubleshooting section for human-assigned bugs

Updates to `docs/technical/operations-state-machine.md`:
- Document the human handoff flow for fix workers
- Add note about `worker:human` assignee semantics

**Verification**: Documentation is consistent with implementation.

## Key Implementation Details

### Note Detection Strategy

Use `wk show <id> -f json` to get structured data about the bug including its notes. The notes array will be populated if the agent added documentation about reproduction failure or other issues.

### Human Assignment Semantics

The `worker:human` assignee indicates:
- Bug requires human attention
- Agent documented why they couldn't fix it (check notes)
- Human should either:
  - Fix it manually
  - Close with `wk close <id> -r "reason"`
  - Reassign back to worker if issue was transient

### Logging

All handoffs should be logged to:
1. The polling daemon log (`/tmp/v0-{project}-fix-polling.log`)
2. The worker error log if appropriate
3. The bug's own note history (already done by agent)

### Edge Cases

1. **Multiple in-progress bugs**: Handle each independently in the stop hook
2. **wk command failures**: Use `|| true` to prevent stop hook from crashing
3. **Race conditions**: The stop hook runs synchronously, so no race with polling
4. **Agent closes bug directly**: The stop hook doesn't intercept `wk close`, but the polling loop will detect the bug is no longer in-progress

## Verification Plan

### Unit Tests

1. Run `make test-file FILE=tests/unit/stop-fix-hook.bats`
2. Run `make test-file FILE=tests/unit/worker-common.bats`

### Integration Tests

1. Create a test bug: `wk new bug "Test note-without-fix"`
2. Start the fix worker: `v0 fix --start`
3. In the worker session:
   - `wk start <bug-id>`
   - `./new-branch <bug-id>`
   - `wk note <bug-id> "Cannot reproduce - needs more info"`
   - `./done`
4. Verify:
   - Bug is still in_progress: `wk show <bug-id>` shows status=in_progress
   - Bug assigned to human: `wk show <bug-id>` shows assignee=worker:human
   - Note is preserved: `wk show <bug-id>` shows the note

### Lint Check

Run `make lint` to ensure all shell scripts pass ShellCheck.

### Regression Tests

Run full test suite with `make test` to ensure no regressions.
