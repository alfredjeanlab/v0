# Implementation Plan: Auto-Hold on Plan/Decompose Completion

**Root Feature:** `v0-d025`

## Overview

Modify `v0 plan` and `v0 decompose` to automatically set `held=true` when they complete successfully. This consolidates the workflow so operations enter a "planned [HELD]" or "queued [HELD]" state, eliminating the need for a separate manual hold step and removing the distinct "plan completed" display state.

## Project Structure

Key files affected:
```
bin/
  v0-plan           # Main plan command - 4 locations transition to "planned"
  v0-decompose      # Decompose command - 2 locations transition to "queued"
lib/
  state-machine.sh  # Add helper function for transition + auto-hold
tests/unit/
  v0-plan.bats      # Update existing tests, add new auto-hold tests
  v0-decompose.bats # Add auto-hold tests (if exists, create otherwise)
```

## Dependencies

None - uses existing codebase utilities:
- `sm_set_hold` function (lib/state-machine.sh:754)
- `sm_bulk_update_state` function for atomic updates

## Implementation Phases

### Phase 1: State Machine Enhancement

Add a helper function to combine phase transition with auto-hold for cleaner code.

**File:** `lib/state-machine.sh`

Add function `sm_transition_to_planned_and_hold`:
```bash
# sm_transition_to_planned_and_hold <op> <plan_file>
# Transition to planned phase and set hold in one atomic update
sm_transition_to_planned_and_hold() {
  local op="$1"
  local plan_file="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  sm_ensure_current_schema "${op}"

  sm_bulk_update_state "${op}" \
    "phase" "\"planned\"" \
    "plan_file" "\"${plan_file}\"" \
    "held" "true" \
    "held_at" "\"${now}\""

  sm_emit_event "${op}" "plan:created" "${plan_file}"
  sm_emit_event "${op}" "hold:auto_set" "Automatically held after planning"
}
```

Add function `sm_transition_to_queued_and_hold`:
```bash
# sm_transition_to_queued_and_hold <op> [epic_id]
# Transition to queued phase and set hold in one atomic update
sm_transition_to_queued_and_hold() {
  local op="$1"
  local epic_id="${2:-}"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  sm_ensure_current_schema "${op}"

  if [[ -n "${epic_id}" ]]; then
    sm_bulk_update_state "${op}" \
      "phase" "\"queued\"" \
      "epic_id" "\"${epic_id}\"" \
      "held" "true" \
      "held_at" "\"${now}\""
    sm_emit_event "${op}" "work:queued" "Issues created"
  else
    sm_bulk_update_state "${op}" \
      "phase" "\"queued\"" \
      "held" "true" \
      "held_at" "\"${now}\""
    sm_emit_event "${op}" "work:queued" "Ready for execution"
  fi

  sm_emit_event "${op}" "hold:auto_set" "Automatically held after decompose"
}
```

**Verification:** Run `make lint` to ensure no syntax errors.

### Phase 2: Modify v0-plan for Auto-Hold

Update all 4 locations where `v0-plan` transitions to the "planned" phase.

**File:** `bin/v0-plan`

**Location 1:** Direct mode success (line ~136)
```bash
# Before:
jq ".phase = \"planned\" | .plan_file = \"${V0_PLANS_DIR}/${NAME}.md\"" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"

# After:
sm_transition_to_planned_and_hold "${NAME}" "${V0_PLANS_DIR}/${NAME}.md"
```

**Location 2:** Direct mode recovery (line ~151)
```bash
# Same change as Location 1
sm_transition_to_planned_and_hold "${NAME}" "${V0_PLANS_DIR}/${NAME}.md"
```

**Location 3:** Foreground mode recovery (line ~293)
```bash
# Same change as Location 1
sm_transition_to_planned_and_hold "${NAME}" "${V0_PLANS_DIR}/${NAME}.md"
```

**Location 4:** Foreground mode success (line ~315)
```bash
# Same change as Location 1
sm_transition_to_planned_and_hold "${NAME}" "${V0_PLANS_DIR}/${NAME}.md"
```

**Verification:**
- Run a manual test: `v0 plan test-hold "Simple test" --direct`
- Verify state shows `"held": true` and `"phase": "planned"`
- Run `v0 status test-hold` and confirm it shows "planned [HELD]"

### Phase 3: Modify v0-decompose for Auto-Hold

Update the location where `v0-decompose` transitions to the "queued" phase.

**File:** `bin/v0-decompose`

**Location:** Lines ~106-113
```bash
# Before:
if [[ ${DECOMPOSE_EXIT} -eq 0 ]] || [[ -n "${EPIC_ID}" ]]; then
  tmp=$(mktemp)
  if [[ -n "${EPIC_ID}" ]]; then
    jq ".phase = \"queued\" | .epic_id = \"${EPIC_ID}\"" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
  else
    jq ".phase = \"queued\"" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
  fi
  exit 0

# After:
if [[ ${DECOMPOSE_EXIT} -eq 0 ]] || [[ -n "${EPIC_ID}" ]]; then
  sm_transition_to_queued_and_hold "${BASENAME}" "${EPIC_ID}"
  exit 0
```

