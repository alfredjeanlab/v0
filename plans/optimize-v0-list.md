# Optimize v0 Status List View

**Root Feature:** `v0-bf24`

## Overview

Optimize the `v0 status` list view performance for large operation counts (~200 operations). The current implementation spawns hundreds of subprocess calls (date, grep) in the display loop, causing noticeable latency. This plan eliminates per-operation subprocess spawning by moving timestamp calculations into jq and using awk for batch formatting.

## Project Structure

```
bin/v0-status           # Main file to modify (lines 163-214, 688-858)
lib/v0-common.sh        # May need new helper functions
tests/unit/v0-status.bats  # Existing tests to verify
```

## Dependencies

- jq (existing) - for batch timestamp extraction
- awk (existing) - for batch elapsed time formatting
- bash (existing) - no version changes needed

## Implementation Phases

### Phase 1: Cache Current Timestamp

**Problem**: `format_operation_time` calls `date +%s` for every operation (line 203), spawning N date processes.

**Current** (lines 192-214):
```bash
format_operation_time() {
  local ts="$1"
  ts_epoch=$(timestamp_to_epoch "${ts}")
  now_epoch=$(date +%s)  # Called N times!
  elapsed=$((now_epoch - ts_epoch))
  ...
}
```

**Solution**: Cache `now_epoch` once before the display loop.

**Implementation**:
```bash
# Before line 698 (start of operation processing loop)
now_epoch=$(date +%s)

# Update format_operation_time to accept optional cached now_epoch
format_operation_time() {
  local ts="$1"
  local now_epoch="${2:-$(date +%s)}"  # Use cached if provided
  ...
}

# Line 830: Pass cached value
display_time=$(format_operation_time "${last_updated}" "${now_epoch}")
```

**Savings**: Reduces N `date +%s` calls to 1.

**Verification**: `time v0 status` should show improvement; unit tests pass.

---

### Phase 2: Move Epoch Conversion into jq

**Problem**: `timestamp_to_epoch` spawns a `date -j` process for each operation. With N operations, that's N subprocess spawns.

**Current** (line 830):
```bash
display_time=$(format_operation_time "${last_updated}" "${now_epoch}")
# Where format_operation_time calls timestamp_to_epoch which spawns date
```

**Solution**: Extract timestamps as epoch seconds directly in the jq filter, eliminating per-operation date process spawning.

**Implementation**: Update the jq filter at lines 832-858 to output epoch timestamps:

```bash
# Add epoch conversion in jq filter (using jq's built-in date parsing)
# Note: jq's strptime requires timezone-aware handling for UTC timestamps
(sort_by(.created_at) | .[] | [
  .name,
  # ... existing fields ...
  # Add epoch for relevant timestamps (created_at, completed_at, merged_at, held_at)
  ((.created_at // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime),
  ((.completed_at // "") | if . == "" or . == "null" then 0 else (sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) end),
  ((.merged_at // "") | if . == "" or . == "null" then 0 else (sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) end),
  ((.held_at // "") | if . == "" or . == "null" then 0 else (sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) end)
] | @tsv)
```

**Alternative** (simpler, if jq strptime is problematic): Use awk to batch-convert timestamps after jq output:

```bash
# jq outputs raw timestamps, awk converts in single process
done < <(jq -rs '...' "${state_files[@]}" | awk -F'\t' -v now="${now_epoch}" '
  function ts_to_epoch(ts) {
    # Parse YYYY-MM-DDTHH:MM:SSZ format
    gsub(/T/, " ", ts); gsub(/Z$/, "", ts); gsub(/\.[0-9]+/, "", ts)
    return mktime(gensub(/-/, " ", "g", ts))
  }
  ...
')
```

**Savings**: Reduces N `date -j` calls to 0 (handled in jq/awk).

**Verification**: Compare output before/after; all timestamp displays should match.

---

### Phase 3: Move Elapsed Time Formatting to awk

**Problem**: `format_elapsed` is a shell function called for each operation. While not spawning subprocesses itself, the shell function call overhead adds up with N operations.

**Solution**: Move the entire display formatting into a single awk process that handles:
1. Timestamp selection (get_last_updated_timestamp logic)
2. Elapsed time calculation
3. Human-readable formatting ("5 min ago", "2 hr ago", etc.)

**Implementation**: Replace the while-read loop with awk-based processing:

```bash
# Cache queue data for awk access
queue_data=$(cat "${queue_cache}" 2>/dev/null || true)

# Single awk process handles all formatting
jq -rs '
  # ... existing jq filter outputting TSV ...
' "${state_files[@]}" | awk -F'\t' -v now="${now_epoch}" -v queue="${queue_data}" '
  BEGIN {
    # Parse queue data into associative arrays
    n = split(queue, lines, "\n")
    for (i = 1; i <= n; i++) {
      split(lines[i], parts, "\t")
      queue_status[parts[1]] = parts[2]
      queue_updated[parts[1]] = parts[3]
    }
  }

  function format_elapsed(seconds) {
    if (seconds < 60) return "just now"
    if (seconds < 3600) return int(seconds / 60) " min ago"
    if (seconds < 86400) return int(seconds / 3600) " hr ago"
    return int(seconds / 86400) " day ago"
  }

  function format_time(epoch) {
    elapsed = now - epoch
    if (elapsed < 43200) return format_elapsed(elapsed)
    return strftime("%Y-%m-%d", epoch)
  }

  # Main processing
  NR == 1 && $1 == "META" { max_name_len = $2; next }
  {
    name = $1
    # ... extract fields ...
    # Select timestamp based on phase
    # Format and print
  }
'
```

