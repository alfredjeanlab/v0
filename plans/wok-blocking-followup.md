# Plan: Wok Blocking Migration Followup

Address gaps from the initial wok-blocking-migration implementation.

## Issues to Fix

1. **Missing unit tests** - `packages/state/tests/blocking.bats` not created
2. **Style issue** - `local` used outside function in v0-status:354
3. **Display inconsistency** - `_status_get_blocker_display` returns empty if first blocker is closed, even when subsequent blockers are open

## Phase 1: Add Unit Tests for Blocking Helpers

**File**: `packages/state/tests/blocking.bats` (NEW)

Test the blocking functions in `packages/state/lib/blocking.sh` that wrap the v0-common.sh helpers.

```bash
#!/usr/bin/env bats
# blocking.bats - Unit tests for blocking.sh functions

load '../../test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  source_lib "blocking.sh"
}

@test "sm_is_blocked returns false when no epic_id" {
  create_operation_state "test-op" "queued"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_is_blocked returns false when epic_id is null" {
  create_operation_state "test-op" "queued" "null"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_is_blocked returns true when wok has open blockers" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"], "status": "todo"}'
  mock_wk_show "v0-blocker1" '{"status": "in_progress"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocked "test-op"
  assert_success
}

@test "sm_is_blocked returns false when all blockers done" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"], "status": "todo"}'
  mock_wk_show "v0-blocker1" '{"status": "done"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_get_blocker returns empty when no blockers" {
  mock_wk_show "v0-epic123" '{"blockers": [], "status": "todo"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output ""
}

@test "sm_get_blocker returns operation name when plan label exists" {
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

@test "sm_get_blocker skips closed blockers" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-closed", "v0-open"]}'
  mock_wk_show "v0-closed" '{"status": "done", "labels": []}'
  mock_wk_show "v0-open" '{"status": "todo", "labels": ["plan:real-blocker"]}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output "real-blocker"
}

@test "sm_is_blocker_merged returns true when no epic_id" {
  create_operation_state "test-op" "queued"

  run sm_is_blocker_merged "test-op"
  assert_success
}

@test "sm_is_blocker_merged returns true when no open blockers" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "done"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocker_merged "test-op"
  assert_success
}

@test "sm_is_blocker_merged returns false when open blockers exist" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "in_progress"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocker_merged "test-op"
  assert_failure
}

@test "sm_find_dependents returns operations blocked by given op" {
  # merged-op blocks dependent-op
  mock_wk_show "v0-merged" '{"blocking": ["v0-dependent"]}'
  mock_wk_show "v0-dependent" '{"labels": ["plan:dependent-op"]}'
  create_operation_state "merged-op" "merged" "v0-merged"
  create_operation_state "dependent-op" "queued" "v0-dependent"

  run sm_find_dependents "merged-op"
  assert_success
  assert_output "dependent-op"
}

@test "sm_find_dependents ignores non-operation issues" {
  mock_wk_show "v0-merged" '{"blocking": ["v0-random-issue"]}'
  mock_wk_show "v0-random-issue" '{"labels": []}'
  create_operation_state "merged-op" "merged" "v0-merged"

  run sm_find_dependents "merged-op"
  assert_success
  assert_output ""
}
```

**File**: `packages/test-support/helpers/test_helper.bash`

Add helper functions for mocking wk:

```bash
# mock_wk_show <issue_id> <json_response>
# Set up mock response for wk show <issue_id> -o json
mock_wk_show() {
  local issue_id="$1"
  local response="$2"

  mkdir -p "${MOCK_DATA_DIR}/wk"
  echo "${response}" > "${MOCK_DATA_DIR}/wk/${issue_id}.json"
}

# create_operation_state <name> <phase> [epic_id]
# Create a minimal state.json for testing
create_operation_state() {
  local name="$1"
  local phase="$2"
  local epic_id="${3:-}"

  local op_dir="${BUILD_DIR}/operations/${name}"
  mkdir -p "${op_dir}"

  local epic_json="null"
  [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]] && epic_json="\"${epic_id}\""

  cat > "${op_dir}/state.json" <<EOF
{
  "name": "${name}",
  "phase": "${phase}",
  "epic_id": ${epic_json},
  "_schema_version": 2
}
EOF
}
```

Also need mock `wk` script that reads from MOCK_DATA_DIR:

```bash
# In mock wk script
if [[ "$1" == "show" ]] && [[ "$3" == "-o" ]] && [[ "$4" == "json" ]]; then
  issue_id="$2"
  mock_file="${MOCK_DATA_DIR}/wk/${issue_id}.json"
  if [[ -f "${mock_file}" ]]; then
    cat "${mock_file}"
    exit 0
  fi
  echo '{}'
  exit 0
fi
```

**Verification**: `scripts/test state`

---

## Phase 2: Fix `local` Outside Function

**File**: `bin/v0-status`

Around line 354, `local blocker_display` is used inside a while loop in the main script body. Remove `local` since it has no effect outside functions.

```bash
# Before (line 354):
          local blocker_display
          blocker_display=$(_status_get_blocker_display "${epic_id}")

# After:
          blocker_display=$(_status_get_blocker_display "${epic_id}")
```

The variable is already scoped to the loop iteration and gets overwritten each time, so this is safe.

**Verification**: `shellcheck bin/v0-status`

---

## Phase 3: Fix Display Inconsistency

**Issue**: `_status_get_blocker_display` returns empty if the first blocker is done/closed, even when subsequent blockers are still open. This creates inconsistent behavior where an operation could appear unblocked in `v0 status` while the worker is actually paused.

**File**: `packages/status/lib/blocker-display.sh`

Update `_status_get_blocker_display` to iterate through blockers:

```bash
# Before (lines 24-42):
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

# After:
  # Check each blocker until we find an open one
  local blocker_id
  for blocker_id in $(echo "${blockers}" | jq -r '.[]'); do
    local blocker_json
    blocker_json=$(wk show "${blocker_id}" -o json 2>/dev/null) || {
      # wk failed, assume blocker is open
      echo "${blocker_id}"
      return
    }

    local status
    status=$(echo "${blocker_json}" | jq -r '.status // "unknown"')
    case "${status}" in
      done|closed)
        # This blocker is resolved, check next
        continue
        ;;
    esac

    # Found an open blocker - resolve to op name and return
    local plan_label
    plan_label=$(echo "${blocker_json}" | jq -r '.labels // [] | .[] | select(startswith("plan:"))' | head -1)

    if [[ -n "${plan_label}" ]]; then
      echo "${plan_label#plan:}"
    else
      echo "${blocker_id}"
    fi
    return
  done

  # All blockers resolved
  return
```

This aligns with `v0_get_first_open_blocker` in v0-common.sh which already iterates.

**Performance note**: Worst case adds N-1 extra wk calls where N = number of resolved blockers. In practice, resolved blockers at the front of the list should be rare since wok typically orders by recency.

**Verification**: Manual test with operation that has multiple blockers where first is done.

---

## Phase 4: Add Tests for Display Helper

**File**: `packages/status/tests/blocker-display.bats` (NEW)

```bash
#!/usr/bin/env bats
# blocker-display.bats - Tests for blocker display helper

load '../../test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  source "${V0_DIR}/packages/status/lib/blocker-display.sh"
}

@test "_status_get_blocker_display returns empty for no epic_id" {
  run _status_get_blocker_display ""
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display returns empty for null epic_id" {
  run _status_get_blocker_display "null"
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display returns op name for open blocker" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-blocker"]}'
  mock_wk_show "v0-blocker" '{"status": "todo", "labels": ["plan:auth"]}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "auth"
}

@test "_status_get_blocker_display skips closed blockers" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-closed", "v0-open"]}'
  mock_wk_show "v0-closed" '{"status": "done", "labels": ["plan:done-op"]}'
  mock_wk_show "v0-open" '{"status": "todo", "labels": ["plan:real-blocker"]}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "real-blocker"
}

@test "_status_get_blocker_display returns empty when all blockers resolved" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-done1", "v0-done2"]}'
  mock_wk_show "v0-done1" '{"status": "done", "labels": []}'
  mock_wk_show "v0-done2" '{"status": "closed", "labels": []}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display returns issue ID when no plan label" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-ext-issue"]}'
  mock_wk_show "v0-ext-issue" '{"status": "todo", "labels": ["bug"]}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "v0-ext-issue"
}
```

**Verification**: `scripts/test status`

---

## Verification Checklist

1. `scripts/test state` - New blocking.bats passes
2. `scripts/test status` - New blocker-display.bats passes
3. `shellcheck bin/v0-status` - No warnings about local
4. Manual test:
   ```bash
   # Create op with two blockers, complete first one
   v0 build a "First"
   v0 build b "Second"
   v0 build c "Third" --after a,b
   # Complete 'a', verify 'c' still shows [after b]
   ```
