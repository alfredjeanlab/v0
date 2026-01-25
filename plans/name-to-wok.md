# Plan: name-to-wok

Allow `v0 chore --after` and `v0 fix --after` to accept both operation names and wok ticket IDs.

## Overview

Currently, `v0 chore --after` and `v0 fix --after` only accept wok ticket IDs (e.g., `v0-123`). This plan adds support for operation names (e.g., `auth`, `api-refactor`), automatically resolving them to their corresponding wok ticket ID via the operation's `epic_id` field.

## Project Structure

Key files:

```
bin/
  v0-chore           # Main chore command, parses --after flag
  v0-fix             # Main fix command, parses --after flag
packages/
  cli/lib/v0-common.sh    # v0_issue_pattern() for detecting wok IDs
  state/lib/io.sh         # sm_read_state() for reading operation state
  state/lib/rules.sh      # sm_get_state_file() for state file paths
tests/
  v0-chore.bats      # Integration tests for v0 chore
  v0-fix.bats        # Integration tests for v0 fix
```

## Dependencies

No new external dependencies. Uses existing:
- `jq` for JSON parsing
- `wk dep` for dependency management
- State package functions for reading operation state

## Implementation Phases

### Phase 1: Add helper function to resolve IDs

**File**: `packages/cli/lib/v0-common.sh`

Add a helper function that resolves an input (either operation name or wok ticket ID) to a wok ticket ID:

```bash
# v0_resolve_to_wok_id <id_or_name>
# Resolve an operation name or wok ticket ID to a wok ticket ID
# Returns: wok ticket ID if found, empty if unresolvable
v0_resolve_to_wok_id() {
  local input="$1"
  local issue_pattern
  issue_pattern=$(v0_issue_pattern)

  # If input matches wok ticket pattern, return as-is
  if [[ "${input}" =~ ^${issue_pattern}$ ]]; then
    echo "${input}"
    return 0
  fi

  # Otherwise, treat as operation name and look up epic_id
  local state_file="${BUILD_DIR}/operations/${input}/state.json"
  if [[ -f "${state_file}" ]]; then
    local epic_id
    epic_id=$(jq -r '.epic_id // empty' "${state_file}")
    if [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]]; then
      echo "${epic_id}"
      return 0
    fi
  fi

  # Return empty if unresolvable (will be skipped by caller)
  return 1
}
```

**Verification**: Unit test in `packages/cli/tests/common.bats`.

---

### Phase 2: Update v0-chore to use resolver

**File**: `bin/v0-chore`

Modify the `--after` handling to resolve each ID through the helper function.

Around line 696-703, replace:

```bash
# Add blocked-by dependencies if --after was specified
if [[ ${#AFTER_IDS[@]} -gt 0 ]]; then
  if ! wk dep "${id}" blocked-by "${AFTER_IDS[@]}" 2>/dev/null; then
```

With:

```bash
# Add blocked-by dependencies if --after was specified
if [[ ${#AFTER_IDS[@]} -gt 0 ]]; then
  # Resolve operation names to wok ticket IDs
  local resolved_ids=()
  for after_id in "${AFTER_IDS[@]}"; do
    local resolved
    if resolved=$(v0_resolve_to_wok_id "${after_id}"); then
      resolved_ids+=("${resolved}")
    else
      echo "Warning: Could not resolve '${after_id}' to a wok ticket ID (skipping)"
    fi
  done

  if [[ ${#resolved_ids[@]} -gt 0 ]]; then
    if ! wk dep "${id}" blocked-by "${resolved_ids[@]}" 2>/dev/null; then
```

Also update the usage text (lines 54-56) to reflect the new capability:

```bash
--after <ids>   Block this chore until specified issues complete
                Accepts operation names or wok ticket IDs
                (e.g., auth, v0-123, api-refactor,v0-456)
```

**Verification**: Run `v0 chore --after <op-name> "test"` where `<op-name>` is an existing operation with an `epic_id`.

---

### Phase 3: Update v0-fix to use resolver

**File**: `bin/v0-fix`

Apply the same changes as Phase 2 to `v0-fix`. The structure is nearly identical:

1. Update usage text (lines 44-46)
2. Update dependency resolution (around line 524-531)

**Verification**: Run `v0 fix --after <op-name> "test bug"` where `<op-name>` is an existing operation.

---

### Phase 4: Add unit tests for resolver function

**File**: `packages/cli/tests/common.bats`

Add tests for the new resolver function:

