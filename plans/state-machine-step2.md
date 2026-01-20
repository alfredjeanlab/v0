# State Machine Integration Plan

**Root Feature:** `v0-8096` (follows state-machine.md)

## Overview

Complete the migration of v0's operation state management to use the centralized `lib/state-machine.sh` library. The library was created in commit 0655061, but the CLI scripts still use inline state transitions. This plan covers the remaining integration work.

**Completed (0655061):**
- Phase 1: `lib/state-machine.sh` created with all core functions
- Phase 6: Comprehensive tests in `tests/unit/state-machine.bats`
- Backward compatibility via deprecated wrappers in `v0-common.sh`

**Remaining:**
- Phase 0: Schema versioning and log rotation infrastructure
- Phase 1: Migrate `v0-feature` and `v0-feature-worker`
- Phase 2: Integrate merge queue improvements into `v0-mergeq`
- Phase 3: Consolidate status display in `v0-status`
- Phase 4: Refactor hold logic in `v0-hold`
- Phase 5: Remove deprecated wrappers from `v0-common.sh`

## Project Structure

```
bin/
├── v0-feature              # MODIFY: Replace inline transitions with sm_* calls
├── v0-feature-worker       # MODIFY: Use sm_* for state updates
├── v0-mergeq               # MODIFY: Use sm_is_merge_ready, sm_merge_ready_reason
├── v0-merge                # MODIFY: Use sm_read_state for status display
├── v0-status               # MODIFY: Use sm_get_display_status, sm_is_active_operation
├── v0-hold                 # MODIFY: Use sm_set_hold, sm_clear_hold
├── v0-prune                # MODIFY: Use sm_read_state, sm_is_terminal_phase
├── v0-cancel               # MODIFY: Use sm_read_state, sm_transition_to_cancelled
├── v0-attach               # MODIFY: Use sm_read_state for phase checks
└── v0-self-debug           # MODIFY: Use sm_read_state for diagnostics

lib/
├── state-machine.sh        # MODIFY: Add schema versioning and log rotation
└── v0-common.sh            # EXISTS: Deprecated wrappers (remove after migration)

tests/unit/
├── state-machine.bats      # MODIFY: Add tests for schema migration and log rotation
├── v0-feature-state.bats   # MODIFY: Update to verify sm_* usage
└── v0-status.bats          # MODIFY: Update for new status format
```

## Dependencies

No new dependencies. Uses existing `lib/state-machine.sh`.

## Implementation Phases

### Phase 0: Schema Versioning and Log Rotation

**Goal:** Add infrastructure for forward compatibility and operational hygiene

**Files to modify:**
- `lib/state-machine.sh`

#### Schema Versioning

Add version field to state.json for detecting and migrating old formats:

```bash
# Current schema version
SM_STATE_VERSION=1

# sm_get_state_version <op>
# Get schema version from state file (defaults to 0 for legacy files)
sm_get_state_version() {
  local op="$1"
  local version
  version=$(sm_read_state "${op}" "_schema_version")
  echo "${version:-0}"
}

# sm_migrate_state <op>
# Migrate state file to current schema version
sm_migrate_state() {
  local op="$1"
  local version
  version=$(sm_get_state_version "${op}")

  # Already current
  [[ "${version}" -ge "${SM_STATE_VERSION}" ]] && return 0

  # Migration from v0 (legacy) to v1
  if [[ "${version}" -eq 0 ]]; then
    sm_bulk_update_state "${op}" \
      "_schema_version" "${SM_STATE_VERSION}" \
      "_migrated_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    sm_emit_event "${op}" "schema:migrated" "v0 -> v${SM_STATE_VERSION}"
  fi

  # Future migrations: v1 -> v2, etc.
  # if [[ "${version}" -eq 1 ]]; then
  #   # migrate v1 -> v2
  # fi
}

# sm_ensure_current_schema <op>
# Called by transition functions to auto-migrate on first access
sm_ensure_current_schema() {
  local op="$1"
  local version
  version=$(sm_get_state_version "${op}")
  if [[ "${version}" -lt "${SM_STATE_VERSION}" ]]; then
    sm_migrate_state "${op}"
  fi
}
```

**State file format (v1):**
```json
{
  "_schema_version": 1,
  "name": "my-feature",
  "phase": "executing",
  "prompt": "Add feature X",
  ...
}
```

