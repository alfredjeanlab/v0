# Implementation Plan: `wk start` and `wk done` Integration

## Overview

Add proper wok epic lifecycle tracking to v0 operations:
1. Mark epics as "in_progress" with `wk start` when agents begin implementation (not during planning)
2. Mark epics as "done" with `wk done` when merges complete successfully
3. Ensure proper ordering: epic marked done BEFORE triggering dependent operations

## Project Structure

```
packages/state/lib/transitions.sh    # Add wk start to sm_transition_to_executing
packages/mergeq/lib/processing.sh    # Add wk done for branch merges
packages/state/tests/transitions.bats # Unit tests for transitions
packages/mergeq/tests/processing.bats # Unit tests for branch merge wk done
```

## Dependencies

- `wk` (wok CLI) - Already a project dependency
- No new external dependencies required

## Implementation Phases

### Phase 1: Add `wk start` on Operation Execution

**Goal**: Mark the operation's wok epic as "in_progress" when the agent starts implementation.

**Files to modify**: `packages/state/lib/transitions.sh`

**Changes**:
Add `wk start` call to `sm_transition_to_executing()` after the phase transition succeeds:

```bash
# In sm_transition_to_executing(), after line 131:

  # Mark the wok epic as in_progress when execution starts
  _sm_start_wok_epic "${op}"
```

Add new helper function `_sm_start_wok_epic`:

```bash
# _sm_start_wok_epic <op>
# Internal helper to mark the operation's wok epic as started (in_progress)
# Called when agent begins implementation work
_sm_start_wok_epic() {
  local op="$1"
  local epic_id

  epic_id=$(sm_read_state "${op}" "epic_id")
  if [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]]; then
    return 0  # No epic to start
  fi

  # Check if already in_progress or done
  local status
  status=$(wk show "${epic_id}" -o json 2>/dev/null | jq -r '.status // "unknown"')
  case "${status}" in
    in_progress|done|closed) return 0 ;;  # Already started or completed
  esac

  # Mark as in_progress
  if ! wk start "${epic_id}" 2>/dev/null; then
    sm_emit_event "${op}" "wok:warn" "Failed to start epic ${epic_id}"
  fi
}
```

**Verification**:
- Run `scripts/test state` to verify unit tests pass
- Manual test: Create operation, verify epic is "todo", transition to executing, verify epic is "in_progress"

### Phase 2: Add `wk done` for Branch Merges in Merge Queue

**Goal**: Mark the associated wok issue as "done" when a branch merge completes successfully.

**Files to modify**: `packages/mergeq/lib/processing.sh`

**Context**: The `mq_process_branch_merge` function handles merges for branches without operation state (e.g., `fix/*` branches from v0-fix). These branches have an associated `issue_id` tracked in the queue entry, but currently the issue is not marked done after merge.

**Changes**:
Add `wk done` call in `mq_process_branch_merge()` success paths, BEFORE calling `mq_trigger_dependents_by_issue`:

1. After direct merge success (around line 181):
```bash
        # Mark the associated issue as done BEFORE triggering dependents
        if [[ -n "${issue_id}" ]]; then
            v0_trace "mergeq:branch:wok" "Marking issue ${issue_id} as done"
            _mq_mark_issue_done "${issue_id}" "Merged to ${V0_DEVELOP_BRANCH}"
        fi

        # Trigger dependent operations now that this issue is merged
        if [[ -n "${issue_id}" ]]; then
```

2. After resolution success (around line 204):
```bash
            # Mark the associated issue as done BEFORE triggering dependents
            if [[ -n "${issue_id}" ]]; then
                v0_trace "mergeq:branch:wok" "Marking issue ${issue_id} as done (after resolution)"
                _mq_mark_issue_done "${issue_id}" "Merged to ${V0_DEVELOP_BRANCH} (after resolution)"
            fi

            # Trigger dependent operations now that this issue is merged
```

Add helper function (near top of file or in a shared location):
```bash
# _mq_mark_issue_done <issue_id> <reason>
# Mark a wok issue as done with the given reason
_mq_mark_issue_done() {
    local issue_id="$1"
    local reason="$2"

    # Check if already done/closed
    local status
    status=$(wk show "${issue_id}" -o json 2>/dev/null | jq -r '.status // "unknown"')
    case "${status}" in
        done|closed) return 0 ;;  # Already closed
    esac

    # If in 'todo' status, start it first (wk done requires in_progress -> done)
    if [[ "${status}" == "todo" ]]; then
        wk start "${issue_id}" 2>/dev/null || true
    fi

    # Mark as done
    if ! wk done "${issue_id}" --reason "${reason}" 2>/dev/null; then
        echo "[$(date +%H:%M:%S)] Warning: Failed to mark issue ${issue_id} as done" >&2
    fi
}
```

**Verification**:
- Run `scripts/test mergeq` to verify unit tests pass
- Manual test: Create bug via `v0 fix`, let it complete and merge, verify the bug issue is marked done

### Phase 3: Verify All Success Paths in v0-merge

**Goal**: Ensure all success paths in `bin/v0-merge` properly trigger `wk done` via `mg_finalize_merge`.

**Analysis of success paths in v0-merge**:

