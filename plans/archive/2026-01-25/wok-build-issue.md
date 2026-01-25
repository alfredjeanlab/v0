# Plan: Create Feature Issue Immediately in v0 build

## Overview

Modify `v0 build` to create the wok feature issue immediately when starting a build operation, rather than waiting until the plan is complete. This brings feature issue creation in line with how bugs and chores work (showing the ID immediately in the response). The description can be updated later when planning completes.

## Current Behavior

| Operation | Issue Created | ID Shown to User |
|-----------|---------------|------------------|
| `v0 fix` (bugs) | Immediately | Yes, immediately |
| `v0 chore` | Immediately | Yes, immediately |
| `v0 build` (features) | After plan complete | No (only in logs) |

## Target Behavior

- Create feature issue immediately when `v0 build` starts
- Show issue ID in the initial response (like bugs/chores)
- Update issue description when plan is complete
- If `--plan` is provided, set description immediately

## Project Structure

Key files to modify:

```
packages/cli/lib/build/
  issue.sh         # Add new function: create_feature_issue()
  init.sh          # Call create_feature_issue() during init

bin/
  v0-build         # Update output to show issue ID
  v0-build-worker  # Update to set description instead of create issue
```

## Dependencies

No new external dependencies. Uses existing:
- `wk` CLI for issue management
- `jq` for JSON manipulation

## Implementation Phases

### Phase 1: Add `create_feature_issue()` Function

**Goal**: Create a new function that creates a feature issue with just a title, returning the ID.

**File**: `packages/cli/lib/build/issue.sh`

Add new function `create_feature_issue()`:

```bash
# create_feature_issue <name>
# Creates a feature issue with a placeholder description
# Arguments:
#   $1 = operation name
# Returns: issue ID on stdout, or empty string on failure
create_feature_issue() {
  local name="$1"
  local title="Plan: ${name}"

  # Create feature issue with placeholder description
  local issue_id output wk_err
  wk_err=$(mktemp)
  output=$(wk new feature "${title}" --description "Planning in progress..." 2>"${wk_err}") || {
    echo "create_feature_issue: wk new failed: $(cat "${wk_err}")" >&2
    rm -f "${wk_err}"
    return 1
  }
  rm -f "${wk_err}"

  issue_id=$(echo "${output}" | grep -oE '\) [a-zA-Z0-9-]+:' | sed 's/^) //; s/:$//')

  if [[ -z "${issue_id}" ]]; then
    echo "create_feature_issue: failed to extract issue ID from: ${output}" >&2
    return 1
  fi

  echo "${issue_id}"
}
```

**Verification**:
- Source the file and test `create_feature_issue test-op` returns an ID
- Verify issue exists with `wk show <id>`

### Phase 2: Update `file_plan_issue()` to Update Existing Issue

**Goal**: Modify `file_plan_issue()` to optionally update an existing issue instead of creating a new one.

**File**: `packages/cli/lib/build/issue.sh`

Modify signature to:
```bash
# file_plan_issue <name> <plan_file> [existing_id]
# Creates or updates a feature issue with plan content
file_plan_issue() {
  local name="$1"
  local plan_file="$2"
  local existing_id="${3:-}"

  # ... existing validation ...

  local issue_id
  if [[ -n "${existing_id}" ]]; then
    # Update existing issue
    issue_id="${existing_id}"
  else
    # Create new issue (backwards compatibility)
    # ... existing creation logic ...
  fi

  # Set description and label (same as before)
  # ...
}
```

**Verification**:
- Test `file_plan_issue name plan.md` creates new issue (backwards compat)
- Test `file_plan_issue name plan.md existing-id` updates existing issue

### Phase 3: Create Issue Immediately in `v0 build`

**Goal**: Create the feature issue right after state initialization and show the ID.

**File**: `bin/v0-build`

Changes:

1. After `feature_init_state()` call (around line 520), create the issue:
```bash
# Create feature issue immediately (before planning)
if [[ -z "${EXISTING_FEATURE}" ]]; then
  FEATURE_ID=$(create_feature_issue "${NAME}")
  if [[ -n "${FEATURE_ID}" ]]; then
    update_state "epic_id" "\"${FEATURE_ID}\""
    emit_event "issue:created" "Created feature ${FEATURE_ID}"
  else
    emit_event "issue:warning" "Failed to create feature issue"
  fi
fi
```

2. Update the background execution output (lines 593-600) to show the ID:
```bash
echo ""
echo -e "${C_GREEN}Created feature:${C_RESET} ${C_CYAN}${FEATURE_ID}${C_RESET}"
echo ""
echo -e "${C_BOLD}${C_CYAN}=== Feature '${NAME}' queued for planning ===${C_RESET}"
echo -e "Worker PID: ${C_DIM}${WORKER_PID}${C_RESET}"
echo ""
echo -e "Check:     ${C_BOLD}v0 status ${NAME}${C_RESET}"
echo -e "Attach:    ${C_BOLD}v0 attach ${NAME}${C_RESET}"
echo -e "View logs: ${C_BOLD}tail -f ${WORKER_LOG}${C_RESET}"
echo ""
```

3. For `--plan` case with no existing feature ID, create issue with full description immediately

**Verification**:
- `v0 build test "prompt"` shows issue ID in output
- State file has `epic_id` set before planning starts

### Phase 4: Update `v0-build-worker` to Update Instead of Create

**Goal**: Worker should update the existing issue description instead of creating a new one.

**File**: `bin/v0-build-worker`

Changes at line 331 (in `run_plan_phase()`):
```bash
# Update feature issue with plan content (issue already created at init)
local PLAN_FILE="${PLANS_DIR}/${NAME}.md"
local FEATURE_ID
FEATURE_ID=$(get_state epic_id)

if [[ -n "${FEATURE_ID}" ]] && [[ "${FEATURE_ID}" != "null" ]]; then
  # Update existing issue with plan content
  file_plan_issue "${NAME}" "${PLAN_FILE}" "${FEATURE_ID}"
  emit_event "issue:updated" "Updated feature ${FEATURE_ID} with plan"
else
  # Fallback: create new issue (shouldn't happen normally)
  FEATURE_ID=$(file_plan_issue "${NAME}" "${PLAN_FILE}")
  if [[ -n "${FEATURE_ID}" ]]; then
    update_state "epic_id" "\"${FEATURE_ID}\""
    emit_event "issue:created" "Created feature ${FEATURE_ID}"
  fi
fi
```

Similar updates needed for:
- Lines 528-538 (`planned` phase recovery)
- Lines 561-570 (`failed` phase recovery)

**Verification**:
- Worker updates existing issue instead of creating new one
- Issue description changes from "Planning in progress..." to actual plan

### Phase 5: Update Foreground Mode Output

**Goal**: Ensure foreground mode also shows the issue ID immediately.

**File**: `bin/v0-build`

In the foreground planning section (around line 637), add issue creation before tmux session:
```bash
# Create feature issue immediately
if [[ -z "$(get_state epic_id)" ]] || [[ "$(get_state epic_id)" = "null" ]]; then
  FEATURE_ID=$(create_feature_issue "${NAME}")
  if [[ -n "${FEATURE_ID}" ]]; then
    update_state "epic_id" "\"${FEATURE_ID}\""
    emit_event "issue:created" "Created feature ${FEATURE_ID}"
    echo -e "${C_GREEN}Created feature:${C_RESET} ${C_CYAN}${FEATURE_ID}${C_RESET}"
    echo ""
  fi
fi
```