**Integration:**
- Add `sm_ensure_current_schema` call to `sm_get_phase()` for lazy migration
- All existing state files (v0) will be migrated on first read
- New state files include `_schema_version: 1` from creation

#### Log Rotation

Add rotation to prevent unbounded event log growth:

```bash
# Maximum log file size before rotation (100KB)
SM_LOG_MAX_SIZE=102400
# Number of rotated logs to keep
SM_LOG_KEEP_COUNT=3

# sm_emit_event <op> <event> [details]
# Log an event with automatic rotation
sm_emit_event() {
  local op="$1"
  local event="$2"
  local details="${3:-}"
  local log_dir="${BUILD_DIR}/operations/${op}/logs"
  local log_file="${log_dir}/events.log"

  mkdir -p "${log_dir}"

  # Rotate if needed
  if [[ -f "${log_file}" ]]; then
    local size
    size=$(stat -f%z "${log_file}" 2>/dev/null || stat -c%s "${log_file}" 2>/dev/null || echo 0)
    if [[ "${size}" -gt "${SM_LOG_MAX_SIZE}" ]]; then
      sm_rotate_log "${log_file}"
    fi
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${event}: ${details}" >> "${log_file}"
}

# sm_rotate_log <log_file>
# Rotate log files: events.log -> events.log.1 -> events.log.2 -> ...
sm_rotate_log() {
  local log_file="$1"
  local i

  # Remove oldest if at limit
  rm -f "${log_file}.${SM_LOG_KEEP_COUNT}"

  # Shift existing rotated logs
  for ((i = SM_LOG_KEEP_COUNT - 1; i >= 1; i--)); do
    [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i + 1))"
  done

  # Rotate current log
  mv "${log_file}" "${log_file}.1"
}
```

**Log structure after rotation:**
```
logs/
├── events.log      # Current (newest)
├── events.log.1    # Previous
├── events.log.2    # Older
└── events.log.3    # Oldest (deleted when events.log.4 would be created)
```

#### Performance: Batch State Reads

Each `sm_read_state()` call spawns a jq subprocess. Functions like `sm_is_merge_ready()` make 4+ separate reads. For `v0 status` listing 20 operations with 3-5 reads each, this means 60-100 subprocess spawns.

Add batch read functions to minimize subprocess overhead:

```bash
# sm_read_state_fields <op> <field1> [field2] [field3] ...
# Read multiple fields in a single jq invocation
# Returns tab-separated values in order requested
sm_read_state_fields() {
  local op="$1"
  shift
  local state_file
  state_file=$(sm_get_state_file "${op}")

  [[ ! -f "${state_file}" ]] && return 1

  # Build jq filter: [.field1, .field2, ...] | @tsv
  local fields=()
  for field in "$@"; do
    fields+=(".${field} // empty")
  done
  local filter
  filter="[$(IFS=,; echo "${fields[*]}")] | @tsv"

  jq -r "${filter}" "${state_file}"
}

# sm_read_all_state <op>
# Read entire state file as associative array (bash 4+)
# Usage: declare -A state; sm_read_all_state "op" state
sm_read_all_state() {
  local op="$1"
  local -n _state_ref="$2"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  [[ ! -f "${state_file}" ]] && return 1

  # Read all key-value pairs
  while IFS=$'\t' read -r key value; do
    _state_ref["${key}"]="${value}"
  done < <(jq -r 'to_entries | .[] | [.key, (.value | tostring)] | @tsv' "${state_file}")
}
```

**Optimized usage in status-heavy code:**
```bash
# Before: 5 jq calls
phase=$(sm_read_state "${op}" "phase")
merge_status=$(sm_read_state "${op}" "merge_status")
held=$(sm_read_state "${op}" "held")
session=$(sm_read_state "${op}" "tmux_session")
worktree=$(sm_read_state "${op}" "worktree")

# After: 1 jq call
IFS=$'\t' read -r phase merge_status held session worktree <<< \
  "$(sm_read_state_fields "${op}" phase merge_status held tmux_session worktree)"
```

**Verification:**
- [ ] Legacy state files (without `_schema_version`) are migrated on first access
- [ ] New state files include `_schema_version: 1`
- [ ] Event logs rotate at 100KB
- [ ] Only 3 rotated logs are kept
- [ ] `sm_read_state_fields` returns correct tab-separated values
- [ ] `v0 status` with 20 operations completes in <500ms
- [ ] Tests added: `tests/unit/state-machine.bats` for migration, rotation, and batch reads