| Line | Path | Calls `mg_finalize_merge`? | `wk done` triggered? |
|------|------|---------------------------|---------------------|
| 178-179 | After conflict resolution | Yes | Yes (via `sm_transition_to_merged`) |
| 201-202 | With worktree | Yes | Yes |
| 212-213 | Without worktree | Yes | Yes |
| 229-230 | After rebase | Yes | Yes |

**Conclusion**: All v0-merge success paths already call `mg_finalize_merge`, which calls `mg_update_operation_state`, which calls `sm_transition_to_merged`, which calls `_sm_close_wok_epic`. **No changes needed** in v0-merge.

**Verification**:
- Run `scripts/test v0-merge` to verify existing tests still pass

### Phase 4: Verify All Success Paths in Merge Queue Processing

**Goal**: Ensure all success paths in `mq_process_merge` and `mq_process_branch_merge` mark epics/issues as done before triggering dependents.

**Analysis of success paths in processing.sh**:

| Function | Line | Path | `wk done` before dependents? |
|----------|------|------|------------------------------|
| `mq_process_branch_merge` | 177-188 | Direct merge success | **NO** - needs fix (Phase 2) |
| `mq_process_branch_merge` | 201-213 | After resolution | **NO** - needs fix (Phase 2) |
| `mq_process_merge` | 326-354 | Operation merge success | Yes (line 328 calls `sm_transition_to_merged` which calls `_sm_close_wok_epic`, then line 349 triggers dependents) |

**Verification of dependent trigger order**:

In `mq_process_merge` (lines 326-354):
```bash
# Line 328: sm_transition_to_merged marks epic as done
sm_transition_to_merged "${op}"
# ...
# Line 349-352: Then trigger dependents
for dep_op in $(sm_find_dependents "${op}" 2>/dev/null); do
    mq_resume_waiting_operation "${dep_op}"
done
```

Order is correct for operation merges.

**Conclusion**: Only `mq_process_branch_merge` needs changes (covered in Phase 2).

### Phase 5: Add Unit Tests

**Goal**: Add tests for the new wk start/done integration.

**Files to create/modify**:

1. `packages/state/tests/transitions.bats` - Add tests for `sm_transition_to_executing`:
```bash
@test "sm_transition_to_executing calls wk start on epic" {
    # Setup mock for wk
    function wk() {
        if [[ "$1" == "show" ]]; then
            echo '{"status": "todo"}'
        elif [[ "$1" == "start" ]]; then
            echo "started $2" >> "${MOCK_WK_CALLS}"
        fi
    }
    export -f wk

    # Create operation with epic_id
    create_test_operation "test-op" "queued" "epic_id" "TEST-123"

    # Transition to executing
    sm_transition_to_executing "test-op" "test-session"

    # Verify wk start was called
    grep -q "started TEST-123" "${MOCK_WK_CALLS}"
}
```

2. `packages/mergeq/tests/processing.bats` - Add tests for branch merge wk done:
```bash
@test "mq_process_branch_merge marks issue done before triggering dependents" {
    # Test that wk done is called before mq_trigger_dependents_by_issue
    # Use mock to track call order
}
```

**Verification**:
- Run `scripts/test state mergeq` to verify all tests pass

### Phase 6: Integration Testing

**Goal**: Verify end-to-end behavior.

**Test scenarios**:

1. **Feature workflow**:
   - Run `v0 feature test-feat "Test feature"`
   - Verify epic transitions: todo -> in_progress (on execution) -> done (on merge)

2. **Fix workflow**:
   - Run `v0 fix "Test bug"`
   - Let fix complete and merge
   - Verify bug issue is marked done after merge

3. **Blocked operation workflow**:
   - Create blocker operation, then dependent operation
   - Merge blocker
   - Verify: blocker epic marked done BEFORE dependent is resumed

**Verification**:
- Run `make check` to verify all tests pass

## Key Implementation Details

### Wok Status Transitions

```
todo ──wk start──> in_progress ──wk done──> done
```

- `wk done` requires the issue to be in `in_progress` status
- If issue is in `todo`, must call `wk start` first before `wk done`
- The `_sm_close_wok_epic` function already handles this pattern

### Critical Ordering

The order of operations when a merge completes:

1. Push merge commit to remote ✓
2. Verify merge commit on target branch ✓
3. Update operation state to "merged" phase ✓
4. **Mark wok epic as done** (unblocks dependents in wok)
5. Trigger dependent v0 operations to resume

This order ensures that when dependents check their blockers, the blocker's epic is already marked done.

### Error Handling

- `wk` command failures should log warnings but not fail the overall operation
- Git operations have already succeeded at the point wk is called
- Use `2>/dev/null || true` pattern for non-critical wk calls

## Verification Plan

1. **Unit Tests**: Run `scripts/test state mergeq` - all tests pass
2. **Integration Tests**: Run `scripts/test v0-merge` - existing tests pass
3. **Full Check**: Run `make check` - all lints and tests pass
4. **Manual Verification**:
   - Create a feature with `v0 feature test "Test"`, verify epic starts as "todo"
   - After build starts, verify epic is "in_progress"
   - After merge completes, verify epic is "done"
   - Verify dependent operations resume after blocker merges
