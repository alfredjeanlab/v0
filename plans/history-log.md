# Implementation Plan: v0 log (History Log)

## Overview

Add `v0 log` as an undocumented command that combines completed operation history from `v0 chore --history`, `v0 fix --history`, and `v0 mergeq --history`. The mergeq command needs a new `--history` option to match the others.

## Project Structure

```
bin/
  v0-log                    # New: combined history command
  v0-mergeq                 # Modify: add --history option
packages/
  mergeq/lib/
    io.sh                   # Existing: queue I/O functions
    history.sh              # New: history query functions
  cli/lib/
    history-format.sh       # New: shared timestamp formatting
```

## Dependencies

- Existing `wk` CLI for listing completed chores/bugs
- Existing queue.json for merge queue history
- State files in `${BUILD_DIR}/<type>/<id>/state.json`

## Implementation Phases

### Phase 1: Extract Shared Timestamp Formatting

Extract the duplicate `format_timestamp()` function from v0-chore and v0-fix into a shared library.

**Files to modify:**
- `packages/cli/lib/history-format.sh` (new)
- `bin/v0-chore` (refactor to use shared lib)
- `bin/v0-fix` (refactor to use shared lib)

**Implementation:**

```bash
# packages/cli/lib/history-format.sh

# Format ISO timestamp for display
# Today: relative (just now, 5 mins ago, 2 hrs ago)
# Other: date only (2026-01-24)
format_timestamp() {
  local ts="${1:-}"
  [[ -z "${ts}" ]] && { echo "unknown"; return; }

  local ts_epoch now_epoch diff_secs
  ts_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%s" 2>/dev/null || echo "0")
  now_epoch=$(date "+%s")
  diff_secs=$((now_epoch - ts_epoch))

  local ts_date today
  ts_date=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%Y-%m-%d" 2>/dev/null || echo "")
  today=$(date "+%Y-%m-%d")

  if [[ "${ts_date}" = "${today}" ]]; then
    if [[ "${diff_secs}" -lt 60 ]]; then
      echo "just now"
    elif [[ "${diff_secs}" -lt 3600 ]]; then
      local mins=$((diff_secs / 60))
      echo "${mins} mins ago"
    else
      local hrs=$((diff_secs / 3600))
      echo "${hrs} hrs ago"
    fi
  else
    echo "${ts_date}"
  fi
}
```

**Verification:** Run `v0 chore --history` and `v0 fix --history` to confirm formatting still works.

---

### Phase 2: Add --history to v0-mergeq

Add `--history` option to v0-mergeq that shows completed/failed merge operations.

**Files to modify:**
- `packages/mergeq/lib/history.sh` (new)
- `bin/v0-mergeq`

**Data source:** Read from `queue.json`, filter for terminal statuses (`completed`, `failed`, `conflict`).

**Implementation:**

```bash
# packages/mergeq/lib/history.sh

# List completed merge queue entries
# Args: [limit] - max entries to show (default 10)
mq_list_history() {
  local limit="${1:-10}"
  local queue_file="${MERGEQ_DIR}/queue.json"

  [[ ! -f "${queue_file}" ]] && return 0

  # Extract terminal entries, sort by updated_at descending
  # Terminal statuses: completed, failed, conflict
  jq -r '
    .entries
    | map(select(.status == "completed" or .status == "failed" or .status == "conflict"))
    | sort_by(.updated_at) | reverse
    | .[]
    | [.operation, .status, .updated_at, .issue_id // ""] | @tsv
  ' "${queue_file}" 2>/dev/null | head -n "${limit}"
}
```

**v0-mergeq additions:**