---

### Phase 1: Migrate Feature Execution Scripts

**Goal:** Replace inline state transitions in feature execution scripts with library calls

**Files to modify:**
- `bin/v0-feature`
- `bin/v0-feature-worker`
- `bin/v0-attach`

**Changes to v0-feature:**

1. **Replace update_state calls with transitions:**
```bash
# Before
update_state "phase" '"planned"'
emit_event "plan:created" "..."

# After
sm_transition_to_planned "${NAME}" "${PLANS_DIR}/${NAME}.md"
```

2. **Replace inline blocked logic:**
```bash
# Before
if [[ -n "${AFTER}" ]]; then
  update_state "phase" '"blocked"'
  update_state "after" "\"${AFTER}\""
  update_state "blocked_phase" "\"${RESUME_PHASE}\""
fi

# After
if [[ -n "${AFTER}" ]]; then
  sm_transition_to_blocked "${NAME}" "${AFTER}" "${RESUME_PHASE}"
fi
```

3. **Replace resume logic:**
```bash
# Before
if [[ "${PHASE}" = "failed" ]]; then
  # Complex inline logic
fi

# After
RESUME_PHASE=$(sm_get_resume_phase "${NAME}")
sm_clear_error_state "${NAME}"
```

4. **Simplify on-complete.sh generation:**
```bash
# Generated script should call:
sm_transition_to_completed "${OP_NAME}"
if sm_should_auto_merge "${OP_NAME}"; then
  sm_transition_to_pending_merge "${OP_NAME}"
  v0-mergeq --enqueue "${OP_NAME}"
fi
```

**Changes to v0-feature-worker:**

1. **Use sm_transition_to_executing:**
```bash
# Before
update_state "phase" '"executing"'
update_state "tmux_session" "\"${SESSION}\""

# After
sm_transition_to_executing "${NAME}" "${SESSION}"
```

2. **Use sm_exit_if_held:**
```bash
# Before
if v0_is_held "${NAME}"; then
  echo "Operation on hold..."
  exit 0
fi

# After
sm_exit_if_held "${NAME}" "feature-worker"
```

**Changes to v0-attach:**

1. **Use sm_read_state for phase checks:**
```bash
# Before (line 132)
PHASE=$(jq -r '.phase // "init"' "${STATE_FILE}")

# After
PHASE=$(sm_get_phase "${NAME}")
[[ -z "${PHASE}" ]] && PHASE="init"
```

**Verification:**
- [ ] `v0 feature test --dry-run` shows expected transitions
- [ ] `make test-file FILE=tests/unit/v0-feature.bats` passes
- [ ] Manual test: `v0 feature foo "test" --foreground` completes full cycle
- [ ] `v0 attach <name>` correctly reads operation state

---

### Phase 2: Integrate Merge Scripts with State Machine

**Goal:** Use state machine merge readiness functions in merge-related scripts

**Files to modify:**
- `bin/v0-mergeq`
- `bin/v0-merge`

**Changes to v0-mergeq:**

1. **Replace inline readiness checks:**
```bash
# Before (scattered checks)
if [[ "${phase}" != "completed" ]] && [[ "${phase}" != "pending_merge" ]]; then
  continue
fi
# ... check worktree ...
# ... check tmux session ...
# ... check issues ...

# After
if ! sm_is_merge_ready "${op}"; then
  local reason=$(sm_merge_ready_reason "${op}")
  log_debug "Skipping ${op}: ${reason}"
  continue
fi
```

2. **Improve error reporting:**
```bash
# When merge blocked, show why
reason=$(sm_merge_ready_reason "${op}")
case "${reason}" in
  phase:*)       echo "Not ready: still in ${reason#phase:}" ;;
  worktree:*)    echo "Not ready: worktree missing" ;;
  session:*)     echo "Not ready: tmux session still active" ;;
  open_issues:*) echo "Not ready: ${reason#open_issues:} issues remaining" ;;
esac
```

3. **Use state transitions for merge status:**
```bash
# Before
update_state "merge_status" '"merged"'

# After
sm_transition_to_merged "${op}"
# or on conflict:
sm_transition_to_conflict "${op}"
```

4. **Trigger dependents after merge:**
```bash
# After successful merge
sm_trigger_dependents "${op}"
```

**Changes to v0-merge:**

