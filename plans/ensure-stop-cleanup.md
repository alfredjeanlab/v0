# Plan: ensure-stop-cleanup

## Overview

Add cleanup logic to `v0 chore --stop` and `v0 fix --stop` commands that reopens in-progress issues assigned to the respective workers. Currently, these commands clean up worktrees and branches but leave issues in `in_progress` status with worker assignees, requiring `v0 shutdown` for full cleanup.

## Project Structure

```
bin/
  v0-chore           # Chore worker command (modify stop_worker)
  v0-fix             # Fix worker command (modify stop_worker)
  v0-shutdown        # Reference implementation of issue reopening (lines 137-161)
lib/
  worker-common.sh   # Shared worker functions (add new helper)
tests/
  unit/
    worker-common.bats  # Add tests for new function
```

## Dependencies

- `wk` CLI tool (already in use) - uses `wk reopen` and `wk edit ... assignee none`
- No new external dependencies required

## Implementation Phases

### Phase 1: Add shared helper function to worker-common.sh

Add a new function `reopen_worker_issues()` to `lib/worker-common.sh` that:
1. Takes the worker assignee name as an argument (e.g., `worker:chore` or `worker:fix`)
2. Queries for in-progress issues assigned to that worker using `wk list`
3. Reopens each issue using `wk reopen`
4. Clears the assignee using `wk edit ... assignee none`

```bash
# Reopen in-progress issues assigned to a worker
# Args: $1 = worker assignee (e.g., "worker:chore", "worker:fix")
reopen_worker_issues() {
  local worker_assignee="$1"

  # Find in-progress issues assigned to this worker
  local issues
  issues=$(wk list --status in_progress --assignee "${worker_assignee}" -f json 2>/dev/null | jq -r '.issues[].id' || true)

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
```

**Verification:** Unit test in `tests/unit/worker-common.bats`

### Phase 2: Integrate into v0-chore --stop

Modify `stop_worker()` in `bin/v0-chore` (around line 533) to call the new helper before cleaning up the worktree.

For the standard mode (lines 537-538):
```bash
stop_worker() {
  if [[ -n "${STANDALONE:-}" ]]; then
    stop_worker_standalone
  else
    reopen_worker_issues "worker:chore"
    generic_stop_worker "${WORKER_SESSION}" "${WORKER_BRANCH}"
  fi
}
```

For standalone mode (`stop_worker_standalone` starting at line 542), add the reopen call before cleanup.

**Verification:** Manual test with `v0 chore --stop` while a chore is in progress

### Phase 3: Integrate into v0-fix --stop

Modify `stop_worker()` in `bin/v0-fix` (around line 375) to call the new helper:

```bash
stop_worker() {
  reopen_worker_issues "worker:fix"
  generic_stop_worker "${WORKER_SESSION}" "${WORKER_BRANCH}"
}
```

**Verification:** Manual test with `v0 fix --stop` while a bug is in progress

### Phase 4: Add unit tests

Create tests in `tests/unit/worker-common.bats` for:
1. `reopen_worker_issues` with no matching issues (should succeed silently)
2. `reopen_worker_issues` with matching issues (should call wk reopen and wk edit)
3. `reopen_worker_issues` handles wk command failures gracefully

### Phase 5: Update v0-shutdown to use shared helper

Refactor `v0-shutdown` (lines 137-161) to use the new `reopen_worker_issues()` function, eliminating code duplication:

```bash
# Reopen in-progress issues owned by workers being shut down
echo ""
echo "Checking for in-progress issues to reopen..."

for worker in "worker:fix" "worker:chore"; do
  if [[ -n "${DRY_RUN}" ]]; then
    # Show what would be reopened
    issues=$(wk list --status in_progress --assignee "${worker}" -f json 2>/dev/null | jq -r '.issues[].id' || true)
    while IFS= read -r issue_id; do
      [[ -z "${issue_id}" ]] && continue
      echo "Would reopen: ${issue_id} (was assigned to ${worker})"
    done <<< "${issues}"
  else
    reopen_worker_issues "${worker}"
  fi
done
```

**Verification:** `v0 shutdown --dry-run` shows correct behavior

## Key Implementation Details

### wk reopen vs wk stop

The existing `v0-shutdown` uses `wk stop` which moves issues back to `todo` status. The user requested `wk reopen` which does the same thing. Both commands return issues to the `todo` status, so `wk reopen` will be used as specified.

### Order of operations

The issue reopen must happen **before** worktree cleanup because:
1. The worktree may have the `.wok` database linked
2. Ensures issues are reopened even if worktree cleanup fails

### Error handling

All `wk` commands are called with `|| true` to prevent stop failures if issues have already been cleaned up or `wk` encounters errors. This matches the existing pattern in `v0-shutdown`.

### Dry-run support

For `v0-shutdown`, the dry-run mode is preserved by checking `$DRY_RUN` before calling the helper. The `--stop` commands in `v0-chore` and `v0-fix` do not have dry-run support, so they will always perform the cleanup.

## Verification Plan

1. **Unit tests**: Run `make test-file FILE=tests/unit/worker-common.bats`
2. **Lint check**: Run `make lint`
3. **Integration test - chore**:
   - Start chore worker: `v0 chore`
   - Create a chore: `wk new chore "Test chore"`
   - Wait for worker to pick it up (status becomes `in_progress`)
   - Stop worker: `v0 chore --stop`
   - Verify issue is reopened: `wk list --type chore --status todo`
4. **Integration test - fix**:
   - Start fix worker: `v0 fix`
   - Create a bug: `wk new bug "Test bug"`
   - Wait for worker to pick it up
   - Stop worker: `v0 fix --stop`
   - Verify issue is reopened: `wk list --type bug --status todo`
5. **Shutdown test**:
   - Verify `v0 shutdown` still works correctly with refactored code
   - Test `v0 shutdown --dry-run` shows expected output