**Verification:**
- Create a test plan file and run `v0 decompose plans/test.md` (in mock mode)
- Verify state shows `"held": true` and `"phase": "queued"`

### Phase 4: Update Output Messages

Update user-facing messages to inform users about the auto-hold behavior.

**File:** `bin/v0-plan`

After successful transition, update the notification/log messages:
```bash
v0_log "plan:complete" "${NAME} (held)"
v0_notify "${PROJECT}: plan completed [HELD]" "${NAME}"
echo "Plan created: ${PLAN_FILE}"
echo "Operation is held. Review the plan, then run: v0 resume ${NAME}"
```

**File:** `bin/v0-decompose`

After successful transition:
```bash
echo "Decompose complete. Issues created."
echo "Operation is held. Review issues, then run: v0 resume ${BASENAME}"
```

### Phase 5: Update Tests

**File:** `tests/unit/v0-plan.bats`

Add new tests for auto-hold behavior:
```bash
@test "v0-plan --direct: automatically sets held=true on success" {
    # Setup test project with mock claude
    # Run v0 plan
    # Assert held=true in state.json
    # Assert held_at is set
}

@test "v0-plan --direct: emits hold:auto_set event" {
    # Setup test project
    # Run v0 plan
    # Assert events.log contains "hold:auto_set"
}

@test "v0-plan: status shows 'planned [HELD]' after completion" {
    # Setup test project
    # Run v0 plan
    # Run v0 status
    # Assert output contains "[HELD]"
}
```

**File:** `tests/unit/v0-decompose.bats` (create if doesn't exist)

Add tests:
```bash
@test "v0-decompose: automatically sets held=true on success" {
    # Setup test project with committed plan file
    # Run v0 decompose
    # Assert held=true in state.json
}

@test "v0-decompose: emits hold:auto_set event" {
    # Setup test project
    # Run v0 decompose
    # Assert events.log contains "hold:auto_set"
}
```

Update existing tests that may assume `held=false` after plan/decompose.

**Verification:** Run `make test` - all tests must pass.

### Phase 6: Remove "plan completed" Display State (Optional)

The display helper `_sm_format_phase_display` in `lib/state-machine.sh` (lines 927-929) shows "plan completed" for plan-type operations that reach completed/pending_merge phase. With auto-hold, this case becomes less relevant.

**File:** `lib/state-machine.sh`

Consider updating lines 927-929:
```bash
# Current:
if [[ "${op_type}" = "plan" ]]; then
  display_phase="plan completed"
  merge_icon=""

# Option: Remove special case, let standard display logic handle it
# OR: Keep for backwards compatibility with existing plan-type operations
```

This phase is optional since the held state takes display precedence anyway.

## Key Implementation Details

### Atomic Updates
All phase transitions use `sm_bulk_update_state` to ensure the `phase` and `held` fields are updated together atomically, preventing race conditions where a worker might see `phase=planned` but `held=false`.

### Event Logging
The new event type `hold:auto_set` distinguishes automatic holds from manual `v0 hold` commands, aiding in debugging and auditing workflows.

### Backwards Compatibility
- Existing operations in "planned" phase without `held=true` will continue to work
- The `v0 resume` command already handles clearing holds properly
- Status display already handles the `held` flag correctly

### User Workflow Impact
Before this change:
1. `v0 plan auth "..."` → state: planned
2. User manually runs `v0 hold auth` → state: planned [HELD]
3. User reviews, then `v0 resume auth`

After this change:
1. `v0 plan auth "..."` → state: planned [HELD] (automatic)
2. User reviews, then `v0 resume auth`

## Verification Plan

1. **Unit Tests**
   - Run `make test` - all existing tests pass
   - Run `make test-file FILE=tests/unit/v0-plan.bats` - new tests pass
   - Run `make test-file FILE=tests/unit/v0-decompose.bats` - new tests pass

2. **Lint Check**
   - Run `make lint` - no shellcheck warnings

3. **Integration Tests**
   - Manual test: `v0 plan test1 "Test feature" --direct`
     - Verify `jq '.held, .phase' .v0/build/operations/test1/state.json` outputs `true "planned"`
     - Verify `v0 status test1` shows "[HELD]"
   - Manual test: Create plan file, run `v0 decompose plans/test1.md`
     - Verify state shows held=true and phase=queued

4. **Resume Flow**
   - Run `v0 resume test1` - should clear hold and proceed to next phase
   - Verify workflow continues normally after resume

5. **Edge Cases**
   - Test plan failure (no plan file created) - should not set held
   - Test decompose with already-held operation - should remain held
   - Test with --draft flag - verify hold still applies