```bash
@test "v0_resolve_to_wok_id returns wok ticket ID as-is" {
    setup_v0_env
    export ISSUE_PREFIX="v0"

    run v0_resolve_to_wok_id "v0-abc123"
    assert_success
    assert_output "v0-abc123"
}

@test "v0_resolve_to_wok_id resolves operation name to epic_id" {
    setup_v0_env

    # Create operation with epic_id
    mkdir -p "${BUILD_DIR}/operations/test-op"
    echo '{"epic_id": "v0-xyz789"}' > "${BUILD_DIR}/operations/test-op/state.json"

    run v0_resolve_to_wok_id "test-op"
    assert_success
    assert_output "v0-xyz789"
}

@test "v0_resolve_to_wok_id fails for unknown operation" {
    setup_v0_env

    run v0_resolve_to_wok_id "nonexistent-op"
    assert_failure
}

@test "v0_resolve_to_wok_id fails for operation without epic_id" {
    setup_v0_env

    # Create operation without epic_id
    mkdir -p "${BUILD_DIR}/operations/early-op"
    echo '{"phase": "init"}' > "${BUILD_DIR}/operations/early-op/state.json"

    run v0_resolve_to_wok_id "early-op"
    assert_failure
}
```

**Verification**: `scripts/test cli`

---

### Phase 5: Add integration tests

**File**: `tests/v0-chore.bats`

Add integration tests for the new behavior:

```bash
@test "v0-chore: --after accepts operation name and resolves to epic_id" {
    # Create mock wk
    setup_mock_wk

    # Create operation with epic_id
    mkdir -p "${BUILD_DIR}/operations/blocker-op"
    cat > "${BUILD_DIR}/operations/blocker-op/state.json" <<EOF
{
  "name": "blocker-op",
  "phase": "merged",
  "epic_id": "test-blocker123"
}
EOF

    # Run v0 chore with --after using operation name
    run "${V0_CHORE}" --after blocker-op "Test chore" 2>&1 || true

    # Verify wk dep was called with resolved epic_id
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "blocked-by"
        assert_output --partial "test-blocker123"
    fi
}

@test "v0-chore: --after accepts mix of operation names and wok IDs" {
    setup_mock_wk

    # Create operation with epic_id
    mkdir -p "${BUILD_DIR}/operations/my-op"
    echo '{"epic_id": "test-op123"}' > "${BUILD_DIR}/operations/my-op/state.json"

    # Run with both operation name and wok ID
    run "${V0_CHORE}" --after my-op,test-direct456 "Mixed dependencies" 2>&1 || true

    # Both should be passed to wk dep
    if [[ -f "${MOCK_CALLS_DIR}/wk.calls" ]]; then
        run cat "${MOCK_CALLS_DIR}/wk.calls"
        assert_output --partial "test-op123"
        assert_output --partial "test-direct456"
    fi
}
```

**Verification**: `scripts/test v0-chore`

---

### Phase 6: Update documentation

Update usage examples in both commands to show the new capability:

```
Examples:
  v0 chore --after auth "Cleanup after auth feature"
  v0 chore --after v0-123 "Chore blocked by v0-123"
  v0 chore --after auth,v0-456 "Mixed blockers"
```

**Verification**: `v0 chore --help` and `v0 fix --help` show updated examples.

## Key Implementation Details

### ID Detection Logic

The resolver distinguishes between wok ticket IDs and operation names using a regex pattern:
- Wok ticket IDs match: `${ISSUE_PREFIX}-[a-z0-9]+` (e.g., `v0-abc123`)
- Operation names: anything else (e.g., `auth`, `api-refactor`)

### Resolution Flow

```
Input: "auth" or "v0-123"
         |
         v
  [Match wok pattern?]
      /          \
    YES           NO
     |             |
  Return       [Find state file?]
  as-is          /          \
               YES           NO
                |             |
            [Has epic_id?]  Return
              /     \       failure
            YES      NO
             |        |
          Return   Return
          epic_id  failure
```

### Graceful Degradation

When an operation name cannot be resolved:
- Log a warning message
- Skip that ID (don't fail the entire command)
- Continue with other resolvable IDs

This allows mixed usage where some blockers may be:
- Early-stage operations without `epic_id` yet
- Typos or non-existent operations

## Verification Plan

1. **Unit tests**: Verify `v0_resolve_to_wok_id` handles all cases
   - Wok ticket ID passthrough
   - Operation name resolution
   - Missing operation
   - Operation without epic_id

2. **Integration tests**: Verify end-to-end behavior
   - `v0 chore --after <op-name>` resolves and creates dependency
   - `v0 fix --after <op-name>` resolves and creates dependency
   - Mixed operation names and wok IDs work together

3. **Manual verification**:
   ```bash
   # Create a feature with v0 build
   v0 build auth "Add authentication"
   # Wait for it to get an epic_id (check v0 status)

   # Create a chore depending on the operation name
   v0 chore --after auth "Cleanup auth temp files"

   # Verify with wk show <chore-id>
   # Should show "blocked by: <auth-epic-id>"
   ```

4. **Regression**: Existing wok ticket ID usage continues to work unchanged