1. **Use sm_read_state for status display:**
```bash
# Before (line 214)
$(jq -r '"  Phase: \(.phase // "unknown")\n  Epic: \(.epic_id // "none")"' "${op_state_file}" ...)

# After
phase=$(sm_read_state "${op}" "phase")
epic_id=$(sm_read_state "${op}" "epic_id")
echo "  Phase: ${phase:-unknown}"
echo "  Epic: ${epic_id:-none}"
```

**Verification:**
- [ ] Merge queue handles incomplete work correctly
- [ ] `v0 status --merge` shows detailed blocking reasons
- [ ] Dependent operations unblock after merge
- [ ] `v0 merge <name>` shows correct operation status

---

### Phase 3: Consolidate Status Display and Prune Logic

**Goal:** Unify status display and terminal state checks using state machine functions

**Files to modify:**
- `bin/v0-status`
- `bin/v0-prune`
- `bin/v0-self-debug`

**Changes to v0-status:**

1. **Replace inline status formatting:**
```bash
# Before (100+ lines of case statements)
case "${phase}" in
  init)
    if tmux has-session ...; then
      status="new [planning]"
    else
      status="new"
    fi
    ;;
  # ... many more cases ...
esac

# After
IFS='|' read -r display_status color icon <<< "$(sm_get_display_status "${op}")"
printf "  %-20s %s%s\n" "${name}:" "${display_status}" "${icon}"
```

2. **Use sm_is_active_operation for filtering:**
```bash
# Default view shows only active operations
for state_file in "${BUILD_DIR}"/operations/*/state.json; do
  op=$(basename "$(dirname "${state_file}")")
  if sm_is_active_operation "${op}"; then
    show_operation "${op}"
  fi
done

# With --all flag, show everything
```

3. **Use sm_get_status_color for consistent coloring:**
```bash
IFS='|' read -r status color icon <<< "$(sm_get_display_status "${op}")"
if [[ -n "${color}" ]]; then
  printf "%b%s%b" "$(sm_get_status_color "${color}")" "${status}" "${C_RESET}"
else
  printf "%s" "${status}"
fi
```

4. **Use batch reads for performance (optional optimization):**
```bash
# If sm_get_display_status becomes a bottleneck, inline with batch reads:
IFS=$'\t' read -r phase merge_status held tmux_session after <<< \
  "$(sm_read_state_fields "${op}" phase merge_status held tmux_session after)"
# Then compute display status inline using local variables
```

**Changes to v0-prune:**

1. **Replace inline phase checks with state machine functions:**
```bash
# Before (lines 112-125 in v0-prune)
phase=$(jq -r '.phase' "${state_file}")
merge_status=$(jq -r '.merge_status // empty' "${state_file}")
should_prune=""

if [[ "${phase}" = "cancelled" ]]; then
  should_prune=1
elif [[ "${phase}" = "merged" ]]; then
  should_prune=1
elif [[ "${phase}" = "completed" ]] || [[ "${phase}" = "pending_merge" ]]; then
  if [[ "${merge_status}" = "merged" ]]; then
    should_prune=1
  fi
fi

# After
if ! sm_is_active_operation "${name}"; then
  # Operation is in terminal state (merged or cancelled)
  should_prune=1
fi
```

2. **Use sm_read_state for session checks:**
```bash
# Before
session=$(jq -r '.tmux_session // empty' "${state_file}")
machine=$(jq -r '.machine // empty' "${state_file}")

# After
session=$(sm_read_state "${name}" "tmux_session")
machine=$(sm_read_state "${name}" "machine")
```

**Changes to v0-self-debug:**

1. **Use sm_read_state for diagnostic output:**
```bash
# Before (lines 189, 511)
phase=$(jq -r '.phase // "unknown"' "${state_file}")

# After
phase=$(sm_get_phase "${op}")
[[ -z "${phase}" ]] && phase="unknown"
```

**Verification:**
- [ ] `v0 status` output matches previous format
- [ ] Colors are consistent across all status types
- [ ] `--all` flag shows merged/cancelled operations
- [ ] `v0 prune` correctly identifies terminal state operations
- [ ] `v0 prune --dry-run` shows expected operations
- [ ] `v0 self-debug` shows correct operation phases

---

### Phase 4: Refactor Hold and Cancel Logic

**Goal:** Consolidate hold and cancel operations using state machine functions

**Files to modify:**
- `bin/v0-hold`
- `bin/v0-cancel`
- `bin/v0-resume` (if separate)

