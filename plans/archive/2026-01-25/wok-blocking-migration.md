# Plan: Migrate Blocking to wok

Remove `after` field from v0's state.json and rely exclusively on wok for dependency/blocking tracking.

## Overview

Currently, v0 tracks operation dependencies in two places:
1. **state.json**: `after` field stores the blocker operation name
2. **wok**: `blocked-by` relationships between issue IDs

This creates duplicate state and sync issues. This plan migrates to using wok as the single source of truth for blocking, removing `after` from state.json entirely.

## Project Structure

Key files to modify:

```
packages/state/lib/
  rules.sh              # Bump SM_STATE_VERSION to 2
  schema.sh             # Add migration v1->v2, remove after field
  blocking.sh           # Rewrite to query wok instead of state.json
  transitions.sh        # Remove sm_transition_to_blocked (no longer needed)
  display.sh            # Update phase display helpers

packages/status/lib/
  blocker-display.sh    # NEW: Helper to get first blocker for display

bin/
  v0-build              # Support --after with comma-separated lists
  v0-build-worker       # Remove after field usage, use wok only
  v0-status             # Show first blocker, prefer op names

packages/cli/lib/
  v0-common.sh          # Add v0_get_first_blocker helper
```

## Dependencies

- wok must support `wk show -o json` with `blockers` array (already supported)
- wok must support `wk dep <id> blocked-by <ids...>` (already supported)

## Implementation Phases

### Phase 1: Add wok Query Helpers

**File**: `packages/cli/lib/v0-common.sh`

Add helper functions to query blocking status from wok:

```bash
# v0_get_blockers <epic_id>
# Returns JSON array of blocker issue IDs from wok
# Output: ["v0-abc", "v0-def"] or []
v0_get_blockers() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] && echo "[]" && return

  local blockers
  blockers=$(wk show "${epic_id}" -o json 2>/dev/null | jq -r '.blockers // []')
  echo "${blockers:-[]}"
}

# v0_get_first_open_blocker <epic_id>
# Returns the first blocker that is not done/closed
# Output: issue_id or empty
v0_get_first_open_blocker() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] && return

  # Get blockers and filter to first open one
  local blockers
  blockers=$(v0_get_blockers "${epic_id}")
  [[ "${blockers}" == "[]" ]] && return

  # Check each blocker's status (stop at first open)
  local blocker_id
  for blocker_id in $(echo "${blockers}" | jq -r '.[]'); do
    local status
    status=$(wk show "${blocker_id}" -o json 2>/dev/null | jq -r '.status // "unknown"')
    case "${status}" in
      done|closed) continue ;;
      *) echo "${blocker_id}"; return ;;
    esac
  done
}

# v0_is_blocked <epic_id>
# Check if issue has any open blockers
# Returns: 0 if blocked, 1 if not blocked
v0_is_blocked() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] && return 1

  local first_blocker
  first_blocker=$(v0_get_first_open_blocker "${epic_id}")
  [[ -n "${first_blocker}" ]]
}

# v0_blocker_to_op_name <blocker_id>
# Resolve a wok issue ID to an operation name if possible
# Returns: operation name or original issue ID
v0_blocker_to_op_name() {
  local blocker_id="$1"

  # Check if this issue belongs to an operation (has plan: label)
  local labels
  labels=$(wk show "${blocker_id}" -o json 2>/dev/null | jq -r '.labels // []')

  # Look for plan:<name> label
  local plan_label
  plan_label=$(echo "${labels}" | jq -r '.[] | select(startswith("plan:"))' | head -1)

  if [[ -n "${plan_label}" ]]; then
    # Extract name from plan:<name>
    echo "${plan_label#plan:}"
  else
    # No operation found, return issue ID
    echo "${blocker_id}"
  fi
}
```

**Verification**: Unit test the helpers with mock wk responses.

---

### Phase 2: Create Optimized Blocker Display Helper

**File**: `packages/status/lib/blocker-display.sh` (NEW)

Create a helper optimized for v0-status that minimizes wok calls:

```bash
#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# blocker-display.sh - Optimized blocker display for v0 status

# _status_get_blocker_display <epic_id>
# Get display string for first open blocker
# Optimized: single wk call per operation, cached lookups for op names
# Output: "op_name" or "issue_id" or empty
_status_get_blocker_display() {
  local epic_id="$1"
  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return

  # Single wk call to get blockers
  local issue_json
  issue_json=$(wk show "${epic_id}" -o json 2>/dev/null) || return

  local blockers
  blockers=$(echo "${issue_json}" | jq -r '.blockers // []')
  [[ "${blockers}" == "[]" ]] && return

  # Get first blocker ID
  local first_blocker
  first_blocker=$(echo "${blockers}" | jq -r '.[0]')
  [[ -z "${first_blocker}" ]] && return

  # Check if blocker is open (one more wk call)
  local blocker_json
  blocker_json=$(wk show "${first_blocker}" -o json 2>/dev/null) || {
    echo "${first_blocker}"
    return
  }

  local status
  status=$(echo "${blocker_json}" | jq -r '.status // "unknown"')
  case "${status}" in
    done|closed)
      # First blocker is closed, would need to check more
      # For performance, just return empty (not blocked by first)
      return
      ;;
  esac

  # Try to resolve to operation name via plan: label
  local plan_label
  plan_label=$(echo "${blocker_json}" | jq -r '.labels // [] | .[] | select(startswith("plan:"))' | head -1)

  if [[ -n "${plan_label}" ]]; then
    echo "${plan_label#plan:}"
  else
    echo "${first_blocker}"
  fi
}

# _status_batch_get_blockers <epic_ids_file>
# Batch query blockers for multiple operations
# Input: file with epic_id per line
# Output: epic_id<tab>first_blocker_display per line
# Optimization: Uses wk list with label filters where possible
_status_batch_get_blockers() {
  local epic_ids_file="$1"

  # For now, iterate (future: batch wk command if available)
  while IFS= read -r epic_id; do
    [[ -z "${epic_id}" ]] && continue
    local display
    display=$(_status_get_blocker_display "${epic_id}")
    [[ -n "${display}" ]] && printf '%s\t%s\n' "${epic_id}" "${display}"
  done < "${epic_ids_file}"
}
```

**Verification**: Benchmark with 10+ operations to ensure acceptable latency.

---

### Phase 3: Update --after Flag to Accept Lists

**File**: `bin/v0-build`

Update argument parsing to accept comma-separated lists and merge multiple --after flags:

```bash
# Before (around line 87):
--after) AFTER="$2"; shift 2 ;;

# After:
--after)
  # Split comma-separated IDs and add to array
  IFS=',' read -ra ids <<< "$2"
  AFTER_OPS+=("${ids[@]}")
  shift 2
  ;;
--after=*)
  IFS=',' read -ra ids <<< "${1#--after=}"
  AFTER_OPS+=("${ids[@]}")
  shift
  ;;
```

Update validation (around line 129):

```bash
# Before:
if [[ -n "${AFTER}" ]]; then
  if [[ ! -f "${BUILD_DIR}/operations/${AFTER}/state.json" ]]; then
    ...

# After:
if [[ ${#AFTER_OPS[@]} -gt 0 ]]; then
  for after_op in "${AFTER_OPS[@]}"; do
    # Validate each operation exists (if it's an op name, not issue ID)
    if ! [[ "${after_op}" =~ ^${ISSUE_PREFIX}-[a-z0-9]+$ ]]; then
      if [[ ! -f "${BUILD_DIR}/operations/${after_op}/state.json" ]]; then
        echo "Error: Operation '${after_op}' does not exist"
        exit 1
      fi
    fi
  done
  # Check for circular dependencies (update to handle array)
  ...
fi
```

Update usage text:

```bash
--after <ops>   Wait for operations to complete before executing
                Accepts comma-separated list: --after auth,api
                Can be specified multiple times: --after auth --after api
```