After planning completes (line 736), update instead of create:
```bash
FEATURE_ID=$(get_state epic_id)
if [[ -n "${FEATURE_ID}" ]] && [[ "${FEATURE_ID}" != "null" ]]; then
  file_plan_issue "${NAME}" "${PLAN_FILE}" "${FEATURE_ID}"
  emit_event "issue:updated" "Updated feature ${FEATURE_ID} with plan"
else
  # Fallback
  FEATURE_ID=$(file_plan_issue "${NAME}" "${PLAN_FILE}")
  # ...
fi
```

**Verification**:
- `v0 build test "prompt" --foreground` shows issue ID at start
- Issue description updated when plan completes

### Phase 6: Add Unit Tests

**Goal**: Add tests for the new and modified functions.

**File**: `packages/cli/tests/issue.bats` (new file)

```bash
#!/usr/bin/env bats

load '../packages/test-support/helpers/test_helper'

setup() {
  setup_test_env
  source_lib "build/issue.sh"

  # Mock wk command
  mock_wk() {
    case "$1" in
      new)
        echo "Created [feature] (todo) mock-abc1: $3"
        ;;
      edit|label)
        return 0
        ;;
    esac
  }
  export -f mock_wk
  alias wk=mock_wk
}

@test "create_feature_issue returns issue ID" {
  run create_feature_issue "test-op"
  [ "$status" -eq 0 ]
  [ "$output" = "mock-abc1" ]
}

@test "file_plan_issue with existing ID updates instead of creates" {
  echo "# Test Plan" > "$BATS_TMPDIR/test.md"

  run file_plan_issue "test-op" "$BATS_TMPDIR/test.md" "existing-id"
  [ "$status" -eq 0 ]
  [ "$output" = "existing-id" ]
}

@test "file_plan_issue without ID creates new issue" {
  echo "# Test Plan" > "$BATS_TMPDIR/test.md"

  run file_plan_issue "test-op" "$BATS_TMPDIR/test.md"
  [ "$status" -eq 0 ]
  [ "$output" = "mock-abc1" ]
}
```

**Verification**:
- `scripts/test cli` passes
- `scripts/test --bust cli` passes (clean run)

## Key Implementation Details

### Issue ID Extraction Pattern

The `wk new` command outputs: `Created [feature] (todo) v0-abc1: Title`

Current regex: `'\) [a-zA-Z0-9-]+:'` extracts the ID portion.

### State Flow

```
Before (current):
  init → (planning...) → planned → file_issue → queued

After (new):
  init → create_issue → (planning...) → planned → update_issue → queued
```

### Backwards Compatibility

- `file_plan_issue` remains callable without existing ID for backwards compat
- Worker falls back to creating issue if `epic_id` is missing
- `--resume` from states without `epic_id` still works

### Label Timing

Labels are added after issue creation. With immediate creation:
- Create issue immediately (no labels yet)
- Add labels after plan completes (or immediately for `--plan`)

## Verification Plan

### Manual Testing

1. **Basic flow**:
   ```bash
   v0 build test-feature "Add a test feature"
   # Verify: Shows "Created feature: v0-xxxx" before "queued for planning"
   # Verify: wk show v0-xxxx shows "Planning in progress..."
   # Wait for plan...
   # Verify: wk show v0-xxxx shows actual plan content
   ```

2. **With --plan flag**:
   ```bash
   v0 build test-plan --plan plans/existing.md
   # Verify: Shows issue ID immediately
   # Verify: Issue has full plan content immediately
   ```

3. **Foreground mode**:
   ```bash
   v0 build test-fg "Test" --foreground
   # Verify: Shows issue ID before "Starting planning step"
   ```

4. **Resume from failure**:
   ```bash
   # Simulate failure after init
   v0 build test-resume --resume
   # Verify: Uses existing issue ID, doesn't create duplicate
   ```

### Automated Testing

```bash
# Run all tests
make check

# Run specific packages
scripts/test cli

# Run with cache bust
scripts/test --bust cli
```

### Regression Checks

- Existing `v0 fix` and `v0 chore` commands unaffected
- `v0 status` shows correct epic_id
- Merge queue handles operations with early-created issues
