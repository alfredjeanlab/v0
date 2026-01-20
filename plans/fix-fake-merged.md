# Fix: False Positive "Merged" Status in v0 status

## Overview

`v0 status` occasionally displays operations as "merged" before the code is actually merged to main. This plan identifies root causes and implements verification to ensure the "merged" status only appears when commits are truly on the main branch.

## Project Structure

Key files involved:

```
bin/
  v0-merge      # Performs the actual merge, updates state
  v0-mergeq     # Merge queue daemon, also updates state
  v0-status     # Reads and displays merge status
lib/
  state-machine.sh  # sm_transition_to_merged(), state management
tests/unit/
  v0-merge.bats     # Existing merge tests
  v0-status.bats    # Status display tests
  v0-mergeq.bats    # Queue tests
```

State files:
- `${BUILD_DIR}/operations/${op}/state.json` - Operation state with `phase`, `merge_status`, `merged_at`
- `${BUILD_DIR}/mergeq/queue.json` - Queue entries with `status` field

## Dependencies

- `git` - For commit verification
- `jq` - For JSON state file manipulation
- Existing v0 infrastructure (no new dependencies needed)

## Root Cause Analysis

### Cause 1: No Verification That Commit Exists on Main

**Location:** `bin/v0-merge:569` and `bin/v0-mergeq:825-832`

The current flow marks status as "merged" when `v0-merge` exits 0, but doesn't verify:
1. The merge commit actually exists on the main branch
2. The merge commit has been pushed to `origin/main`

```bash
# Current code in v0-mergeq (lines 825-832)
if [[ ${merge_exit} -eq 0 ]]; then
  # Success - immediately marks as merged without verification
  update_entry "${op}" "completed"
  update_operation_state "${op}" "merge_status" '"merged"'
  update_operation_state "${op}" "merged_at" "\"${merged_at}\""
  update_operation_state "${op}" "phase" '"merged"'
```

### Cause 2: Queue Entry Updated Before State File

**Location:** `bin/v0-mergeq:829-832`

Queue is marked "completed" before `state.json` is updated. If `v0-status` reads between these updates:
```bash
update_entry "${op}" "completed"           # Line 829 - queue shows completed
update_operation_state "${op}" ...         # Lines 830-832 - state still stale
```

### Cause 3: Duplicate State Updates Create Race Conditions

**Location:** `bin/v0-merge:154-178` and `bin/v0-mergeq:825-858`

Both `v0-merge` and `v0-mergeq` update state independently:
- `v0-merge` calls `update_operation_state()` (line 569)
- `v0-merge` calls `update_merge_queue_entry()` (line 569)
- `v0-mergeq` also calls `update_entry()` and `update_operation_state()` (lines 829-832)

### Cause 4: Silent Push Failures

**Location:** `bin/v0-merge:569`

If `git push` fails but the local merge succeeded, the chain `do_merge && cleanup && git push && update_*` stops, but local main has the commits. A subsequent status check might show "merged" based on branch comparison.

### Cause 5: Stale Queue Entries

If an operation was previously merged, deleted, and recreated with the same name, the queue might contain a stale "completed" entry.

## Implementation Phases

### Phase 1: Add Merge Verification Function

Create a verification function that confirms commits are actually on main.

**File:** `lib/v0-common.sh`

```bash
# v0_verify_merge <branch> [require_remote]
# Verify that a branch has been merged to main
# Returns 0 if merged, 1 if not merged
#
# Args:
#   branch         - Branch name to check
#   require_remote - If "true", also verify on origin/main (default: false)
v0_verify_merge() {
  local branch="$1"
  local require_remote="${2:-false}"

  # Get the commit hash of the branch tip
  local branch_commit
  branch_commit=$(git rev-parse "${branch}" 2>/dev/null) || return 1

  # Check if commit is ancestor of local main
  if ! git merge-base --is-ancestor "${branch_commit}" main 2>/dev/null; then
    return 1
  fi

  # Optionally check remote
  if [[ "${require_remote}" = "true" ]]; then
    git fetch origin main --quiet 2>/dev/null || true
    if ! git merge-base --is-ancestor "${branch_commit}" origin/main 2>/dev/null; then
      return 1
    fi
  fi

  return 0
}

# v0_verify_merge_by_op <operation>
# Verify merge using operation's recorded merge commit
v0_verify_merge_by_op() {
  local op="$1"
  local merge_commit
  merge_commit=$(sm_read_state "${op}" "merge_commit")

  if [[ -z "${merge_commit}" ]] || [[ "${merge_commit}" = "null" ]]; then
    return 1  # No recorded merge commit
  fi

  # Verify commit exists on main
  git merge-base --is-ancestor "${merge_commit}" main 2>/dev/null
}
```

