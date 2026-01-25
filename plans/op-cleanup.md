# Implementation Plan: v0 build Flag Cleanup

## Overview

Simplify `v0 build` by removing several flags (`--eager`, `--foreground`, `--safe`, `--enqueue`) and adding `--hold` for automatic hold on creation. Also add `--blocked-by` as an undocumented alias of `--after`.

## Project Structure

Files to modify:
```
bin/v0-build            # Main command implementation
bin/v0-build-worker     # Background worker
tests/v0-build.bats     # Integration tests
```

## Dependencies

None - this is a refactoring of existing functionality.

## Implementation Phases

### Phase 1: Add --hold and --blocked-by Flags

Add new functionality first, before removing anything.

**bin/v0-build:**

1. Add `HOLD=""` variable (line ~84, with other flag variables)

2. Add flag parsing for `--hold` and `--blocked-by` (in case statement ~87-120):
```bash
--hold) HOLD=1; shift ;;
--blocked-by) AFTER="$2"; shift 2 ;;  # Undocumented alias
```

3. After `init_state` is called (around line 533), set hold if requested:
```bash
if [[ -n "${HOLD}" ]]; then
  sm_set_hold "${NAME}"
fi
```

4. Do NOT add `--hold` or `--blocked-by` to usage text (both undocumented)

**Verification:** Run `v0 build test-hold "Test" --hold --dry-run` and verify hold is set in state.

### Phase 2: Remove --eager Mode

Remove the eager mode which allowed planning before blocking.

**bin/v0-build:**

1. Remove `EAGER=""` variable declaration (line 81)

2. Remove `--eager) EAGER=1; shift ;;` from flag parsing (line 103)

3. Remove `--eager` validation block (lines 181-184):
```bash
# DELETE:
elif [[ -n "${EAGER}" ]]; then
  echo "Error: --eager requires --after"
  exit 1
fi
```

4. Remove `eager` from state initialization (lines 215, 220, 243):
   - Remove `local eager="false"`
   - Remove `[[ -n "${EAGER}" ]] && eager="true"`
   - Remove `"eager": ${eager},` from state JSON

5. Remove eager from resume logic (lines 301-302):
```bash
# DELETE:
EAGER=$(get_state eager)
[[ "${EAGER}" = "true" ]] && EAGER=1 || EAGER=""
```

6. Remove eager mode blocking logic at build phase (lines 832-846):
```bash
# DELETE entire block:
if [[ -n "${EAGER}" ]] && [[ -n "${AFTER}" ]] && [[ "${AFTER}" != "null" ]]; then
  ...
fi
```

7. Remove from usage text:
   - Line 38: `--eager` option description
   - Line 51: `--eager` mode explanation
   - Line 65: Example with `--eager`

**bin/v0-build-worker:**

1. Remove eager logic in `run_build_phase()` (lines 400-411):
```bash
# DELETE:
local EAGER
EAGER=$(get_state eager)
if [[ "${EAGER}" = "true" ]] && ...
```

**tests/v0-build.bats:**

1. Remove test `v0-build: --eager requires --after` (lines 196-200)

**Verification:** Run `make lint` and `scripts/test v0-build`

### Phase 3: Remove --foreground Mode

Remove foreground mode - all operations now run in background by default.

**bin/v0-build:**

1. Remove `FOREGROUND=""` variable declaration (line 83)

2. Remove `--foreground) FOREGROUND=1; shift ;;` from flag parsing (line 105)

3. In resume logic, remove foreground checks (line 379):
```bash
# CHANGE:
if [[ -z "${FOREGROUND}" ]] && [[ -z "${DRY_RUN}" ]]; then
# TO:
if [[ -z "${DRY_RUN}" ]]; then
```

4. For new operations, remove foreground check (line 619):
```bash
# CHANGE:
if [[ -z "${FOREGROUND}" ]] && [[ -z "${DRY_RUN}" ]]; then
# TO:
if [[ -z "${DRY_RUN}" ]]; then
```