**Savings**: Reduces shell function call overhead; all display logic in single awk process.

**Verification**: Output must match exactly; run tests.

---

### Phase 4: Optimize Queue Cache Lookups

**Problem**: Two grep calls per operation (lines 753, 825) for queue status lookups = 2N grep processes.

**Current**:
```bash
queue_entry_status=$(grep "^${name}"$'\t' "${queue_cache}" | cut -f2)
mq_updated=$(grep "^${name}"$'\t'"completed"$'\t' "${queue_cache}" | cut -f3)
```

**Solution**: Load queue cache into shell pattern once, use bash string matching:

```bash
# Before loop: Load entire cache into variable
queue_cache_data=$(<"${queue_cache}")

# In loop: Use bash pattern matching
if [[ "${queue_cache_data}" == *$'\n'"${name}"$'\t'* ]] || [[ "${queue_cache_data}" == "${name}"$'\t'* ]]; then
  # Extract with bash substring expansion or single grep on variable
  queue_line=$(echo "${queue_cache_data}" | grep "^${name}"$'\t')
  queue_entry_status=$(echo "${queue_line}" | cut -f2)
fi
```

**Better alternative**: If implementing Phase 3 (awk processing), queue lookups happen in awk using pre-parsed associative arrays - no grep at all.

**Savings**: Reduces 2N grep/cut calls to 0 (if combined with Phase 3).

---

### Phase 5: Parallelize wk list Calls (Optional)

**Problem**: Four sequential `wk list` calls (lines 884-887) each taking ~16ms = ~64ms total.

```bash
bugs_in_progress=$(wk list --type bug --status in_progress 2>/dev/null || true)
bugs_open=$(wk list --type bug --status todo 2>/dev/null || true)
chores_in_progress=$(wk list --type chore --status in_progress 2>/dev/null || true)
chores_open=$(wk list --type chore --status todo 2>/dev/null || true)
```

**Solution**: Run in parallel using background jobs:

```bash
# Temp files for parallel results
tmp_bugs_ip=$(mktemp); tmp_bugs_open=$(mktemp)
tmp_chores_ip=$(mktemp); tmp_chores_open=$(mktemp)

# Launch in parallel
wk list --type bug --status in_progress > "${tmp_bugs_ip}" 2>/dev/null &
wk list --type bug --status todo > "${tmp_bugs_open}" 2>/dev/null &
wk list --type chore --status in_progress > "${tmp_chores_ip}" 2>/dev/null &
wk list --type chore --status todo > "${tmp_chores_open}" 2>/dev/null &
wait

# Read results
bugs_in_progress=$(<"${tmp_bugs_ip}")
bugs_open=$(<"${tmp_bugs_open}")
# ... etc

# Cleanup
rm -f "${tmp_bugs_ip}" "${tmp_bugs_open}" "${tmp_chores_ip}" "${tmp_chores_open}"
```

**Savings**: ~48ms (parallel execution vs sequential).

**Note**: This is optional as 64ms is not significant compared to the N×date savings.

---

## Key Implementation Details

### jq Timestamp Parsing

jq's `strptime` and `mktime` handle ISO 8601 UTC timestamps:

```jq
# Parse "2026-01-22T10:30:45.123Z" to epoch
"2026-01-22T10:30:45.123Z" | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime
```

Ensure milliseconds are stripped (the `sub` call) as jq's strptime doesn't handle them.

### awk Timestamp Parsing (GNU awk)

GNU awk's `mktime` expects "YYYY MM DD HH MM SS":

```awk
function iso_to_epoch(ts) {
  gsub(/[-T:Z]/, " ", ts)
  gsub(/\.[0-9]+/, "", ts)  # Remove milliseconds
  return mktime(ts)
}
```

macOS awk (BSD) lacks `mktime`, so prefer the jq approach or use gawk.

### Backward Compatibility

- **Bash 3.2**: No associative arrays. Use string matching or file-based lookups.
- **BSD awk**: Lacks `mktime`/`strftime`. Use jq for timestamp math, awk for simple formatting.

### Error Handling

Preserve existing `2>/dev/null || true` patterns. Invalid timestamps should fall back to displaying the date string (first 10 chars).

---

## Verification Plan

1. **Unit tests**: Run existing test suite
   ```bash
   make test-file FILE=tests/unit/v0-status.bats
   ```

2. **Output comparison**: Ensure display matches before/after
   ```bash
   # Create baseline
   v0 status > /tmp/before.txt 2>&1
   # Apply changes, then:
   v0 status > /tmp/after.txt 2>&1
   diff /tmp/before.txt /tmp/after.txt
   ```

3. **Performance measurement**: Time with representative operation count
   ```bash
   # Create test operations if needed
   time v0 status
   ```

4. **Edge cases**:
   - Empty operations directory
   - Operations with missing timestamps
   - Operations with future timestamps (negative elapsed)
   - Very old operations (>1 day, date display)

5. **Linting**:
   ```bash
   make lint
   ```

---

## Summary of Expected Savings

| Phase | Subprocess Spawns (N=200) | Reduction |
|-------|---------------------------|-----------|
| Before optimization | ~800+ | baseline |
| Phase 1: Cache now_epoch | 600 | -200 |
| Phase 2: jq epoch conversion | 400 | -200 |
| Phase 3: awk formatting | ~10 | -390 |
| Phase 4: Queue lookups in awk | ~5 | -5 |
| **Total** | **~5** | **~795** |

Primary wins come from Phases 1-3. Phase 4 is absorbed into Phase 3. Phase 5 is optional polish.
