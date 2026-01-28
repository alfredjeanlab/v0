# Plan: Add Held Semantics to `v0 wait`

## Summary

Update `v0 wait` to detect when an operation is held (paused) and stop waiting with an informational message instead of polling forever or timing out.

## Problem

After `v0 plan`, operations are auto-held. If user runs `v0 wait`, it polls forever because `planned` is not a terminal phase. Users expect `v0 wait` to recognize the held state.

## Solution

Add held state detection to `check_work_completion()` and handle it in the wait loops with a new exit code (4) and informational message.

## Changes

### 1. `bin/v0-wait` - Help text (lines 27-31)

Add exit code 4:
```
Exit codes:
  0    Completed successfully
  1    Failed or was cancelled
  2    Timeout expired
  3    Target not found
  4    Paused (held)
```

### 2. `bin/v0-wait` - `check_work_completion()` (lines 163-171)

Add held check for operations (return 3 for held):
```bash
operation)
  local phase
  phase=$(sm_read_state "${work_id}" "phase")
  if sm_is_terminal_phase "${phase}"; then
    [[ "${phase}" == "merged" ]] && return 0 || return 2
  fi
  # Check if held (paused)
  if sm_is_held "${work_id}"; then
    return 3
  fi
  return 1
  ;;
```

### 3. `bin/v0-wait` - `wait_for_work_completion()` (lines 238-247)

Handle result 3 (held), return exit code 4:
```bash
case ${result} in
  0) # Complete
    [[ -z "${quiet}" ]] && echo "'${display_name}' completed successfully"
    return 0
    ;;
  2) # Failed
    [[ -z "${quiet}" ]] && echo "'${display_name}' failed or was cancelled"
    return 1
    ;;
  3) # Held (paused)
    if [[ -z "${quiet}" ]]; then
      echo -e "${C_CYAN}Note:${C_RESET} Finished waiting because '${display_name}' is paused (held)"
      echo -e "  ${C_DIM}Resume with:${C_RESET} v0 resume ${work_id}"
    fi
    return 4
    ;;
esac
```

### 4. `bin/v0-wait` - `wait_for_issue()` (lines 310-319)

Same pattern for issue-based waiting:
```bash
case ${result} in
  0) # Complete
    [[ -z "${quiet}" ]] && echo "Issue '${issue_id}' completed successfully"
    return 0
    ;;
  2) # Failed
    [[ -z "${quiet}" ]] && echo "Issue '${issue_id}' failed"
    return 1
    ;;
  3) # Held (paused)
    if [[ -z "${quiet}" ]]; then
      echo -e "${C_CYAN}Note:${C_RESET} Finished waiting because issue '${issue_id}' is paused (held)"
      echo -e "  ${C_DIM}Resume with:${C_RESET} v0 resume ${work_id}"
    fi
    return 4
    ;;
esac
```

### 5. `tests/v0-wait.bats` - Add test cases

- Held operation returns exit code 4
- Held operation shows "paused (held)" message
- Held operation shows resume hint
- `--quiet` suppresses held message but still returns 4
- Held operation found via issue ID returns 4
- Non-held planned operation times out (not treated as held)

## Files to Modify

1. `/Users/kestred/Developer/v0/bin/v0-wait` - Main implementation
2. `/Users/kestred/Developer/v0/tests/v0-wait.bats` - Tests

## No Changes Needed

- `packages/state/lib/holds.sh` - Already has `sm_is_held()` function
- Other hold-setting commands (`v0 plan`, `v0 hold`, `v0 build --hold`) - Already set `held: true` in state.json correctly

## Verification

```bash
# Create a held operation and test
v0 plan testop "test" --direct
v0 wait testop          # Should return 4 with "paused (held)" message
echo $?                 # Should be 4

# Run tests
scripts/test v0-wait

# Full check
make check
```