5. Remove all foreground-specific code blocks (lines 651-932 approximately):
   - The entire "Phase 1: Plan" foreground execution block
   - The entire "Phase 2: Execute" foreground execution block

   Since these blocks only run when `FOREGROUND` is set and we're removing that mode, the code after the background worker spawn (`exit 0`) becomes dead code for the non-resume path. Keep only:
   - The resume path execution (which already spawns background workers)
   - Error handling

6. Remove from usage text:
   - Line 40: `--foreground` option
   - Line 45: `--foreground` mode description
   - Line 58: Example with `--foreground`

**Verification:** Run `scripts/test v0-build` and manual test that builds work

### Phase 4: Remove --safe Mode

Remove safe mode which required permission prompts.

**bin/v0-build:**

1. Remove `SAFE=""` variable declaration (line 78)

2. Remove `--safe) SAFE=1; shift ;;` from flag parsing (line 100)

3. Remove `safe` from state initialization (lines 216, 222, 244):
   - Remove `local safe="false"`
   - Remove `[[ -n "${SAFE}" ]] && safe="true"`
   - Remove `"safe": ${safe},` from state JSON

4. Remove safe from resume logic (lines 303-313):
```bash
# DELETE:
SAFE_CHANGED=""
if [[ -n "${SAFE}" ]]; then
  ...
fi
```

5. Remove safe session restart logic (lines 515-521):
```bash
# DELETE:
elif [[ -n "${SAFE_CHANGED}" ]]; then
  echo "Restarting session to apply --safe flag..."
  ...
fi
```

6. Remove safe from Claude args in execute phase (lines 890-893):
```bash
# SIMPLIFY to just:
CLAUDE_ARGS="--model opus --dangerously-skip-permissions --allow-dangerously-skip-permissions"
```

7. Remove `V0_SAFE_EXPORT` logic in plan phase (lines 700-701, 707)

8. Remove from usage text:
   - Line 35: `--safe` option description

**bin/v0-build-worker:**

1. Remove safe handling in `run_plan_phase()` (lines 202-203, 222-223):
```bash
# DELETE:
local SAFE
SAFE=$(get_state safe)
...
V0_SAFE_EXPORT=""
[[ "${SAFE}" = "true" ]] && V0_SAFE_EXPORT="export V0_SAFE=1"
```

2. Remove safe from Claude args in `run_build_phase()` (lines 489-492):
```bash
# SIMPLIFY to just:
CLAUDE_ARGS="--model opus --dangerously-skip-permissions --allow-dangerously-skip-permissions"
```

**Verification:** Run `scripts/test v0-build`

### Phase 5: Remove --enqueue Mode

Remove enqueue mode which planned without executing.

**bin/v0-build:**

1. Remove `ENQUEUE_ONLY=""` variable declaration (line 73)

2. Remove `--enqueue) ENQUEUE_ONLY=1; shift ;;` from flag parsing (line 89)

3. Remove enqueue-only output block (lines 933-940):
```bash
# DELETE:
elif [[ "${PHASE}" = "queued" ]]; then
  echo ""
  echo -e "${C_BOLD}${C_CYAN}=== Work queued (--enqueue mode) ===${C_RESET}"
  ...
fi
```

4. Remove `[[ -z "${ENQUEUE_ONLY}" ]]` check in build phase (line 829):
```bash
# CHANGE:
if [[ "${PHASE}" = "queued" ]] && [[ -z "${ENQUEUE_ONLY}" ]]; then
# TO:
if [[ "${PHASE}" = "queued" ]]; then
```

5. Remove from usage text:
   - Line 30: `--enqueue` option
   - Line 46: `--enqueue` mode description
   - Line 59: Example with `--enqueue`

**bin/v0-build-worker:**

