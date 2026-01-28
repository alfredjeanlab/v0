# Implementation Plan: Wait on Anything

## Overview

Enhance `v0 wait` to accept issue IDs directly without the `--issue` flag and support waiting on any work type: operations (features), bugs, chores, and roadmaps. This requires auto-detecting issue IDs, unifying state lookup across different work types, and ensuring all workflows correctly update state when complete.

## Project Structure

```
bin/v0-wait                                 # Enhanced: auto-detect issue IDs, unified lookup
packages/cli/lib/v0-common.sh               # New helper: v0_is_issue_id
tests/v0-wait.bats                          # Extended: new test cases
docs/arch/commands/v0-wait.md               # New: command documentation
```

## Dependencies

- No new external dependencies
- Uses existing:
  - `wk` CLI for issue status queries
  - State machine functions from `packages/state/lib/`
  - Issue pattern from `v0_issue_pattern()`

## Implementation Phases

### Phase 1: Auto-detect Issue IDs Without `--issue` Flag

**Goal**: Allow `v0 wait v0-abc123` without requiring `--issue`.

**File**: `bin/v0-wait`

The key insight is that all wok issue IDs follow the pattern `${ISSUE_PREFIX}-[a-z0-9]+` (e.g., "v0-abc123"). When the positional argument matches this pattern, treat it as an issue ID.

**Changes**:

1. Add helper function to detect issue ID format:
```bash
# Check if argument looks like a wok issue ID
is_issue_id() {
  local arg="$1"
  local pattern
  pattern=$(v0_issue_pattern)
  [[ "${arg}" =~ ^${pattern}$ ]]
}
```

2. Update argument resolution logic:
```bash
# Resolve argument: either issue ID or operation name
if [[ -n "${ISSUE_ID}" ]]; then
  # Explicit --issue flag takes precedence
  resolve_issue "${ISSUE_ID}"
elif [[ -n "${POSITIONAL_ARG}" ]]; then
  if is_issue_id "${POSITIONAL_ARG}"; then
    # Looks like an issue ID
    resolve_issue "${POSITIONAL_ARG}"
  else
    # Treat as operation name
    resolve_operation "${POSITIONAL_ARG}"
  fi
fi
```

**Verification**:
- `v0 wait v0-abc123` works (auto-detects issue ID)
- `v0 wait auth` still works (operation name)
- `v0 wait --issue v0-abc123` still works (explicit flag)

---

### Phase 2: Unified Issue Lookup Across All Work Types

**Goal**: Find issues across all state locations (operations, bugs, chores).

**File**: `bin/v0-wait`

Currently, `find_op_by_issue()` only searches operations. Bugs and chores have different state file structures:

| Work Type | State Location | ID Field |
|-----------|----------------|----------|
| Operations | `${BUILD_DIR}/operations/<name>/state.json` | `epic_id` |
| Bugs | `${BUILD_DIR}/fix/<id>/state.json` | `issue_id` |
| Chores | `${BUILD_DIR}/chore/<id>/state.json` | `issue_id` |

**Changes**:

1. Replace `find_op_by_issue()` with unified `find_work_by_issue()`:
```bash
# Find work item by issue ID
# Returns: "type:name" (e.g., "operation:auth", "fix:v0-abc", "chore:v0-def")
# Exit 0 if found, 1 if not found
find_work_by_issue() {
  local issue_id="$1"

  # 1. Check operations (epic_id field)
  if [[ -d "${BUILD_DIR}/operations" ]]; then
    for state_file in "${BUILD_DIR}"/operations/*/state.json; do
      [[ -f "${state_file}" ]] || continue
      local epic_id
      epic_id=$(jq -r '.epic_id // empty' "${state_file}" 2>/dev/null)
      if [[ "${epic_id}" == "${issue_id}" ]]; then
        local op_name
        op_name=$(basename "$(dirname "${state_file}")")
        echo "operation:${op_name}"
        return 0
      fi
    done
  fi

  # 2. Check fix state (direct lookup by issue ID)
  local fix_state="${BUILD_DIR}/fix/${issue_id}/state.json"
  if [[ -f "${fix_state}" ]]; then
    echo "fix:${issue_id}"
    return 0
  fi

  # 3. Check chore state (direct lookup by issue ID)
  local chore_state="${BUILD_DIR}/chore/${issue_id}/state.json"
  if [[ -f "${chore_state}" ]]; then
    echo "chore:${issue_id}"
    return 0
  fi

  return 1
}
```

