# Implementation Plan: Improved Watch All

## Overview

Improve `v0 watch --all` by:
1. Increasing the default polling interval from 5 seconds to 10 seconds
2. Adding a `--short` flag to `v0 status` that produces more concise output by:
   - Skipping coffee and nudge status lines
   - Hiding Bugs/Chores/Merges sections when they show "Stopped" or "None"
3. Using `--short` in `v0 watch --all` for cleaner multi-project display

## Project Structure

Files to modify:
```
bin/v0-watch    # Change default interval for --all mode
bin/v0-status   # Add --short flag and conditional section display
```

## Dependencies

None - uses existing status display infrastructure.

## Implementation Phases

### Phase 1: Add --short flag to v0-status

**File:** `bin/v0-status`

1. Add `SHORT=""` variable with other flags (~line 175):
   ```bash
   SHORT=""
   ```

2. Add case to argument parsing (~line 188, after `--no-hints`):
   ```bash
   --short) SHORT=1; shift ;;
   ```

3. Update usage() to document the flag (~line 46):
   ```bash
   --short        Compact output (hides inactive sections, coffee/nudge)
   ```

### Phase 2: Conditionally hide coffee/nudge status

**File:** `bin/v0-status` (~lines 683-699)

Wrap the coffee/nudge display block with a SHORT check:

```bash
# Show coffee and nudge status on one line (unless --short mode)
if [[ -z "${SHORT}" ]]; then
  coffee_status=""
  nudge_status=""
  if coffee_is_running; then
    coffee_pid_val=$(coffee_pid)
    coffee_status="${C_GREEN}Running${C_RESET} ${C_DIM}[pid: ${coffee_pid_val}]${C_RESET}"
  else
    coffee_status="${C_DIM}Stopped${C_RESET}"
  fi
  if nudge_running; then
    nudge_pid_val=$(nudge_pid)
    nudge_status="${C_GREEN}Running${C_RESET} ${C_DIM}[pid: ${nudge_pid_val}]${C_RESET}"
  else
    nudge_status="${C_DIM}Stopped${C_RESET}"
  fi
  echo -e "Coffee: ${coffee_status}"
  echo -e "Nudge: ${nudge_status}"
fi
```

### Phase 3: Conditionally hide inactive worker sections

**File:** `bin/v0-status` (~lines 622-681)

For each worker section (Bugs, Chores, Merges), skip display when:
- `--short` is set AND
- Status is "Stopped" or queue is empty (None)

**Bugs section (~lines 622-626):**
```bash
# Bugs section
fix_status=$(get_worker_status "fix" "${all_sessions}" "${all_polling}")
# In short mode, skip if Stopped or None
if [[ -z "${SHORT}" ]] || { [[ "${fix_status}" != "stopped" ]] && [[ "${bugs_empty}" != true ]]; }; then
  show_worker_header_compact "Bugs" "${fix_status}" "${bugs_empty}"
  [[ "${bugs_empty}" != true ]] && show_worker_items_inline "${bugs_in_progress}" "${bugs_open}" 3
  [[ "${bugs_empty}" != true ]] && echo ""
fi
```

**Chores section (~lines 628-632):**
```bash
# Chores section
chore_status=$(get_worker_status "chore" "${all_sessions}" "${all_polling}")
# In short mode, skip if Stopped or None
if [[ -z "${SHORT}" ]] || { [[ "${chore_status}" != "stopped" ]] && [[ "${chores_empty}" != true ]]; }; then
  show_worker_header_compact "Chores" "${chore_status}" "${chores_empty}"
  [[ "${chores_empty}" != true ]] && show_worker_items_inline "${chores_in_progress}" "${chores_open}" 3
  [[ "${chores_empty}" != true ]] && echo ""
fi
```

**Merges section (~lines 634-681):**

The merges section is more complex. Extract status determination first, then conditionally show:

```bash
# Merges section
mergeq_pid_file="${BUILD_DIR}/mergeq/.daemon.pid"
merge_resolve_running=false
if [[ -n "${all_sessions}" ]] && echo "${all_sessions}" | v0_grep_quiet "merge-resolve"; then
  merge_resolve_running=true
fi

# Determine merge status
merge_status_text=""
if [[ -f "${mergeq_pid_file}" ]] && kill -0 "$(cat "${mergeq_pid_file}" 2>/dev/null)" 2>/dev/null; then
  processing=$(echo "${mergeq_entries}" | v0_grep_count "^processing" 2>/dev/null)
  pending=$(echo "${mergeq_entries}" | v0_grep_count "^pending" 2>/dev/null)
  if [[ "${processing}" -gt 0 ]] || [[ "${pending}" -gt 0 ]]; then
    merge_status_text="active"
  else
    merge_status_text="polling"
  fi
elif [[ "${merge_resolve_running}" = true ]]; then
  merge_status_text="active"
elif [[ "${merges_empty}" = true ]]; then
  merge_status_text="none"
else
  merge_status_text="stopped"
fi

# In short mode, skip if Stopped or None
if [[ -z "${SHORT}" ]] || { [[ "${merge_status_text}" != "stopped" ]] && [[ "${merge_status_text}" != "none" ]]; }; then
  # Display merge header based on status
  case "${merge_status_text}" in
    active)  echo -e "Merges: ${C_CYAN}Active${C_RESET}" ;;
    polling) echo -e "Merges: ${C_YELLOW}Polling${C_RESET}" ;;
    none)    echo -e "Merges: ${C_DIM}None${C_RESET}" ;;
    stopped) echo -e "Merges: ${C_DIM}Stopped${C_RESET}" ;;
  esac
  # Display queue items if not empty
  if [[ "${merges_empty}" != true ]]; then
    total=$(echo "${mergeq_entries}" | v0_grep_count '.' 2>/dev/null)
    if [[ "${total}" -le 3 ]]; then
      echo "${mergeq_entries}" | while IFS=$'\t' read -r status op; do
        [[ -z "${status}" ]] && continue
        status_color="${C_CYAN}"
        [[ "${status}" = "pending" ]] && status_color=""
        printf "  ${status_color}%-12s${C_RESET} %s\n" "[${status}]" "${op}"
      done
    else
      echo "${mergeq_entries}" | head -n 3 | while IFS=$'\t' read -r status op; do
        [[ -z "${status}" ]] && continue
        status_color="${C_CYAN}"
        [[ "${status}" = "pending" ]] && status_color=""
        printf "  ${status_color}%-12s${C_RESET} %s\n" "[${status}]" "${op}"
      done
      remaining=$((total - 3))
      echo -e "  ${C_DIM}... and ${remaining} more in queue${C_RESET}"
    fi
  fi
fi
[[ "${merges_empty}" != true ]] && [[ -z "${SHORT}" || "${merge_status_text}" == "active" || "${merge_status_text}" == "polling" ]] && echo ""
```

### Phase 4: Update v0-watch --all to use --short and 10s interval

**File:** `bin/v0-watch`

1. Change default interval for --all mode (~line 10):
   Current: `REFRESH_INTERVAL=5`

   Add a separate default for --all mode. After parsing `--all` flag (~line 87), set:
   ```bash
   # System-wide watch mode
   if [[ -n "${WATCH_ALL}" ]]; then
     # Use longer interval for --all mode if not explicitly set
     [[ "${REFRESH_INTERVAL}" -eq 5 ]] && REFRESH_INTERVAL=10
   ```

2. Add `--short` to the v0-status call (~line 184):
   Current: `"${SCRIPT_DIR}/v0-status" --no-hints --max-ops 5`
   Change to: `"${SCRIPT_DIR}/v0-status" --no-hints --max-ops 5 --short`

### Phase 5: Update help text

**File:** `bin/v0-watch` (~line 27)

Update the help text to reflect the 10-second default for --all:
```bash
-n, --interval SECS   Refresh interval in seconds (default: 5, or 10 with --all)
```

## Key Implementation Details

### Status Detection Logic

The `get_worker_status` function in `packages/status/lib/worker-status.sh` returns:
- `"running"` - Worker tmux session is active
- `"polling"` - Daemon is running but no active work
- `"stopped"` - Nothing running

For `--short` mode, we skip sections when:
- Status is `"stopped"` (daemon not running)
- Queue is empty (would show "None")

### Backwards Compatibility

- Default behavior of `v0 status` unchanged (shows all sections)
- Default behavior of `v0 watch` unchanged (5-second interval)
- Only `v0 watch --all` gets the 10-second default and `--short` output

### Edge Cases

- If user explicitly passes `-n 5` with `--all`, their choice is respected
- Empty projects in `--all` mode will show minimal output (just Plans section)
- The `--short` flag can be used standalone with `v0 status --short`

## Verification Plan

1. **Manual verification of --short flag:**
   ```bash
   # Normal output
   v0 status

   # Short output (should hide Stopped/None sections and coffee/nudge)
   v0 status --short
   ```

2. **Manual verification of watch --all:**
   ```bash
   # Should now poll every 10 seconds with concise output
   v0 watch --all

   # Override to 5 seconds
   v0 watch --all -n 5
   ```

3. **Lint check:**
   ```bash
   make lint
   ```

4. **Run existing tests:**
   ```bash
   scripts/test
   ```

5. **Integration test scenarios:**
   - Start a fix worker, verify `v0 status --short` shows Bugs section
   - Stop fix worker, verify `v0 status --short` hides Bugs section
   - Same for chore and merge workers