1. Remove enqueue_only handling in `run_build_phase()` (lines 390-396):
```bash
# DELETE:
local ENQUEUE_ONLY
ENQUEUE_ONLY=$(get_state enqueue_only)
if [[ "${ENQUEUE_ONLY}" = "true" ]]; then
  log "Enqueue-only mode, skipping build phase"
  return 0
fi
```

**Verification:** Run `scripts/test v0-build`

### Phase 6: Add and Update Tests

**tests/v0-build.bats:**

1. Add test for `--hold` flag:
```bash
@test "v0-build: --hold sets operation hold state" {
    # Create a plan file to skip planning
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    cat > "${TEST_TEMP_DIR}/project/plans/test-op.md" <<EOF
# Test Plan
Feature: \`test-feature456\`
## Tasks
- Task 1
EOF

    run "${V0_BUILD}" test-op --plan "${TEST_TEMP_DIR}/project/plans/test-op.md" --hold --dry-run 2>&1 || true

    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    if [[ -f "${state_file}" ]]; then
        run jq -r '.held' "${state_file}"
        assert_output "true"
    fi
}
```

2. Add test for `--blocked-by` alias:
```bash
@test "v0-build: --blocked-by is alias for --after" {
    # Create blocker operation
    local blocker_dir="${TEST_TEMP_DIR}/project/.v0/build/operations/blocker"
    mkdir -p "${blocker_dir}"
    cat > "${blocker_dir}/state.json" <<EOF
{
  "name": "blocker",
  "phase": "merged",
  "epic_id": "test-blocker123"
}
EOF

    run "${V0_BUILD}" test-op "Test prompt" --blocked-by blocker --dry-run 2>&1 || true

    local state_file="${TEST_TEMP_DIR}/project/.v0/build/operations/test-op/state.json"
    if [[ -f "${state_file}" ]]; then
        run jq -r '.after' "${state_file}"
        assert_output "blocker"
    fi
}
```

3. Remove `--eager requires --after` test (already done in Phase 2)

4. Update any tests that use removed flags (`--foreground`, `--safe`, `--enqueue`, `--eager`)

5. Add test verifying removed flags produce errors:
```bash
@test "v0-build: --foreground is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --foreground 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

@test "v0-build: --safe is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --safe 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

@test "v0-build: --enqueue is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --enqueue 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}

@test "v0-build: --eager is not a valid option" {
    run "${V0_BUILD}" test-op "Test prompt" --eager 2>&1
    assert_failure
    assert_output --partial "Unknown option"
}
```

**Verification:** Run full test suite: `make check`

## Key Implementation Details

### Flag Behavior Summary

| Flag | Action |
|------|--------|
| `--hold` | Sets `held=true` in state after creation (undocumented) |
| `--blocked-by` | Alias for `--after` (undocumented) |
| `--eager` | REMOVED |
| `--foreground` | REMOVED |
| `--safe` | REMOVED |
| `--enqueue` | REMOVED |

### State Schema Changes

The `state.json` schema will have these fields removed:
- `eager` (boolean)
- `safe` (boolean)

No new fields are added since `held` already exists.

### Code Removal Strategy

Remove code in reverse dependency order:
1. Tests that use the flags
2. Worker code that reads flag state
3. Main command flag handling and state initialization
4. Usage text

## Verification Plan

1. **After each phase:**
   - Run `make lint` to catch shell errors
   - Run `scripts/test v0-build` to verify existing tests pass

2. **After Phase 6:**
   - Run `make check` for full lint + test suite
   - Manual verification:
     ```bash
     # Test --hold works
     v0 build test-hold "Test feature" --hold --dry-run

     # Test --blocked-by works
     v0 build blocker "Blocker feature" --dry-run
     v0 build dependent "Dependent feature" --blocked-by blocker --dry-run

     # Test removed flags error
     v0 build test "Test" --foreground  # Should error
     v0 build test "Test" --safe        # Should error
     v0 build test "Test" --enqueue     # Should error
     v0 build test "Test" --eager       # Should error
     ```

3. **Integration test:**
   - Create a real build operation and verify it works end-to-end without the removed modes