2. Add work-type-specific completion checking:
```bash
# Check if work item is complete based on type
# Returns 0 if complete, 1 if in progress, 2 if failed
check_work_completion() {
  local work_type="$1"
  local work_id="$2"

  case "${work_type}" in
    operation)
      local phase
      phase=$(sm_read_state "${work_id}" "phase")
      if sm_is_terminal_phase "${phase}"; then
        [[ "${phase}" == "merged" ]] && return 0 || return 2
      fi
      return 1
      ;;

    fix|chore)
      local state_file="${BUILD_DIR}/${work_type}/${work_id}/state.json"
      local status
      status=$(jq -r '.status // empty' "${state_file}" 2>/dev/null)

      # Terminal states for fix/chore workers
      case "${status}" in
        pushed|completed) return 0 ;;  # Success
        *) return 1 ;;  # In progress
      esac
      ;;
  esac

  return 1
}
```

**Verification**:
- `v0 wait v0-bug123` finds and waits on bug fix
- `v0 wait v0-chore456` finds and waits on chore
- `v0 wait v0-feature789` finds operation by epic_id

---

### Phase 3: Support Roadmap Waiting

**Goal**: Allow waiting on roadmaps by name or associated idea ID.

**File**: `bin/v0-wait`

Roadmaps have separate state at `${BUILD_DIR}/roadmaps/<name>/state.json` with:
- `phase` field (terminal: `completed`, `failed`, `interrupted`)
- `idea_id` field linking to wok issue

**Changes**:

1. Extend `find_work_by_issue()` to check roadmaps:
```bash
  # 4. Check roadmaps (idea_id field)
  if [[ -d "${BUILD_DIR}/roadmaps" ]]; then
    for state_file in "${BUILD_DIR}"/roadmaps/*/state.json; do
      [[ -f "${state_file}" ]] || continue
      local idea_id
      idea_id=$(jq -r '.idea_id // empty' "${state_file}" 2>/dev/null)
      if [[ "${idea_id}" == "${issue_id}" ]]; then
        local roadmap_name
        roadmap_name=$(basename "$(dirname "${state_file}")")
        echo "roadmap:${roadmap_name}"
        return 0
      fi
    done
  fi
```

2. Add roadmap support to `check_work_completion()`:
```bash
    roadmap)
      local state_file="${BUILD_DIR}/roadmaps/${work_id}/state.json"
      local phase
      phase=$(jq -r '.phase // empty' "${state_file}" 2>/dev/null)

      # Terminal states for roadmaps
      case "${phase}" in
        completed) return 0 ;;           # Success
        failed|interrupted) return 2 ;;  # Failed
        *) return 1 ;;                   # In progress
      esac
      ;;
```

3. Support roadmap names as direct argument:
```bash
# Also try direct roadmap lookup by name
resolve_by_name() {
  local name="$1"

  # Check if it's an operation
  if sm_state_exists "${name}"; then
    echo "operation:${name}"
    return 0
  fi

  # Check if it's a roadmap
  if [[ -f "${BUILD_DIR}/roadmaps/${name}/state.json" ]]; then
    echo "roadmap:${name}"
    return 0
  fi

  return 1
}
```

**Verification**:
- `v0 wait myproject` waits on roadmap named "myproject"
- `v0 wait v0-idea123` waits on roadmap by idea_id

---

### Phase 4: wok Status Fallback

**Goal**: For issues without local state, check wok directly.

**File**: `bin/v0-wait`

Some issues may complete without local state (e.g., manually closed), or state may be stale. Add wok status as fallback.

**Changes**:

1. Add wok-based completion check:
```bash
# Check wok issue status directly
# Returns 0 if done/closed, 1 if open, 2 if not found
check_wok_status() {
  local issue_id="$1"

  local status
  status=$(wk show "${issue_id}" -o json 2>/dev/null | jq -r '.status // empty')

  case "${status}" in
    done|closed) return 0 ;;
    todo|in_progress) return 1 ;;
    "") return 2 ;;  # Issue not found
    *) return 1 ;;   # Unknown status, treat as in-progress
  esac
}
```

2. Update wait loop to use wok fallback:
```bash
wait_for_issue() {
  local issue_id="$1"
  local timeout_secs="$2"
  local quiet="$3"

  local start_time work_info
  start_time=$(date +%s)

  while true; do
    # Try to find local state first
    if work_info=$(find_work_by_issue "${issue_id}"); then
      local work_type work_id
      work_type="${work_info%%:*}"
      work_id="${work_info#*:}"

      local result
      check_work_completion "${work_type}" "${work_id}"
      result=$?

      case ${result} in
        0) # Complete
          [[ -z "${quiet}" ]] && echo "Issue '${issue_id}' completed successfully"
          return 0
          ;;
        2) # Failed
          [[ -z "${quiet}" ]] && echo "Issue '${issue_id}' failed"
          return 1
          ;;
      esac
    else
      # No local state - check wok directly
      check_wok_status "${issue_id}"
      case $? in
        0) # Done in wok
          [[ -z "${quiet}" ]] && echo "Issue '${issue_id}' is done (per wok)"
          return 0
          ;;
        2) # Not found
          echo "Error: Issue '${issue_id}' not found" >&2
          return 3
          ;;
      esac
    fi

    # Check timeout
    # ... (existing timeout logic)

    sleep 2
  done
}
```

**Verification**:
- `v0 wait v0-manual123` works for manually-closed issues
- Proper error message when issue doesn't exist in wok

---

### Phase 5: Workflow Notification Audit

**Goal**: Ensure all workflows correctly update state when complete so `v0 wait` can detect completion.

**Review Checklist**:

| Workflow | State File | Terminal State | Update Location |
|----------|------------|----------------|-----------------|
| `v0 build` | `operations/<name>/state.json` | `phase: merged/cancelled` | `sm_transition_to_merged()` |
| `v0 fix` | `fix/<id>/state.json` | `status: pushed` | `fixed` script in worktree |
| `v0 chore` | `chore/<id>/state.json` | `status: pushed/completed` | `fixed`/`completed` scripts |
| `v0 roadmap` | `roadmaps/<name>/state.json` | `phase: completed/failed/interrupted` | `v0-roadmap-worker` |

**Files to Review**:

1. **Fix Worker** (`bin/v0-fix`):
   - `fixed` script sets `status: pushed`
   - Human handoff sets `status: started` (not terminal)

2. **Chore Worker** (`bin/v0-chore`):
   - Project mode: `fixed` script sets `status: pushed`
   - Standalone mode: `completed` script sets `status: completed`

3. **Roadmap Worker** (`bin/v0-roadmap-worker`):
   - Verify terminal phases are set correctly

**Potential Fixes**:

If any workflow doesn't properly update state on completion, add the update. Example pattern:
```bash
# In completion handler
cat > "${STATE_DIR}/state.json" <<EOF
{
  "issue_id": "${ISSUE_ID}",
  "status": "completed",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
```

---

### Phase 6: Tests and Documentation

**Goal**: Comprehensive tests and documentation.

**File**: `tests/v0-wait.bats`

**New Test Cases**:

```bash
# Auto-detect issue ID format
@test "v0-wait: auto-detects issue ID without --issue flag" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" \
      '{"name": "testop", "phase": "merged", "machine": "testmachine", "epic_id": "test-abc123"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-abc123
    '
    assert_success
    assert_output --partial "completed successfully"
}

# Wait on bug fix
@test "v0-wait: waits for bug fix completion" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create fix state
    mkdir -p "${project_dir}/.v0/build/fix/test-bug123"
    echo '{"issue_id": "test-bug123", "status": "pushed"}' > \
      "${project_dir}/.v0/build/fix/test-bug123/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-bug123
    '
    assert_success
}

# Wait on chore
@test "v0-wait: waits for chore completion" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create chore state
    mkdir -p "${project_dir}/.v0/build/chore/test-chore456"
    echo '{"issue_id": "test-chore456", "status": "completed"}' > \
      "${project_dir}/.v0/build/chore/test-chore456/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-chore456
    '
    assert_success
}

# Wait on roadmap
@test "v0-wait: waits for roadmap by name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create roadmap state
    mkdir -p "${project_dir}/.v0/build/roadmaps/myproject"
    echo '{"name": "myproject", "phase": "completed"}' > \
      "${project_dir}/.v0/build/roadmaps/myproject/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" myproject
    '
    assert_success
}

# Ambiguous argument prefers operation
@test "v0-wait: operation name takes precedence over pattern match" {
    # If someone names an operation "v0-abc", it should work as operation name
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "v0-abc" \
      '{"name": "v0-abc", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" v0-abc
    '
    assert_success
}
```