```bash
# Argument parsing
--history)
  ACTION="history"
  HISTORY_LIMIT=10
  shift
  ;;
--history=*)
  ACTION="history"
  arg="${1#--history=}"
  if [[ "${arg}" = "all" ]]; then
    HISTORY_LIMIT=999999
  else
    HISTORY_LIMIT="${arg}"
  fi
  shift
  ;;

# Action handler
show_history() {
  local limit="${1:-10}"
  local entries
  entries=$(mq_list_history "${limit}")

  if [[ -z "${entries}" ]]; then
    echo "No completed merges"
    return 0
  fi

  echo "Completed Merges:"
  echo ""

  while IFS=$'\t' read -r op status updated_at issue_id; do
    local date_str
    date_str=$(format_timestamp "${updated_at}")
    local status_icon=""
    case "${status}" in
      completed) status_icon="✓" ;;
      failed)    status_icon="✗" ;;
      conflict)  status_icon="!" ;;
    esac
    printf "%-20s %s (%s)\n" "${op}" "${status_icon}" "${date_str}"
  done <<< "${entries}"
}
```

**Verification:** Run `v0 mergeq --history` after completing some merge operations.

---

### Phase 3: Create v0-log Command

Create the combined history command that aggregates all completed operations.

**Files to create:**
- `bin/v0-log`

**Implementation:**

```bash
#!/usr/bin/env bash
# v0-log - Show combined history of completed operations
# Usage: v0 log [--limit=N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V0_ROOT="${SCRIPT_DIR%/bin}"

# Source required libraries
source "${V0_ROOT}/packages/core/lib/config.sh"
source "${V0_ROOT}/packages/core/lib/logging.sh"
source "${V0_ROOT}/packages/cli/lib/history-format.sh"
source "${V0_ROOT}/packages/mergeq/lib/history.sh"

# Initialize
v0_load_config
BUILD_DIR="${V0_STATE_DIR:-${HOME}/.local/state/v0}/build"
MERGEQ_DIR="${V0_STATE_DIR:-${HOME}/.local/state/v0}/mergeq"
LIMIT=20

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit=*) LIMIT="${1#--limit=}"; shift ;;
    --limit)   LIMIT="${2:-20}"; shift 2 ;;
    -h|--help) echo "Usage: v0 log [--limit=N]"; exit 0 ;;
    *) shift ;;
  esac
done

# Collect all history entries with timestamps for sorting
declare -a entries=()

# Get chore history
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  local id ts msg
  id=$(echo "${line}" | cut -f1)
  ts=$(echo "${line}" | cut -f2)
  msg=$(echo "${line}" | cut -f3)
  entries+=("${ts}|chore|${id}|${msg}")
done < <(get_chore_history_raw "${LIMIT}")

# Get fix history
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  local id ts msg
  id=$(echo "${line}" | cut -f1)
  ts=$(echo "${line}" | cut -f2)
  msg=$(echo "${line}" | cut -f3)
  entries+=("${ts}|fix|${id}|${msg}")
done < <(get_fix_history_raw "${LIMIT}")

# Get mergeq history
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  local op status ts
  op=$(echo "${line}" | cut -f1)
  status=$(echo "${line}" | cut -f2)
  ts=$(echo "${line}" | cut -f3)
  entries+=("${ts}|merge|${op}|${status}")
done < <(mq_list_history "${LIMIT}")

# Sort by timestamp descending and display
printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -r | head -n "${LIMIT}" | \
while IFS='|' read -r ts type id desc; do
  local date_str
  date_str=$(format_timestamp "${ts}")
  printf "%-8s %-15s (%s) %s\n" "[${type}]" "${id}" "${date_str}" "${desc}"
done
```

**Verification:** Run `v0 log` and verify it shows combined, sorted output.

---

### Phase 4: Add Raw History Functions

Add functions to get raw history data (with timestamps) for sorting in v0-log.

**Files to modify:**
- `packages/cli/lib/history-format.sh` (add raw getters)

