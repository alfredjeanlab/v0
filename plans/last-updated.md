# Implementation Plan: Last-Updated Timestamps in v0 Status

**Root Feature:** `v0-407c`

## Overview

Update the `v0 status` command to display the timestamp of when an operation's state was last updated, rather than when it was created. This provides users with more meaningful timing information—for example, showing when an operation was merged rather than when it was started. Operations will continue to be sorted by creation time to maintain a stable, chronological list.

## Project Structure

Files to modify:
```
bin/v0-status          # Main status display logic - timestamp selection
lib/state-machine.sh   # State machine - ensure timestamps are tracked
```

No new files required.

## Dependencies

None. Uses existing jq, bash, and date utilities already in use.

## Implementation Phases

### Phase 1: Add `get_last_updated_timestamp` Function

Add a new function to `bin/v0-status` that determines the most recent relevant timestamp for an operation based on its current phase.

**Location:** `bin/v0-status` (near `format_operation_time` function, ~line 200)

**Logic:**
```bash
# Get the most relevant timestamp for display based on current state
# Arguments: phase, created_at, completed_at, merged_at, held_at
# Output: The most appropriate timestamp for display
get_last_updated_timestamp() {
  local phase="$1"
  local created_at="$2"
  local completed_at="$3"
  local merged_at="$4"
  local held_at="$5"

  case "$phase" in
    merged)
      # Prefer merged_at, fall back to completed_at, then created_at
      if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
        echo "$merged_at"
      elif [[ -n "$completed_at" && "$completed_at" != "null" ]]; then
        echo "$completed_at"
      else
        echo "$created_at"
      fi
      ;;
    completed|pending_merge)
      # Show when it was completed
      if [[ -n "$completed_at" && "$completed_at" != "null" ]]; then
        echo "$completed_at"
      else
        echo "$created_at"
      fi
      ;;
    held)
      # Show when it was put on hold
      if [[ -n "$held_at" && "$held_at" != "null" ]]; then
        echo "$held_at"
      else
        echo "$created_at"
      fi
      ;;
    *)
      # For init, planned, queued, executing, etc. - use created_at
      echo "$created_at"
      ;;
  esac
}
```

**Verification:** Unit test with various phase/timestamp combinations.

---

### Phase 2: Extract Additional Timestamps in jq Query

Modify the jq query in `list_operations()` to extract `completed_at` and `held_at` timestamps alongside existing fields.

**Location:** `bin/v0-status` (around line 716-731)

**Current query extracts:**
- `created_at` (index 3)
- `merged_at` (index 8)

**Add extraction for:**
- `completed_at` (new field)
- `held_at` (new field)

**Modified jq output fields:**
```bash
jq -rs 'sort_by(.created_at) | .[] | [
  .name,                           # 0
  (.type // "build"),              # 1
  .phase,                          # 2
  .created_at,                     # 3 - for sorting
  (.machine // "unknown"),         # 4
  (.completed | length),           # 5
  (.merge_queued // false),        # 6
  (.merge_status // "null"),       # 7
  (.merged_at // "null"),          # 8
  (.completed_at // "null"),       # 9  - NEW
  (.held_at // "null"),            # 10 - NEW
  ...
] | @tsv'
```

**Verification:** Run `v0 status` and confirm no regressions in display.

---

### Phase 3: Update Display Logic to Use Last-Updated Timestamp

Modify the status display loop to use `get_last_updated_timestamp` instead of raw `created_at`.

**Location:** `bin/v0-status` (around line 745-760, in the while loop processing operations)

**Current code (approximately):**
```bash
display_time=$(format_operation_time "${created}")
```

**Updated code:**
```bash
# Get the most relevant timestamp based on operation phase
last_updated=$(get_last_updated_timestamp "$phase" "$created" "$completed_at" "$merged_at" "$held_at")
display_time=$(format_operation_time "${last_updated}")
```

**Verification:**
- Create a test operation, advance through phases, verify timestamp updates
- Check that `merged` operations show merge time
- Check that `completed` operations show completion time

---

### Phase 4: Integrate Merge Queue Timestamps

