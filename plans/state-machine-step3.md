# State Machine Integration - Step 3: v0-status Migration

**Root Feature:** `v0-8096` (follows state-machine-step2.md)

## Overview

Complete the v0-status migration that was missed in step2. The state machine library has the necessary functions (`sm_get_display_status`, `sm_is_active_operation`, `sm_get_status_color`) but v0-status still uses 39 inline jq calls.

**Current State:**
- `lib/state-machine.sh` has: `sm_get_display_status()`, `sm_get_status_color()`, `sm_is_active_operation()`, `sm_get_merge_display_status()`
- `bin/v0-status` has: 39 inline `jq` calls, 0 `sm_*` calls
- Complex phase display logic duplicated in both list view and single-operation view

## Files to Modify

```
bin/v0-status              # MODIFY: Replace inline jq with sm_* calls
tests/unit/v0-status.bats  # MODIFY: Update tests for state machine usage
```

## Implementation

### Phase 1: Single-Operation View (`show_status` function)

The `show_status()` function (lines 791-1048) reads state with 20+ separate jq calls on the same state object.

**Current pattern:**
```bash
local state
state=$(cat "${STATE_FILE}")
local phase
phase=$(echo "${state}" | jq -r '.phase')
local feature_id
feature_id=$(echo "${state}" | jq -r '.epic_id // empty')
# ... 20 more similar calls
```

**Target pattern using batch reads:**
```bash
# Single jq call instead of 20+
IFS=$'\t' read -r phase op_type feature_id machine session current_issue \
  completed last_activity merge_queued merge_status merged_at after eager \
  worker_pid worker_log worker_started_at error_msg held held_at worktree <<< \
  "$(sm_read_state_fields "${NAME}" phase type epic_id machine tmux_session \
     current_issue completed last_activity merge_queued merge_status merged_at \
     after eager worker_pid worker_log worker_started_at error held held_at worktree)"

# Handle defaults
[[ -z "${op_type}" ]] && op_type="build"
[[ -z "${machine}" ]] && machine="unknown"
```

**Replace inline phase checks with state machine:**
```bash
# Before (line 785-789)
STATE_FILE="${BUILD_DIR}/operations/${NAME}/state.json"
if [[ ! -f "${STATE_FILE}" ]]; then

# After
if ! sm_state_exists "${NAME}"; then
```

**Replace after-operation status check (line 925-932):**
```bash
# Before
local after_state_file="${BUILD_DIR}/operations/${after}/state.json"
if [[ -f "${after_state_file}" ]]; then
  local after_phase
  after_phase=$(jq -r '.phase' "${after_state_file}")

# After
local after_phase
after_phase=$(sm_get_phase "${after}")
```

### Phase 2: List View Optimization

The list view (lines 509-683) already uses a batched jq -s approach which is efficient. However, it duplicates the phase display logic from `sm_get_display_status`.

**Option A: Use sm_get_display_status per operation**
- Simpler code, uses existing functions
- Trade-off: More jq subprocess spawns (one per operation)

**Option B: Keep batch jq, extract display logic to shared function**
- Best performance for large operation counts
- Move phase-to-display-status logic to helper function used by both

**Recommendation: Option B** - The batch approach is intentional for performance. Instead, extract the display logic into a helper that both v0-status and sm_get_display_status can share.

**Changes:**

1. Extract display logic to `_sm_format_phase_display()` in state-machine.sh:
```bash
# _sm_format_phase_display <phase> <merge_status> <merge_queued> <held> <session> <op_type>
# Format phase for display (shared logic for v0-status and sm_get_display_status)
# Returns: display_phase|color|icon
_sm_format_phase_display() {
  local phase="$1" merge_status="$2" merge_queued="$3" held="$4" session="$5" op_type="$6"
  # ... phase display logic from v0-status lines 571-656
}
```

2. Update `sm_get_display_status` to use the shared helper

3. In v0-status list view, call the helper with batch-read values:
```bash
# After batch read
IFS='|' read -r display_phase color icon <<< \
  "$(_sm_format_phase_display "${phase}" "${merge_status}" "${merge_queued}" "${held}" "${session}" "${op_type}")"
```

### Phase 3: Filter Functions

**Replace active operation check:**
```bash
# Add --active flag to filter (future enhancement)
# For now, use sm_is_active_operation in show logic

# In list filtering:
if [[ -n "${ACTIVE_ONLY}" ]]; then
  sm_is_active_operation "${name}" || continue
fi
```

**Replace blocked check with sm_is_blocked:**
```bash
# Before (line 537-541)
if [[ -n "${BLOCKED}" ]]; then
  if [[ -z "${after}" ]] || [[ "${after}" = "null" ]]; then
    continue
  fi
fi

# After
if [[ -n "${BLOCKED}" ]]; then
  sm_is_blocked "${name}" || continue
fi
```

### Phase 4: Hold Status Display

**Use sm_is_held:**
```bash
# Before (line 567)
if [[ "${held}" = "true" ]]; then

# After (if not using batch read)
if sm_is_held "${name}"; then
```

## Verification

- [ ] `v0 status` output matches previous format exactly
- [ ] `v0 status <name>` shows same detailed information
- [ ] `v0 status --blocked` filters correctly
- [ ] Colors are consistent with previous output
- [ ] `v0 status --json` still works
- [ ] `v0 status --watch` still works
- [ ] No remaining inline `jq '.phase'` or `jq '.held'` etc. in v0-status (queue.json access is OK)
- [ ] Performance: `v0 status` with 20 operations completes in <500ms
- [ ] `make test-file FILE=tests/unit/v0-status.bats` passes
- [ ] `make lint` passes

## Testing

Add/update tests in `tests/unit/v0-status.bats`:

```bash
@test "v0-status uses sm_state_exists for operation lookup" {
  # Verify no direct file checks for state.json
  run grep -c "\\-f.*state.json" bin/v0-status
  assert_output "0"
}

@test "v0-status uses sm_read_state_fields for batch reads" {
  # Verify batch read usage in show_status
  run grep -c "sm_read_state_fields" bin/v0-status
  # Should have at least 1 batch read call
  [[ "${output}" -ge 1 ]]
}
```

## Notes

- The merge queue file (`queue.json`) access can remain as direct jq - it's not part of operation state
- `wk list` calls for issue counts are not part of state machine scope
- Worker status helpers (`show_bugs_indented`, etc.) don't use operation state

## Risk Assessment

**Low risk:**
- Pure refactoring - no behavior changes
- State machine functions are already tested
- Easy rollback (single file change)
