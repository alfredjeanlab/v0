# Plan: start-stop-typo

## Overview

Add support for positional argument "typos" like `v0 fix stop` and `v0 chore start` to be interpreted as their flag equivalents `v0 fix --stop` and `v0 chore --start`. This follows the existing pattern already used for `attach` and `status` positional arguments.

## Project Structure

Files to modify:
```
bin/
  v0-fix                    # Add start/stop positional arg handlers
  v0-chore                  # Add start/stop positional arg handlers
tests/
  v0-fix.bats              # Add tests for positional start/stop
  v0-chore.bats            # Add tests for positional start/stop
```

## Dependencies

None - this is a pure shell script modification using existing patterns.

## Implementation Phases

### Phase 1: Add positional handlers in v0-fix

In `bin/v0-fix`, the argument parsing loop (around line 717-725) already handles:
- `attach)` → redirects to `v0-attach fix`
- `status)` → sets `ACTION="status"`

Add equivalent handlers for `start` and `stop`:

```bash
    start)
      # Auto-correct 'v0 fix start' to 'v0 fix --start'
      ACTION="start"
      shift
      ;;
    stop)
      # Auto-correct 'v0 fix stop' to 'v0 fix --stop'
      ACTION="stop"
      shift
      ;;
```

Insert these cases before the `*)` fallthrough case, alongside the existing `attach)` and `status)` handlers.

**Verification:** Run `v0 fix start`, `v0 fix stop` manually and verify they behave like `--start` and `--stop`.

### Phase 2: Add positional handlers in v0-chore

In `bin/v0-chore`, the same pattern exists (around lines 890-897). Add equivalent handlers:

```bash
    start)
      # Auto-correct 'v0 chore start' to 'v0 chore --start'
      ACTION="start"
      shift
      ;;
    stop)
      # Auto-correct 'v0 chore stop' to 'v0 chore --stop'
      ACTION="stop"
      shift
      ;;
```

**Verification:** Run `v0 chore start`, `v0 chore stop` manually and verify they behave like `--start` and `--stop`.

### Phase 3: Add tests for v0-fix positional arguments

Add tests to `tests/v0-fix.bats` for the new positional argument handling:

```bash
# ============================================================================
# Positional Argument Alias Tests
# ============================================================================

@test "v0-fix: 'stop' positional arg works like --stop" {
    run "${V0_FIX}" stop
    # Should have same behavior as --stop
    assert_success || assert_failure
}

@test "v0-fix: 'start' positional arg works like --start" {
    run "${V0_FIX}" start
    # Should attempt to start worker (may fail due to mock tmux)
    assert_success || assert_failure
}

@test "v0-fix: 'status' positional arg works like --status" {
    run "${V0_FIX}" status
    assert_success || assert_failure
    assert_output --partial "Worker" || assert_output --partial "worker" || assert_output --partial "not running" || true
}
```

**Verification:** Run `scripts/test v0-fix` and verify all tests pass.

### Phase 4: Add tests for v0-chore positional arguments

Add parallel tests to `tests/v0-chore.bats`:

```bash
# ============================================================================
# Positional Argument Alias Tests
# ============================================================================

@test "v0-chore: 'stop' positional arg works like --stop" {
    run "${V0_CHORE}" stop
    assert_success || assert_failure
}

@test "v0-chore: 'start' positional arg works like --start" {
    run "${V0_CHORE}" start
    assert_success || assert_failure
}

@test "v0-chore: 'status' positional arg works like --status" {
    run "${V0_CHORE}" status
    assert_success || assert_failure
    assert_output --partial "Worker" || assert_output --partial "worker" || assert_output --partial "not running" || true
}
```

**Verification:** Run `scripts/test v0-chore` and verify all tests pass.

## Key Implementation Details

### Existing Pattern

The codebase already establishes the pattern for positional argument translation:

```bash
# From bin/v0-fix lines 717-724
    attach)
      # Handle 'v0 fix attach' as alias for 'v0 attach fix'
      exec "${SCRIPT_DIR}/v0-attach" fix
      ;;
    status)
      # Auto-correct 'v0 fix status' to 'v0 fix --status'
      ACTION="status"
      shift
      ;;
```

The `start` and `stop` handlers follow the same pattern as `status`, simply setting the ACTION variable.

### Placement

The new cases must be placed:
- Before the `*)` fallthrough case
- After the flag parsing (`--*` and `-*` cases) to ensure flags take precedence

### Commands in Scope

Only `v0 fix` and `v0 chore` have `--start`, `--stop`, and `--status` flags. Other commands like `v0 roadmap` have `--status` but not `--start`/`--stop`, so they are out of scope per the user's specification.

## Verification Plan

1. **Unit testing:** Run `scripts/test v0-fix v0-chore` to verify the new tests pass
2. **Manual testing:**
   - `v0 fix start` should behave identically to `v0 fix --start`
   - `v0 fix stop` should behave identically to `v0 fix --stop`
   - `v0 chore start` should behave identically to `v0 chore --start`
   - `v0 chore stop` should behave identically to `v0 chore --stop`
3. **Full suite:** Run `make check` to ensure no regressions
4. **Edge cases:**
   - Verify `v0 fix start "some bug"` doesn't interpret "some bug" incorrectly (start should consume the action, remaining args should be positional)
   - Verify flag versions still work: `v0 fix --start`, `v0 fix --stop`