When an operation has been merged via the merge queue, prefer the merge queue's `updated_at` timestamp if it's more recent than the state machine's `merged_at`.

**Location:** `bin/v0-status` (in the merge queue status overlay section, ~line 863-900)

**Approach:**
1. When reading merge queue entries, capture `updated_at` for completed entries
2. In the display loop, if operation has `merge_status == "completed"` and merge queue has a timestamp, compare and use the more recent one
3. This handles cases where merge queue tracking is more accurate than state file updates

**Implementation detail:**
```bash
# Build associative array of merge queue completion times
declare -A merge_queue_times
while IFS=$'\t' read -r op_name mq_status mq_updated; do
  if [[ "$mq_status" == "completed" && -n "$mq_updated" && "$mq_updated" != "null" ]]; then
    merge_queue_times["$op_name"]="$mq_updated"
  fi
done < <(jq -r '.entries[] | [.operation, .status, (.updated_at // "null")] | @tsv' "$mergeq_queue_file")

# In display loop, check for merge queue override
if [[ -n "${merge_queue_times[$name]:-}" ]]; then
  mq_time="${merge_queue_times[$name]}"
  # Use merge queue time if available and merged
  if [[ "$phase" == "merged" ]]; then
    last_updated="$mq_time"
  fi
fi
```

**Verification:** Merge an operation through the queue, verify timestamp reflects merge completion time.

---

### Phase 5: Add Unit Tests

Create tests in `tests/unit/v0-status.bats` for the new timestamp logic.

**Test cases:**
1. `get_last_updated_timestamp` returns `merged_at` for merged phase
2. `get_last_updated_timestamp` returns `completed_at` for completed phase
3. `get_last_updated_timestamp` returns `held_at` for held phase
4. `get_last_updated_timestamp` falls back to `created_at` when specific timestamps are null
5. `get_last_updated_timestamp` returns `created_at` for init/planned/queued/executing phases
6. Integration: operations still sort by `created_at`

**Verification:** `make test` passes with new tests.

---

### Phase 6: Documentation and Edge Cases

1. Update any relevant documentation or comments
2. Handle edge cases:
   - Operations migrated from older schema without new timestamp fields
   - Null or missing timestamp fields (already handled by `// "null"` in jq)
   - Timestamps that parse incorrectly

**Verification:** Test with legacy state files if available; manual verification of edge cases.

## Key Implementation Details

### Timestamp Priority Order

For each phase, timestamps are checked in this priority order:

| Phase | Priority 1 | Priority 2 | Fallback |
|-------|------------|------------|----------|
| `merged` | `merged_at` | `completed_at` | `created_at` |
| `completed` | `completed_at` | — | `created_at` |
| `pending_merge` | `completed_at` | — | `created_at` |
| `held` | `held_at` | — | `created_at` |
| `init`, `planned`, `queued`, `executing` | — | — | `created_at` |

### Sorting Remains Unchanged

The jq query continues to use `sort_by(.created_at)` to maintain stable, chronological ordering. This ensures:
- New operations appear at the bottom of the list
- Operation order doesn't jump around as state changes
- Users can track operations by their original creation order

### Existing Timestamp Fields

From `lib/state-machine.sh`, these timestamps are already tracked:
- `created_at` (line 221 in init) — set once at creation
- `completed_at` (line 473 in `sm_transition_to_completed`)
- `merged_at` (line 504 in `sm_transition_to_merged`)
- `held_at` (line 761 in `sm_set_hold`)
- `worker_started_at` (various locations)

No changes to the state machine are required; all necessary timestamps are already being recorded.

## Verification Plan

1. **Unit tests:** Run `make test` — all existing and new tests pass
2. **Lint:** Run `make lint` — no shellcheck warnings
3. **Manual testing scenarios:**
   - Create new operation → shows creation time
   - Complete operation → shows completion time
   - Merge operation → shows merge time
   - Put operation on hold → shows hold time
   - Verify list order remains stable (sorted by creation)
4. **Regression testing:**
   - Existing operations with missing timestamps display correctly
   - No format changes to other status output