**Changes to v0-hold:**

1. **Use sm_set_hold and sm_clear_hold:**
```bash
# In v0-hold
case "${ACTION}" in
  hold)
    sm_set_hold "${NAME}"
    echo "Operation '${NAME}' is now on hold"
    ;;
  resume)
    sm_clear_hold "${NAME}"
    echo "Hold released for '${NAME}'"
    # Check if should auto-resume
    if ! sm_is_blocked "${NAME}"; then
      v0-feature "${NAME}" --resume &
    fi
    ;;
esac
```

2. **Show hold status with reason:**
```bash
if sm_is_held "${NAME}"; then
  held_at=$(sm_read_state "${NAME}" "held_at")
  echo "Operation '${NAME}' has been on hold since ${held_at}"
fi
```

**Changes to v0-cancel:**

1. **Use sm_read_state and add sm_transition_to_cancelled:**
```bash
# Before (line 72)
phase=$(jq -r '.phase' "${STATE_FILE}")

# After
phase=$(sm_get_phase "${NAME}")
```

2. **Add transition function (in state-machine.sh):**
```bash
# sm_transition_to_cancelled <op>
# Transition operation to cancelled state
sm_transition_to_cancelled() {
  local op="$1"

  # Cancelled is allowed from any non-terminal state
  local phase
  phase=$(sm_get_phase "${op}")
  if sm_is_terminal_phase "${phase}"; then
    echo "Error: Cannot cancel operation in terminal state '${phase}'" >&2
    return 1
  fi

  _sm_do_transition "${op}" "cancelled" "operation:cancelled" "" \
    "cancelled_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
}
```

**Verification:**
- [ ] `v0 hold foo` + `v0 resume foo` works correctly
- [ ] Held operations don't auto-start when dependency merges
- [ ] Status shows hold time
- [ ] `v0 cancel <name>` transitions to cancelled state
- [ ] Cancel is rejected for already-merged operations

---

### Phase 5: Remove Deprecated Wrappers

**Goal:** Clean up v0-common.sh after migration complete

**Files to modify:**
- `lib/v0-common.sh`

**Changes:**

Remove the deprecated wrapper functions after all scripts are migrated:
- `v0_find_dependent_operations()` → use `sm_find_dependents()`
- `v0_trigger_dependent_operations()` → use `sm_trigger_dependents()`
- `v0_is_held()` → use `sm_is_held()`
- `v0_exit_if_held()` → use `sm_exit_if_held()`

**Verification:**
- [ ] `grep -r "v0_is_held\|v0_exit_if_held\|v0_find_dependent\|v0_trigger_dependent" bin/` returns nothing
- [ ] `make test` passes
- [ ] `make lint` passes

---

## Key Implementation Details

### Preserving Backward Compatibility

During migration, both old and new patterns will work:
- Old: `v0_is_held()` delegates to `sm_is_held()`
- New: Call `sm_is_held()` directly

This allows incremental migration without breaking existing functionality.

### Event Log Format

All transitions emit events to `${BUILD_DIR}/operations/${op}/logs/events.log`:
```
[2026-01-19T12:00:00Z] plan:created: plans/foo.md
[2026-01-19T12:01:00Z] work:queued: Issues created
[2026-01-19T12:02:00Z] agent:launched: tmux session v0-foo
```

### Error Handling

Transition functions return non-zero on invalid transitions:
```bash
if ! sm_transition_to_planned "${NAME}" "${PLAN_FILE}"; then
  echo "Error: Cannot transition to planned state" >&2
  exit 1
fi
```

## Verification Plan

### Unit Tests
```bash
make test-file FILE=tests/unit/v0-feature.bats
make test-file FILE=tests/unit/v0-status.bats
make test-file FILE=tests/unit/state-machine.bats
```

### Integration Tests (Manual)

1. **Full feature cycle:**
```bash
v0 feature test-sm "Test state machine" --foreground
# Should complete plan -> decompose -> execute -> merge
```

2. **Blocking flow:**
```bash
v0 feature parent "Parent feature"
v0 feature child "Child feature" --after parent
# Child should block until parent merges
```

3. **Hold/resume flow:**
```bash
v0 feature held-test "Test hold"
v0 hold held-test
# Should stop after current work
v0 resume held-test
# Should continue
```

### Regression Tests
- All existing tests in `tests/unit/` must pass
- `make lint` must pass
- `make check` must pass