```bash
# Get raw chore history as TSV: id<TAB>timestamp<TAB>message
get_chore_history_raw() {
  local limit="${1:-10}"
  local chores
  chores=$(wk list --type chore --status "done" 2>/dev/null || true)

  [[ -z "${chores}" ]] && return 0

  local count=0
  while IFS= read -r line; do
    [[ "${count}" -ge "${limit}" ]] && break

    local id
    id=$(echo "${line}" | v0_grep_extract '[a-zA-Z0-9]+-[a-f0-9]+' | head -1)
    [[ -z "${id}" ]] && continue

    local state_file="${BUILD_DIR}/chore/${id}/state.json"
    if [[ -f "${state_file}" ]]; then
      local pushed_at commit_msg
      pushed_at=$(v0_grep_extract '"pushed_at": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      commit_msg=$(v0_grep_extract '"commit_message": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      printf "%s\t%s\t%s\n" "${id}" "${pushed_at}" "${commit_msg}"
    fi

    count=$((count + 1))
  done <<< "${chores}"
}

# Get raw fix history as TSV: id<TAB>timestamp<TAB>message
get_fix_history_raw() {
  local limit="${1:-10}"
  local bugs
  bugs=$(wk list --type bug --status "done" 2>/dev/null || true)

  [[ -z "${bugs}" ]] && return 0

  local count=0
  while IFS= read -r line; do
    [[ "${count}" -ge "${limit}" ]] && break

    local id
    id=$(echo "${line}" | v0_grep_extract "$(v0_issue_pattern)" | head -1)
    [[ -z "${id}" ]] && continue

    local state_file="${BUILD_DIR}/fix/${id}/state.json"
    if [[ -f "${state_file}" ]]; then
      local pushed_at commit_msg
      pushed_at=$(v0_grep_extract '"pushed_at": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      commit_msg=$(v0_grep_extract '"commit_message": "[^"]*"' "${state_file}" | cut -d'"' -f4)
      printf "%s\t%s\t%s\n" "${id}" "${pushed_at}" "${commit_msg}"
    fi

    count=$((count + 1))
  done <<< "${bugs}"
}
```

**Verification:** Test raw functions return properly formatted TSV data.

---

## Key Implementation Details

### Filtering for Completed Only

| Source | Filter Criteria |
|--------|-----------------|
| chores | `wk list --type chore --status "done"` |
| bugs   | `wk list --type bug --status "done"` |
| mergeq | entries with status in `[completed, failed, conflict]` |

### Output Format

```
[type]   id              (timestamp) description
[chore]  c-abc123        (just now) Fix: v0 status exits early
[fix]    b-def456        (5 mins ago) Fix login validation
[merge]  chore/c-abc123  (2 hrs ago) completed
```

### Undocumented Command

- Do NOT add `v0 log` to help text or documentation
- Do NOT register in command completion
- Command should work but remain discoverable only by those who know about it

### Timestamp Sorting

All entries use ISO 8601 timestamps (`2026-01-26T14:30:45Z`) which sort lexicographically, enabling simple `sort -r` for descending order.

## Verification Plan

### Phase 1 Verification
```bash
# Confirm shared formatting works
v0 chore --history
v0 fix --history
# Output should be identical to before refactor
```

### Phase 2 Verification
```bash
# Test mergeq history with various states
v0 mergeq --history
v0 mergeq --history=5
v0 mergeq --history=all
# Should show completed/failed/conflict entries only
```

### Phase 3-4 Verification
```bash
# Test combined log
v0 log
v0 log --limit=5

# Verify sorting (most recent first)
# Verify only completed operations shown
# Verify all three types appear when data exists
```

### Integration Test
```bash
# Add test in tests/v0-log.bats
@test "v0 log shows combined history" {
  # Setup: create some completed operations
  # Run: v0 log
  # Assert: output contains entries from chore, fix, and mergeq
}

@test "v0 log respects --limit" {
  # Setup: create >5 completed operations
  # Run: v0 log --limit=3
  # Assert: exactly 3 lines of output
}
```