**Verification**: Test `v0 build test --after a,b --after c` resolves to all three blockers.

---

### Phase 4: Update State Schema to v2

**File**: `packages/state/lib/rules.sh`

```bash
# Before:
SM_STATE_VERSION=1

# After:
SM_STATE_VERSION=2
```

**File**: `packages/state/lib/schema.sh`

Add migration logic:

```bash
sm_migrate_state() {
  local op="$1"
  local version
  version=$(sm_get_state_version "${op}")

  [[ "${version}" -ge "${SM_STATE_VERSION}" ]] && return 0

  # Migration from v0 (legacy) to v1
  if [[ "${version}" -eq 0 ]]; then
    sm_bulk_update_state "${op}" \
      "_schema_version" "1" \
      "_migrated_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    sm_emit_event "${op}" "schema:migrated" "v0 -> v1"
    version=1
  fi

  # Migration from v1 to v2: Remove after field, migrate to wok
  if [[ "${version}" -eq 1 ]]; then
    local state_file
    state_file=$(sm_get_state_file "${op}")

    # Read current after value before removing
    local after_op epic_id
    after_op=$(jq -r '.after // empty' "${state_file}")
    epic_id=$(jq -r '.epic_id // empty' "${state_file}")

    # If we have an after dependency and an epic_id, migrate to wok
    if [[ -n "${after_op}" ]] && [[ "${after_op}" != "null" ]] && \
       [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]]; then
      # Resolve after_op to wok ID
      local blocker_id
      blocker_id=$(v0_resolve_to_wok_id "${after_op}")

      if [[ -n "${blocker_id}" ]]; then
        # Add wok dependency (graceful failure)
        if wk dep "${epic_id}" blocked-by "${blocker_id}" 2>/dev/null; then
          sm_emit_event "${op}" "migration:dep_added" "Added wok dep: ${blocker_id}"
        else
          sm_emit_event "${op}" "migration:dep_failed" "Failed to add wok dep: ${blocker_id}"
        fi
      fi
    fi

    # Remove after, blocked_phase, eager fields from state
    local tmp
    tmp=$(mktemp)
    if jq 'del(.after, .blocked_phase, .eager) | ._schema_version = 2 | ._migrated_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
       "${state_file}" > "${tmp}"; then
      mv "${tmp}" "${state_file}"
    else
      rm -f "${tmp}"
    fi

    sm_emit_event "${op}" "schema:migrated" "v1 -> v2 (after field removed)"
  fi
}
```

**Verification**: Create v1 state file with `after` field, run migration, verify wok dep added and field removed.

---

### Phase 5: Rewrite Blocking Functions

**File**: `packages/state/lib/blocking.sh`

Replace state.json-based blocking with wok queries:

```bash
#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/blocking.sh - Dependency management via wok
#
# This module provides blocking checks that query wok
# instead of using local state.json fields.

# Requires: v0_get_first_open_blocker, v0_is_blocked from v0-common.sh
# Requires: sm_read_state from io.sh for epic_id lookup

# sm_is_blocked <op>
# Check if operation is blocked by any open dependencies in wok
sm_is_blocked() {
  local op="$1"
  local epic_id
  epic_id=$(sm_read_state "${op}" "epic_id")

  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return 1

  v0_is_blocked "${epic_id}"
}

# sm_get_blocker <op>
# Get the first open blocker operation/issue for display
# Returns operation name if resolvable, otherwise issue ID
sm_get_blocker() {
  local op="$1"
  local epic_id
  epic_id=$(sm_read_state "${op}" "epic_id")

  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return

  local blocker_id
  blocker_id=$(v0_get_first_open_blocker "${epic_id}")
  [[ -z "${blocker_id}" ]] && return

  # Try to resolve to operation name
  v0_blocker_to_op_name "${blocker_id}"
}

# sm_get_blocker_status <blocker>
# Get phase/status of the blocking operation or issue
sm_get_blocker_status() {
  local blocker="$1"

  # Try as operation name first
  local state_file="${BUILD_DIR}/operations/${blocker}/state.json"
  if [[ -f "${state_file}" ]]; then
    jq -r '.phase // "unknown"' "${state_file}"
    return
  fi

  # Try as wok issue ID
  local status
  status=$(wk show "${blocker}" -o json 2>/dev/null | jq -r '.status // "unknown"')
  echo "${status}"
}

# sm_is_blocker_merged <op>
# Check if all blockers have completed (done/closed in wok)
sm_is_blocker_merged() {
  local op="$1"
  local epic_id
  epic_id=$(sm_read_state "${op}" "epic_id")

  [[ -z "${epic_id}" ]] || [[ "${epic_id}" == "null" ]] && return 0

  # If no open blockers, then all are "merged"
  ! v0_is_blocked "${epic_id}"
}

# sm_find_dependents <op>
# Find operations waiting for the given operation
# Uses wok's blocking relationship queries
sm_find_dependents() {
  local merged_op="$1"
  local merged_epic_id
  merged_epic_id=$(sm_read_state "${merged_op}" "epic_id")

  [[ -z "${merged_epic_id}" ]] || [[ "${merged_epic_id}" == "null" ]] && return

  # Get issues that this one blocks
  local blocking_ids
  blocking_ids=$(wk show "${merged_epic_id}" -o json 2>/dev/null | jq -r '.blocking // [] | .[]')

  # Resolve each to operation name if possible
  for blocked_id in ${blocking_ids}; do
    local op_name
    op_name=$(v0_blocker_to_op_name "${blocked_id}")
    # Only return if it's a known operation
    if [[ -f "${BUILD_DIR}/operations/${op_name}/state.json" ]]; then
      echo "${op_name}"
    fi
  done
}

# sm_trigger_dependents <op>
# Notify dependent operations that blocker has merged
# (wok already tracks this via blocked-by relationships)
sm_trigger_dependents() {
  local merged_op="$1"

  # With wok-based tracking, dependents are automatically unblocked
  # when their blockers are marked done. Just log for visibility.
  local dep_op
  for dep_op in $(sm_find_dependents "${merged_op}"); do
    sm_emit_event "${dep_op}" "unblock:notified" "Blocker ${merged_op} completed"
  done
}

# REMOVED: sm_unblock_operation - no longer needed, wok tracks automatically
# REMOVED: sm_transition_to_blocked - blocked is not a separate phase now
```

**Verification**: Test that `sm_is_blocked` returns correct result for operations with wok dependencies.

---

### Phase 6: Remove Blocked Phase from Transitions

**File**: `packages/state/lib/transitions.sh`

Remove `sm_transition_to_blocked`:

```bash
# DELETE the entire sm_transition_to_blocked function (lines 115-132)
```

**File**: `packages/state/lib/rules.sh`

Update transition rules to remove blocked state:

```bash
# Before:
sm_allowed_transitions() {
  local phase="$1"
  case "${phase}" in
    init)          echo "planned blocked failed" ;;
    planned)       echo "queued executing blocked failed" ;;
    blocked)       echo "init planned queued" ;;
    queued)        echo "executing blocked failed" ;;
    ...

# After:
sm_allowed_transitions() {
  local phase="$1"
  case "${phase}" in
    init)          echo "planned failed" ;;
    planned)       echo "queued executing failed" ;;
    # blocked phase removed
    queued)        echo "executing failed" ;;
    ...
```

**Verification**: Ensure state machine tests pass without blocked phase.

---

### Phase 7: Update v0-status Display

**File**: `bin/v0-status`

Update the display logic to show first blocker from wok:

```bash
# In the jq processing section, add epic_id to output fields
# Around line 524, after epic_id field extraction...

# Replace after_icon logic (around line 339-348):
# OLD: Read after from state.json
# NEW: Query wok for first blocker

# After reading state fields, add blocker lookup:
blocker_display=""
if [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]]; then
  # Use optimized helper (single wk call)
  blocker_display=$(_status_get_blocker_display "${epic_id}")
fi

# Update after_icon display:
after_icon=""
if [[ -n "${blocker_display}" ]]; then
  case "${phase}" in
    executing|completed|pending_merge|merged|cancelled)
      # Don't show blocker for these phases
      ;;
    *)
      after_icon=" ${C_YELLOW}[after ${blocker_display}]${C_RESET}"
      ;;
  esac
fi
```