**Verification:** Unit tests in `tests/unit/v0-common.bats`

### Phase 2: Record Merge Commit in State

Modify `v0-merge` to record the actual merge commit hash before marking as merged.

**File:** `bin/v0-merge`

Update the merge success path (around line 569):

```bash
do_merge && {
  # Record the merge commit hash BEFORE cleanup
  local merge_commit
  merge_commit=$(git rev-parse HEAD)

  cleanup && git push && {
    # Verify push succeeded by checking remote
    git fetch origin main --quiet
    if git merge-base --is-ancestor "${merge_commit}" origin/main; then
      # Record merge commit in state, then update status
      sm_update_state "$(basename "${BRANCH}")" "merge_commit" "\"${merge_commit}\""
      update_operation_state && update_merge_queue_entry && {
        sm_trigger_dependents "$(basename "${BRANCH}")"
        v0_notify "${PROJECT}: merged" "${BRANCH}"
        git push origin --delete "${BRANCH}" 2>/dev/null || true
      }
    else
      echo "Error: Push succeeded but commit not found on origin/main" >&2
      exit 1
    fi
  }
}
```

**Verification:**
- Test that `merge_commit` is recorded in `state.json`
- Test that merge fails if remote verification fails

### Phase 3: Add Verification to v0-mergeq

Update `v0-mergeq` to verify merge before marking complete.

**File:** `bin/v0-mergeq`

Update `process_merge()` (around line 825):

```bash
if [[ ${merge_exit} -eq 0 ]]; then
  # Verify the merge actually happened
  local branch
  branch=$(jq -r '.branch // empty' "${state_file}")

  if [[ -n "${branch}" ]]; then
    # Give git a moment to sync, then verify
    sleep 1
    if ! v0_verify_merge "${branch}" "true"; then
      echo "[$(date +%H:%M:%S)] Warning: v0-merge exited 0 but branch not on origin/main"
      update_entry "${op}" "failed"
      update_operation_state "${op}" "merge_status" '"verification_failed"'
      update_operation_state "${op}" "merge_error" '"Branch not found on origin/main after merge"'
      return 1
    fi
  fi

  # Verified - now mark as merged
  local merged_at
  merged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Update state.json FIRST, then queue (reverse current order)
  update_operation_state "${op}" "merge_status" '"merged"'
  update_operation_state "${op}" "merged_at" "\"${merged_at}\""
  update_operation_state "${op}" "phase" '"merged"'
  update_entry "${op}" "completed"  # Queue last
  ...
}
```

**Verification:** Integration test that simulates push failure

### Phase 4: Fix Status Display Priorities

Update `v0-status` to verify "merged" claims before displaying.

**File:** `bin/v0-status`

Add verification for stale/suspect merged status (around line 994):

```bash
completed)
  # Queue says completed - verify before displaying as merged
  local merge_commit
  merge_commit=$(sm_read_state "${NAME}" "merge_commit")
  if [[ -n "${merge_commit}" ]] && [[ "${merge_commit}" != "null" ]]; then
    # Has recorded commit - verify it's on main
    if v0_verify_merge_by_op "${NAME}"; then
      echo "Status: completed (merged)"
    else
      echo "Status: completed (== VERIFY FAILED ==)"
    fi
  else
    # No recorded commit - trust queue but flag as unverified
    echo "Status: completed (merged)"
  fi
  ;;
```

**Verification:** Test with mocked git states

### Phase 5: Add Staleness Detection for Queue Entries

Add check for orphaned/stale queue entries.

**File:** `bin/v0-mergeq`

Enhance `is_stale()` function (around line 430):

