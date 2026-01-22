# Limit Operations in v0 Status List

## Overview

Limit the `v0 status` operations list to 15 entries with intelligent pruning. When more than 15 operations exist, prioritize "open" operations (actively working, new, failed) over "blocked" and "completed" operations. This optimization avoids expensive per-operation checks (tmux sessions, worker PIDs) for operations that won't be displayed.

## Project Structure

```
bin/v0-status           # Main file to modify (lines 779-988)
lib/v0-common.sh        # Optional: add V0_STATUS_LIMIT config var
tests/unit/v0-status.bats  # Add tests for limit behavior
```

## Dependencies

- jq (existing) - for filtering and sorting operations
- No new dependencies required

## Implementation Phases

### Phase 1: Add Operation Priority Classification in jq

**Goal**: Classify operations by priority in the jq filter so pruning decisions are data-driven.

**Priority Categories** (in order of display preference):
1. **open**: Actively workable - `init`, `planned`, `queued`, `executing`, `failed`, `conflict`, `interrupted`
2. **blocked**: Waiting on dependencies - `blocked` phase OR has non-null `after` field with incomplete parent
3. **completed**: Done - `completed`, `pending_merge`, `merged`, `cancelled`

**Implementation**: Modify the jq filter at line 951 to add a priority field:

```jq
# Priority classification for pruning
def priority_class:
  if .phase == "completed" or .phase == "pending_merge" or .phase == "merged" or .phase == "cancelled"
  then 2  # completed
  elif .after != null and .after != "null" and .phase != "executing"
  then 1  # blocked (has unmet dependency)
  else 0  # open (highest priority)
  end;
```

**Output change**: Add priority value to TSV output for use in Phase 2.

**Verification**: Run `v0 status --json` equivalent to verify priority classification is correct.

---

### Phase 2: Implement Limit and Pruning Logic in jq

**Goal**: Select up to 15 operations using priority-aware pruning, maintaining created_at order within each priority class.

**Pruning Algorithm**:
1. Sort all operations by `created_at` ASC (existing behavior)
2. Group by priority class (0=open, 1=blocked, 2=completed)
3. Fill slots: open first (up to 15), then blocked, then completed
4. Return selected operations + counts of pruned operations by category

**Implementation**: Wrap the jq filter to perform selection:

```jq
# In the jq -rs block:
. as $all |
($all | length) as $total |

# Calculate priority for each op
[$all[] | . + {priority: priority_class}] |

# Separate by priority
(map(select(.priority == 0))) as $open |
(map(select(.priority == 1))) as $blocked |
(map(select(.priority == 2))) as $completed |

# Build selection (open first, then blocked, then completed) up to limit
($open | sort_by(.created_at)) as $sorted_open |
($blocked | sort_by(.created_at)) as $sorted_blocked |
($completed | sort_by(.created_at)) as $sorted_completed |

15 as $limit |
([$sorted_open[], $sorted_blocked[], $sorted_completed[]] | .[:$limit]) as $selected |

# Output META line with max_name_len and pruning stats
{
  max_name_len: (reduce $selected[] as $op (0; [., ([($op.name | length) + 1, 40] | min)] | max)),
  pruned_open: (($open | length) - ([$selected[] | select(.priority == 0)] | length)),
  pruned_blocked: (($blocked | length) - ([$selected[] | select(.priority == 1)] | length)),
  pruned_completed: (($completed | length) - ([$selected[] | select(.priority == 2)] | length)),
  total: $total
} | "META\t\(.max_name_len)\t\(.pruned_open)\t\(.pruned_blocked)\t\(.pruned_completed)\t\(.total)",

# Then output selected operations in created_at order
($selected | sort_by(.created_at) | .[] | [...existing fields...] | @tsv)
```

**META line change**: Expand to include pruning statistics:
- `META\t<max_name_len>\t<pruned_open>\t<pruned_blocked>\t<pruned_completed>\t<total>`

**Verification**: Create 20+ test operations with mixed statuses, verify only 15 display with correct priority.

---

### Phase 3: Display Summary Line for Pruned Operations

**Goal**: When operations are pruned, show a summary line indicating what was hidden.

**Display format** (after operation list):

```
  ... and 85 more (5 blocked, 80 completed)
```

Or if only completed are pruned:
```
  ... and 80 more completed
```

**Implementation**: After the while-read loop, check pruned counts from META line:

```bash
# After the while-read loop (around line 989)
if [[ ${total_ops} -gt 15 ]]; then
  pruned=$((total_ops - 15))
  summary_parts=()
  [[ ${pruned_blocked} -gt 0 ]] && summary_parts+=("${pruned_blocked} blocked")
  [[ ${pruned_completed} -gt 0 ]] && summary_parts+=("${pruned_completed} completed")

  if [[ ${#summary_parts[@]} -eq 0 ]]; then
    echo -e "  ${C_DIM}... and ${pruned} more${C_RESET}"
  elif [[ ${#summary_parts[@]} -eq 1 ]] && [[ ${pruned_open} -eq 0 ]]; then
    # Only one category pruned and no open pruned - simpler message
    echo -e "  ${C_DIM}... and ${pruned} more ${summary_parts[0]%% *}${C_RESET}"
  else
    summary=$(IFS=', '; echo "${summary_parts[*]}")
    echo -e "  ${C_DIM}... and ${pruned} more (${summary})${C_RESET}"
  fi
fi
```

**Verification**: Visually confirm summary line appears correctly with various operation mixes.

---

### Phase 4: Make Limit Configurable

**Goal**: Allow users to override the default limit via environment variable.

**Implementation**:

1. Add to `lib/v0-common.sh`:
```bash
# Maximum operations to show in v0 status list (default: 15)
V0_STATUS_LIMIT="${V0_STATUS_LIMIT:-15}"
```

2. Update jq filter to use variable:
```bash
# Pass limit as jq argument
--argjson limit "${V0_STATUS_LIMIT}"
```

3. Document in help text (optional):
```
V0_STATUS_LIMIT=30 v0 status   # Show more operations
```

**Verification**: Test with `V0_STATUS_LIMIT=5 v0 status` and `V0_STATUS_LIMIT=100 v0 status`.

---

### Phase 5: Add Unit Tests

**Goal**: Ensure limit behavior is correct and doesn't regress.

**Test cases** (add to `tests/unit/v0-status.bats`):

```bash
@test "status list limits to 15 operations by default" {
  # Create 20 operations with various phases
  # Verify output has exactly 15 operation lines + summary
}

@test "status list prioritizes open operations over blocked" {
  # Create 10 completed, 10 blocked, 5 open
  # Verify all 5 open appear in output
}

@test "status list prioritizes blocked over completed" {
  # Create 20 completed, 5 blocked
  # Verify all 5 blocked appear before completed
}

@test "status list shows summary for pruned operations" {
  # Create 20 operations
  # Verify "... and X more" line appears
}

@test "status list respects V0_STATUS_LIMIT env var" {
  # Create 10 operations
  # Run with V0_STATUS_LIMIT=5
  # Verify only 5 operations shown
}

@test "status list shows all operations when under limit" {
  # Create 10 operations
  # Verify all 10 shown, no summary line
}
```

**Verification**: `make test-file FILE=tests/unit/v0-status.bats`

---

## Key Implementation Details

### Priority Classification Edge Cases

- **blocked phase**: Always priority 1, regardless of `after` field
- **executing with after**: Priority 0 (open) - already past the blocking point
- **init/planned with after**: Priority 1 (blocked) - still waiting
- **failed**: Priority 0 (open) - needs attention

### Performance Impact

The pruning happens in jq (single subprocess), so operations beyond the limit never trigger:
- tmux session checks (line 835)
- worker PID checks via `kill -0` (line 840)
- Queue status lookups (line 868)
- Phase display formatting (line 873)

This is the primary performance win: O(N) expensive checks become O(15) checks.

### Backward Compatibility

- Default behavior changes (shows 15 instead of all)
- Users can restore full list with `V0_STATUS_LIMIT=0` or `V0_STATUS_LIMIT=999`
- `v0 status --json` should remain unaffected (shows all operations)

### Display Order Preservation

Within the 15 selected operations, maintain `created_at` ASC ordering. The priority classification only affects *which* operations are selected, not their display order.

---

## Verification Plan

1. **Unit tests**:
   ```bash
   make test-file FILE=tests/unit/v0-status.bats
   ```

2. **Manual testing with many operations**:
   ```bash
   # Use existing test environment or create test operations
   v0 status
   # Should show 15 ops + summary line
   ```

3. **Performance verification**:
   ```bash
   time v0 status
   # Should be faster with large operation counts
   ```

4. **Edge cases**:
   - 0 operations (no change)
   - 1-15 operations (no pruning, no summary)
   - Exactly 15 operations (no pruning, no summary)
   - 16+ operations (pruning active, summary shown)
   - All same priority (oldest 15 shown)
   - Mixed priorities (verify priority order)

5. **Linting**:
   ```bash
   make lint
   ```
