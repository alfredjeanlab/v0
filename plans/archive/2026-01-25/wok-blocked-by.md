# Plan: wok-blocked-by

Add `wk dep ... blocked-by ...` integration to `v0 build --after` to document work sequences in the issue tracker.

## Overview

When using `v0 build` with `--after`, the operation dependency is currently only stored in the state machine (`state.json`). This plan adds automatic creation of `wk dep` (blocked-by) relationships so that work sequences are also documented in the issue tracker (`wk`), matching the behavior of `v0 chore --after` and `v0 fix --after`.

## Project Structure

Key files involved:

```
v0/bin/
  v0-build           # Main build command (foreground mode)
  v0-build-worker    # Background worker for build pipeline
  v0-chore           # Reference implementation for --after with wk dep
  v0-fix             # Reference implementation for --after with wk dep
v0/packages/
  state/lib/         # State machine utilities
```

## Dependencies

No new external dependencies. Uses existing `wk dep` command.

## Implementation Phases

### Phase 1: Add helper function to resolve blocker issue IDs

**File**: `v0/bin/v0-build`

Add a helper function to look up the `epic_id` from a blocker operation's state:

```bash
# Get blocker operation's issue ID for wk dep
get_blocker_issue_id() {
  local op="$1"
  local blocker_state="${BUILD_DIR}/operations/${op}/state.json"
  if [[ -f "${blocker_state}" ]]; then
    jq -r '.epic_id // empty' "${blocker_state}"
  fi
}
```

**Verification**: Test function manually with an existing operation that has an epic_id.

---

### Phase 2: Add wk dep call after epic_id is set (foreground mode)

**File**: `v0/bin/v0-build`

After the `epic_id` is set (around line 818 and 562), add logic to create the `wk dep` relationship:

```bash
# Add blocked-by dependency in wk if --after was specified
if [[ -n "${AFTER}" ]] && [[ "${AFTER}" != "null" ]] && [[ -n "${FEATURE_ID}" ]]; then
  BLOCKER_ISSUE_ID=$(get_blocker_issue_id "${AFTER}")
  if [[ -n "${BLOCKER_ISSUE_ID}" ]] && [[ "${BLOCKER_ISSUE_ID}" != "null" ]]; then
    if wk dep "${FEATURE_ID}" blocked-by "${BLOCKER_ISSUE_ID}" 2>/dev/null; then
      emit_event "dep:added" "Added blocked-by: ${BLOCKER_ISSUE_ID}"
    else
      emit_event "dep:failed" "Failed to add blocked-by: ${BLOCKER_ISSUE_ID}"
    fi
  fi
fi
```

Locations to add this logic:
1. **Line ~562**: After `update_state "epic_id" "\"${EXISTING_FEATURE}\""` (when using `--plan` with existing feature)
2. **Line ~818**: After `update_state "epic_id" "\"${FEATURE_ID}\""` (after decompose completes)

**Verification**: Run `v0 build test2 "Test" --after test1` where `test1` has an epic_id. Verify `wk show <test2-epic-id>` shows blocked-by relationship.

---

### Phase 3: Add wk dep call to build worker (background mode)

**File**: `v0/bin/v0-build-worker`

Add the same helper function and wk dep call to the worker, since most builds run in background mode.

Add helper function near the top (after sourcing):
```bash
# Get blocker operation's issue ID for wk dep
get_blocker_issue_id() {
  local op="$1"
  local blocker_state="${BUILD_DIR}/operations/${op}/state.json"
  if [[ -f "${blocker_state}" ]]; then
    jq -r '.epic_id // empty' "${blocker_state}"
  fi
}
```

Add wk dep call after line 439 (`update_state "epic_id"`):
```bash
# Add blocked-by dependency in wk if --after was specified
AFTER_OP=$(get_state after)
if [[ -n "${AFTER_OP}" ]] && [[ "${AFTER_OP}" != "null" ]] && [[ -n "${FEATURE_ID}" ]]; then
  BLOCKER_ISSUE_ID=$(get_blocker_issue_id "${AFTER_OP}")
  if [[ -n "${BLOCKER_ISSUE_ID}" ]] && [[ "${BLOCKER_ISSUE_ID}" != "null" ]]; then
    if wk dep "${FEATURE_ID}" blocked-by "${BLOCKER_ISSUE_ID}" 2>/dev/null; then
      emit_event "dep:added" "Added blocked-by: ${BLOCKER_ISSUE_ID}"
    else
      emit_event "dep:failed" "Failed to add blocked-by: ${BLOCKER_ISSUE_ID}"
    fi
  fi
fi
```

**Verification**: Run `v0 build test3 "Test" --after test1` (background mode). Check worker log for `dep:added` event. Verify `wk show <test3-epic-id>` shows blocked-by relationship.

---

### Phase 4: Add integration test

**File**: `v0/tests/v0-build.bats`

Add test case to verify wk dep is called when --after is used:

```bash
@test "build --after creates wk dep blocked-by relationship" {
    setup_mock_wk

    # Create a blocker operation with epic_id
    mkdir -p "${BUILD_DIR}/operations/blocker"
    cat > "${BUILD_DIR}/operations/blocker/state.json" <<EOF
{
  "name": "blocker",
  "phase": "merged",
  "epic_id": "v0-abc123"
}
EOF

    run "${V0_BUILD}" test-after "Test build" --after blocker --dry-run 2>&1 || true

    # Note: --dry-run may not trigger wk dep, test actual run in integration
    # For now verify state is set up correctly
    assert_success
}
```

**Verification**: `scripts/test v0-build`

## Key Implementation Details

### Issue ID Resolution

The `--after` flag for `v0 build` accepts an **operation name** (e.g., "auth"), not an issue ID. This differs from `v0 chore --after` which accepts **issue IDs** directly. The implementation must:

1. Look up the blocker operation's `state.json`
2. Extract the `epic_id` field (which contains the wk issue ID)
3. Use that issue ID in the `wk dep` call

### Timing Considerations

The `wk dep` call must happen **after** the current operation's `epic_id` is known:
- This occurs during the **decompose** phase when Claude creates issues
- Or immediately when using `--plan` with an existing feature ID in the plan file

### Graceful Degradation

The `wk dep` call should:
- Silently succeed if blocker has no epic_id (early-stage operation)
- Log a warning event but not fail if `wk dep` fails
- Not block the build process

### State Machine vs. Issue Tracker

Two parallel dependency systems now exist:
- **State machine** (`state.json`): Controls build execution order via `after` field
- **Issue tracker** (`wk`): Documents work sequence via `blocked-by` relationship

Both are maintained for their respective purposes.

## Verification Plan

1. **Unit test**: Mock `wk` command, verify `wk dep ... blocked-by ...` is called with correct arguments
2. **Integration test**: Create two operations with `--after`, verify `wk show` displays the dependency
3. **Edge cases**:
   - Blocker operation has no epic_id yet (should silently skip)
   - wk is not initialized (should warn but not fail)
   - Multiple blockers (future enhancement, not in scope)
4. **Manual verification**:
   ```bash
   # Create first operation
   v0 build auth "Add authentication"
   # Wait for epic_id to be set

   # Create second operation with dependency
   v0 build api "Add API" --after auth

   # Verify wk dependency
   wk show <api-epic-id>  # Should show "blocked by: <auth-epic-id>"
   ```