**Performance optimization**: For the list view, avoid N+1 wk calls:

```bash
# Pre-fetch epic_ids and batch query (if wk supports batch in future)
# For now, use lazy loading - only query wok if operation has epic_id

# Add to source section at top:
source "${V0_DIR}/packages/status/lib/blocker-display.sh"
```

**Verification**: Run `time v0 status` before and after, ensure <2s for 20 operations.

---

### Phase 8: Update v0-build and v0-build-worker

**File**: `bin/v0-build`

Replace `--after` handling to use wok-only dependencies:

```bash
# Initialize array instead of single value
AFTER_OPS=()

# Update arg parsing (see Phase 3)

# Remove eager flag handling (no longer relevant)
# EAGER flag DELETE

# Update dependency setup (around line 540):
# After epic_id is set, add all blockers to wok:
if [[ ${#AFTER_OPS[@]} -gt 0 ]] && [[ -n "${FEATURE_ID}" ]]; then
  local resolved_ids=()
  for after_op in "${AFTER_OPS[@]}"; do
    local resolved
    if resolved=$(v0_resolve_to_wok_id "${after_op}"); then
      resolved_ids+=("${resolved}")
    else
      echo "Warning: Could not resolve '${after_op}' to wok ID (skipping)"
    fi
  done

  if [[ ${#resolved_ids[@]} -gt 0 ]]; then
    if wk dep "${FEATURE_ID}" blocked-by "${resolved_ids[@]}" 2>/dev/null; then
      emit_event "dep:added" "Added blocked-by: ${resolved_ids[*]}"
    else
      emit_event "dep:failed" "Failed to add blocked-by dependencies"
    fi
  fi
fi

# REMOVE: update_state "after" logic
# REMOVE: update_state "eager" logic
# REMOVE: blocked phase transitions
```

**File**: `bin/v0-build-worker`

Similar updates:

```bash
# Remove after/eager from state operations
# Remove blocked phase handling
# Keep wk dep call for adding dependencies

# Update check_for_unblock (if exists) to use wk ready instead of state.json
```

**Verification**: Test `v0 build foo "Test" --after bar,baz` creates wok dependencies.

---

### Phase 9: Update Tests

**File**: `packages/state/tests/blocking.bats` (update or create)

```bash
#!/usr/bin/env bats
# Test blocking functions with wok

load '../../test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  setup_mock_wk
}

@test "sm_is_blocked returns true when wok has open blockers" {
  # Mock wk show to return blocker
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"], "status": "todo"}'
  mock_wk_show "v0-blocker1" '{"status": "in_progress"}'

  # Create operation with epic_id
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocked "test-op"
  assert_success
}

@test "sm_is_blocked returns false when blockers are done" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"], "status": "todo"}'
  mock_wk_show "v0-blocker1" '{"status": "done"}'

  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_get_blocker returns operation name when available" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "todo", "labels": ["plan:auth-feature"]}'

  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output "auth-feature"
}

@test "sm_get_blocker returns issue ID when no plan label" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "todo", "labels": []}'

  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output "v0-blocker1"
}
```

**File**: `tests/v0-build.bats`

Add tests for comma-separated --after:

```bash
@test "build --after accepts comma-separated list" {
  setup_mock_wk
  create_operation_state "blocker1" "merged" "v0-b1"
  create_operation_state "blocker2" "merged" "v0-b2"

  run "${V0_BUILD}" test-op "Test" --after blocker1,blocker2 --dry-run
  assert_success
  # Verify wk dep called with both blockers
}

@test "build --after merges multiple flags" {
  setup_mock_wk
  create_operation_state "a" "merged" "v0-a"
  create_operation_state "b" "merged" "v0-b"
  create_operation_state "c" "merged" "v0-c"

  run "${V0_BUILD}" test-op "Test" --after a,b --after c --dry-run
  assert_success
  # Should have all three blockers
}
```