```bash
is_stale() {
  local op="$1"
  local state_file="${BUILD_DIR}/operations/${op}/state.json"

  # Existing: Check for merged_at
  if [[ -f "${state_file}" ]]; then
    local merged_at
    merged_at=$(jq -r '.merged_at // empty' "${state_file}")
    if [[ -n "${merged_at}" ]]; then
      # Additional: Verify the merge is real
      if v0_verify_merge_by_op "${op}"; then
        echo "already merged at ${merged_at}"
        return 0
      else
        echo "claims merged but verification failed"
        return 0  # Still stale - needs attention
      fi
    fi
  fi

  # Check if operation was recreated (queue entry older than state)
  local queue_file="${MERGEQ_DIR}/queue.json"
  if [[ -f "${queue_file}" ]] && [[ -f "${state_file}" ]]; then
    local queue_time state_time
    queue_time=$(jq -r ".entries[] | select(.operation == \"${op}\") | .queued_at // empty" "${queue_file}")
    state_time=$(jq -r '.created_at // empty' "${state_file}")
    if [[ -n "${queue_time}" ]] && [[ -n "${state_time}" ]]; then
      if [[ "${state_time}" > "${queue_time}" ]]; then
        echo "stale queue entry (operation recreated)"
        return 0
      fi
    fi
  fi

  return 1
}
```

**Verification:** Test with recreated operation scenarios

### Phase 6: Consolidate State Updates

Remove duplicate state updates by having only one source of truth.

**File:** `bin/v0-merge`

Remove the `update_merge_queue_entry()` call from `v0-merge` since `v0-mergeq` already handles this:

```bash
# In v0-merge, change line 569 from:
do_merge && cleanup && git push && update_operation_state && update_merge_queue_entry && {

# To:
do_merge && cleanup && git push && update_operation_state && {
  # Note: Queue update handled by v0-mergeq caller
```

Add a flag to indicate direct merge vs queue-driven merge:

```bash
# When called directly (not via v0-mergeq), update queue
if [[ -z "${V0_MERGEQ_CALLER:-}" ]]; then
  update_merge_queue_entry
fi
```

In `v0-mergeq`, set the flag:
```bash
V0_MERGEQ_CALLER=1 "${V0_DIR}/bin/v0-merge" "${worktree}" 2>&1
```

**Verification:** Test both direct and queue-driven merge paths

## Key Implementation Details

### Git Verification Commands

```bash
# Check if commit is ancestor of branch
git merge-base --is-ancestor <commit> <branch>

# Get current HEAD commit
git rev-parse HEAD

# Fetch latest remote state
git fetch origin main --quiet
```

### State Update Ordering

To prevent race conditions, updates should follow this order:
1. Verify merge on remote
2. Update `state.json` (all fields atomically if possible)
3. Update `queue.json` (last)

### Backward Compatibility

Operations merged before this fix won't have `merge_commit` recorded. The verification should gracefully handle this:
- If `merge_commit` exists: verify it
- If `merge_commit` is missing: trust existing status (legacy behavior)

## Verification Plan

### Unit Tests

1. **`tests/unit/v0-common.bats`**
   - `v0_verify_merge returns 0 for merged branch`
   - `v0_verify_merge returns 1 for unmerged branch`
   - `v0_verify_merge with require_remote checks origin`
   - `v0_verify_merge_by_op uses recorded commit`

2. **`tests/unit/v0-merge.bats`**
   - `merge records merge_commit in state`
   - `merge fails verification if push fails`
   - `direct merge updates queue entry`
   - `queue-driven merge skips duplicate queue update`

3. **`tests/unit/v0-mergeq.bats`**
   - `process_merge verifies before marking complete`
   - `process_merge detects false positive merge`
   - `is_stale detects recreated operations`
   - `state updated before queue entry`

4. **`tests/unit/v0-status.bats`**
   - `status verifies merged claims`
   - `status shows VERIFY FAILED for unverified merges`
   - `status handles missing merge_commit gracefully`

### Integration Tests

1. Create operation, merge, verify status shows "merged"
2. Create operation, simulate push failure, verify status shows error
3. Create operation, merge, delete, recreate with same name, verify no false positive
4. Run concurrent merges, verify no race conditions

### Manual Verification

```bash
# Test 1: Normal merge flow
v0 feature "test-verify-merge"
# ... make changes, complete ...
v0 merge test-verify-merge
v0 status test-verify-merge  # Should show "merged"

# Test 2: Check merge commit recorded
jq '.merge_commit' .v0/build/operations/test-verify-merge/state.json

# Test 3: Verify on remote
git fetch origin main
git merge-base --is-ancestor $(jq -r '.merge_commit' .v0/build/operations/test-verify-merge/state.json) origin/main && echo "Verified"
```