**Documentation**: `docs/arch/commands/v0-wait.md`

```markdown
# v0 wait

Wait for an operation, issue, or roadmap to complete.

## Usage

```bash
v0 wait <target> [--timeout <duration>] [--quiet]
```

## Target Resolution

The target can be:

| Format | Example | Description |
|--------|---------|-------------|
| Operation name | `auth` | Wait for operation "auth" |
| Issue ID | `v0-abc123` | Wait for issue (auto-detected by pattern) |
| Roadmap name | `api-rewrite` | Wait for roadmap |
| Explicit issue | `--issue v0-xyz` | Explicit issue ID (for edge cases) |

Issue IDs are auto-detected when the argument matches the project's issue
pattern (`${ISSUE_PREFIX}-[a-z0-9]+`).

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Completed successfully |
| 1 | Failed or cancelled |
| 2 | Timeout expired |
| 3 | Target not found |

## Examples

```bash
# Wait for operation
v0 wait auth

# Wait for bug fix (auto-detects issue ID)
v0 wait v0-bug123

# Wait with timeout
v0 wait v0-chore456 --timeout 30m

# Script usage with exit code check
if v0 wait auth --quiet; then
  echo "Auth feature merged"
fi
```
```

## Key Implementation Details

### Issue Pattern Detection

Issue IDs follow the pattern defined by wok configuration:
- Pattern: `${ISSUE_PREFIX}-[a-z0-9]+`
- Example with `prefix = "v0"`: `v0-abc123`, `v0-7f8e9d`

The detection uses regex matching against `v0_issue_pattern()` output.

### State File Locations

| Work Type | State Path | Key Fields |
|-----------|------------|------------|
| Operation | `${BUILD_DIR}/operations/<name>/state.json` | `phase`, `epic_id` |
| Bug Fix | `${BUILD_DIR}/fix/<id>/state.json` | `status`, `issue_id` |
| Chore | `${BUILD_DIR}/chore/<id>/state.json` | `status`, `issue_id` |
| Roadmap | `${BUILD_DIR}/roadmaps/<name>/state.json` | `phase`, `idea_id` |

### Terminal States by Type

| Work Type | Success State | Failure States |
|-----------|---------------|----------------|
| Operation | `merged` | `cancelled`, `failed` |
| Bug/Chore | `pushed`, `completed` | - |
| Roadmap | `completed` | `failed`, `interrupted` |

### Polling Interval

Wait polls every 2 seconds, consistent with other v0 monitoring patterns.

### wok Fallback

If no local state exists for an issue ID, wait checks wok directly:
- `done` or `closed` status → success (exit 0)
- `todo` or `in_progress` → keep waiting
- Issue not found → error (exit 3)

## Verification Plan

1. **Lint**: `make lint` - ShellCheck passes
2. **Unit Tests**: `scripts/test v0-wait` - all tests pass
3. **Integration**: `make check` - full suite passes
4. **Manual Testing**:
   - Auto-detect: `v0 wait v0-abc` (issue ID without --issue)
   - Bug fix: Create bug with `v0 fix`, wait on its ID
   - Chore: Create chore with `v0 chore`, wait on its ID
   - Roadmap: Create roadmap, wait on its name or idea_id
   - Timeout: `v0 wait in-progress-op --timeout 5s`
   - Not found: `v0 wait nonexistent-999` exits with code 3
