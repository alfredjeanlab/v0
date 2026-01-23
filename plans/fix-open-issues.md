# Fix Open Issues After Feature Workflow

**Root Feature:** `v0-864c`

## Overview

After the `v0 feature` workflow completes, issues remain unclosed almost without exception. This plan identifies the root cause and fixes it by simplifying the issue-closing architecture.

## Root Cause Analysis

### Current Architecture (Overly Complex)

Issues can be closed in **three places**, leading to confusion about responsibility:

1. **`./done` script** (lines 303-332 of `bin/v0-feature`): Closes issues before killing Claude
2. **Stop hook** (`lib/hooks/stop-feature.sh`): Blocks exit if issues remain open
3. **`on-complete.sh`** (lines 1144-1172): Runs after Claude exits, only records done issues

### Why Issues Leak

The problem occurs when Claude exits WITHOUT calling `./done`:

1. Claude tries to stop (out of context, natural exit, etc.)
2. Stop hook fires, sees open issues, blocks
3. Claude is instructed to continue (with `stop_hook_active=true`)
4. Claude tries to stop again
5. Stop hook sees `stop_hook_active=true`, **approves immediately** (infinite loop prevention)
6. Claude exits with issues still open
7. `on-complete.sh` runs but **only records done issues** - it doesn't close open ones

The `stop_hook_active` bypass is necessary to prevent infinite loops, but it creates a path where issues leak.

### Additional Bypass Paths

The stop hook also approves immediately for:
- Auth/credential failures
- Credit/billing issues
- Payment issues

In all these cases, issues remain open.

## Project Structure

```
bin/v0-feature           # Main feature workflow script
  - create_done_script() # Lines 270-335: Creates ./done script
  - on-complete.sh       # Lines 1144-1172: Post-exit handler

lib/hooks/
  stop-feature.sh        # Stop hook - blocks exit if issues open

tests/unit/
  stop-feature-hook.bats # New: Tests for stop-feature.sh
  v0-feature-state.bats  # Extend: Test on-complete issue closing
```

## Dependencies

None - uses existing `wk` commands and shell utilities.

## Implementation Phases

### Phase 1: Add Safety Net to `on-complete.sh`

**Goal**: Ensure issues are always closed, regardless of how Claude exits.

**Changes**:
- Modify `on-complete.sh` template in `bin/v0-feature` (lines 1144-1172)
- Add issue closing logic BEFORE collecting done issues

**Code snippet**:
```bash
# on-complete.sh - add BEFORE existing logic:

# Close any remaining open issues (safety net)
OPEN_IDS=\$(wk list --label "plan:\${OP_NAME}" --status todo 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+' || true)
IN_PROGRESS_IDS=\$(wk list --label "plan:\${OP_NAME}" --status in_progress 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+' || true)
ALL_IDS="\${OPEN_IDS} \${IN_PROGRESS_IDS}"
ALL_IDS=\$(echo "\${ALL_IDS}" | xargs)  # Trim whitespace
if [[ -n "\${ALL_IDS}" ]]; then
  echo "Closing remaining issues: \${ALL_IDS}"
  wk done \${ALL_IDS} --reason "Auto-closed by on-complete handler" 2>/dev/null || true
fi

# Then existing logic to collect done issues...
```

**Verification**:
- Issues are closed even when `./done` is not called
- Works with `stop_hook_active=true` bypass
- Works with auth/credit/billing bypass

### Phase 2: Simplify `./done` Script

**Goal**: Remove redundant issue-closing logic from `./done` since `on-complete.sh` handles it.

**Changes**:
- Modify `create_done_script()` in `bin/v0-feature` (lines 270-335)
- Remove issue-closing logic, keep only Claude termination

**Simplified `./done` script**:
```bash
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
```

**Verification**:
- `./done` still terminates Claude
- Issue closing is handled by `on-complete.sh`

### Phase 3: Make Stop Hook Informational

**Goal**: Stop hook should warn about open issues but not block (since on-complete handles cleanup).

**Changes**:
- Modify `lib/hooks/stop-feature.sh`
- Change from blocking to warning (approve with message)

**Alternative**: Keep blocking behavior but ensure it's clear that `on-complete.sh` is the authoritative closer. The stop hook serves as a "are you sure?" prompt.

**Decision**: Keep blocking for now - it prompts Claude to complete work before exiting. The safety net in `on-complete.sh` handles cases where Claude can't continue.

### Phase 4: Add Tests

**Goal**: Verify the fix works and prevent regression.

**New test file**: `tests/unit/stop-feature-hook.bats`

```bash
@test "stop-feature hook approves when no open issues" {
    # Mock wk to return no open issues
    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}

@test "stop-feature hook blocks when issues are open" {
    # Mock wk to return open issues
    run bash -c 'echo "{}" | "$HOOK_SCRIPT"'
    assert_output --partial '"decision": "block"'
}

@test "stop-feature hook approves with stop_hook_active=true" {
    run bash -c 'echo "{\"stop_hook_active\": true}" | "$HOOK_SCRIPT"'
    assert_success
    assert_output '{"decision": "approve"}'
}
```

**Extend**: `tests/unit/v0-feature-state.bats`

```bash
@test "on-complete closes remaining issues before recording" {
    # Test that on-complete.sh closes open issues
}
```

### Phase 5: Update Documentation

**Goal**: Document the simplified architecture.

**Changes**:
- Update `docs/debug/recovery.md` if needed
- Update `docs/arch/operations/state.md` if needed
- Remove references to `./done` closing issues (now handled by `on-complete.sh`)

## Key Implementation Details

### Issue ID Pattern

The current pattern `[a-zA-Z]+-[a-z0-9]+` is hardcoded in multiple places. Consider using `v0_issue_pattern()` consistently, but this is out of scope for this fix.

### Error Handling

All `wk` commands use `|| true` to prevent failures from breaking the workflow. This is intentional - better to complete the workflow with some issues open than to crash.

### Race Conditions

There's a potential race between Claude closing issues and `on-complete.sh` running, but this is benign - closing an already-closed issue is a no-op.

### Environment Variables

`on-complete.sh` uses `OP_NAME` which is set at script creation time (not runtime), so it works correctly.

## Verification Plan

### Unit Tests

1. Run `make test-file FILE=tests/unit/stop-feature-hook.bats` (new)
2. Run `make test-file FILE=tests/unit/v0-feature-state.bats` (extended)

### Manual Testing

1. Start a feature with issues: `v0 feature test-fix`
2. In the Claude session, do NOT call `./done` - just let it exit naturally
3. Verify issues are closed after session ends
4. Check `wk list --label plan:test-fix` shows no open issues

### Edge Cases

1. **Auth failure exit**: Issues should still be closed by `on-complete.sh`
2. **Out of context exit**: Issues should still be closed by `on-complete.sh`
3. **`./done` called**: Issues closed by `./done`, `on-complete.sh` is a no-op
4. **`./incomplete` called**: Issues NOT closed (by design - preserves state)

## Summary

The fix consolidates issue-closing responsibility into `on-complete.sh`, which runs reliably after every Claude exit. This:

1. **Simplifies** the architecture by having one authoritative place for issue closing
2. **Fixes** the leak where `stop_hook_active=true` bypasses issue closing
3. **Is testable** with unit tests for the hook and integration tests for the flow
4. **Maintains** the `./incomplete` escape hatch for preserving issue state when needed