**Verification**: `scripts/test state blocking v0-build`

---

### Phase 10: Update Documentation

**File**: `docs/arch/operations/state.md`

Update state diagram to remove blocked phase:

```mermaid
flowchart TD
    start((start)) --> init
    init[init] -->|plan created| planned
    planned[planned] -->|issue filed| queued
    queued[queued] -->|agent launched| executing
    # ... remove blocked transitions ...
```

Update state schema to show v2 without after/blocked_phase/eager fields.

Add section on wok-based dependency tracking:

```markdown
## Dependency Tracking (v2+)

Starting with schema v2, operation dependencies are tracked exclusively
in wok using `blocked-by` relationships:

```bash
# Add dependency when creating operation
wk dep <epic_id> blocked-by <blocker_id>

# Check if operation is blocked
wk show <epic_id> -o json | jq '.blockers'

# Operations are unblocked when blockers reach done/closed status
wk ready --label plan:<name>  # Shows if unblocked
```

The `after`, `blocked_phase`, and `eager` fields have been removed from
state.json. Migration from v1 automatically adds wok dependencies.
```

**Verification**: Review docs for accuracy.

---

## Key Implementation Details

### Performance Considerations

The main risk is `v0 status` becoming slow due to wok queries. Mitigations:

1. **Lazy loading**: Only query wok if operation has `epic_id`
2. **Single call per op**: Use `wk show -o json` once to get blockers + first blocker status
3. **Early termination**: Stop at first open blocker, don't enumerate all
4. **Caching**: Consider file-based cache with short TTL for list view

Target: `v0 status` should complete in <2s for 20 operations.

### Migration Safety

1. **Graceful failure**: If wk dep fails during migration, log warning but continue
2. **Idempotent**: Re-running migration should be safe (wk dep is idempotent)
3. **Rollback path**: Keep v1 state files backed up until v2 is stable

### --after Behavior Changes

| Aspect | Before (v1) | After (v2) |
|--------|-------------|------------|
| Storage | state.json `after` field | wok `blocked-by` |
| Multiple deps | Single operation only | Multiple via comma or repeated flag |
| Eager mode | `--eager` flag for plan-first | Removed (always proceed with planning) |
| Blocked phase | Explicit `blocked` state | No separate phase; checked via wok |
| Unblock trigger | State machine transition | Automatic when blocker done in wok |

### Issue ID vs Operation Name Resolution

The display logic should:
1. Query wok for blocker issue IDs
2. Check each blocker's labels for `plan:<name>` pattern
3. If found, display operation name; otherwise display issue ID
4. This allows mixed dependencies (operations and standalone issues)

## Verification Plan

1. **Unit tests**:
   - `packages/state/tests/blocking.bats` - wok query helpers
   - `packages/state/tests/schema.bats` - v1->v2 migration

2. **Integration tests**:
   - `tests/v0-build.bats` - --after flag variations
   - `tests/v0-status.bats` - blocker display

3. **Manual verification**:
   ```bash
   # Create operation with dependency
   v0 build auth "Add auth"
   v0 build api "Build API" --after auth

   # Check wok has dependency
   wk show $(jq -r .epic_id ~/.v0/v0/operations/api/state.json) -o json | jq .blockers

   # Verify v0 status shows blocker
   v0 status  # Should show api with [after auth]

   # Complete auth, verify api unblocked
   wk done $(jq -r .epic_id ~/.v0/v0/operations/auth/state.json)
   v0 status  # api should no longer show [after auth]
   ```

4. **Performance benchmark**:
   ```bash
   time v0 status  # With 20+ operations, should be <2s
   ```

5. **Migration test**:
   ```bash
   # Create v1 state file with after field
   # Run any v0 command that reads state
   # Verify wok dep added and field removed
   ```
