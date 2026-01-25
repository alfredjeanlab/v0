# Plan: Standardize Start/Stop Command Documentation

## Overview

Update all user-facing documentation to consistently show `v0 start [worker]` and `v0 stop [worker]` as the primary interface, instead of `v0 <worker> --start` / `v0 <worker> --stop`. The old flag-based commands (`--start`, `--stop`) will continue to work but be hidden from help output.

## Project Structure

Key files to modify:
```
bin/v0                  # Main help text (already correct)
bin/v0-fix              # Hide --start/--stop from usage
bin/v0-chore            # Hide --start/--stop from usage
bin/v0-mergeq           # Hide --start/--stop from usage
bin/v0-prime            # Change 'v0 startup' → 'v0 start'
README.md               # Change 'v0 shutdown' → 'v0 stop'
tests/v0-help.bats      # NEW: Test help output formatting
tests/v0-aliases.bats   # NEW: Test alias/flag behavior
```

## Dependencies

No new external dependencies required.

## Implementation Phases

### Phase 1: Update Worker Help Text

Hide `--start` and `--stop` flags from user-facing help while keeping them functional.

**Files to modify:**
- `bin/v0-fix` (lines 24-62)
- `bin/v0-chore` (similar structure)
- `bin/v0-mergeq` (lines 28-55)

**Change pattern for v0-fix:**
```bash
# Before:
Usage: v0 fix [options] <bug description>
       v0 fix --start
       v0 fix --stop
       v0 fix --status
       v0 fix --history

# After:
Usage: v0 fix [options] <bug description>
       v0 fix --status
       v0 fix --history

# Remove from Commands section:
  --start         Start worker to process existing bugs
  --stop          Stop the worker
```

Keep the `--start` and `--stop` case handlers in argument parsing to maintain backward compatibility.

**Verification:** Run `v0 fix --help` and verify `--start`/`--stop` are not shown.

### Phase 2: Update Prime Quick-Start Guide

Update `bin/v0-prime` to use `v0 start` instead of `v0 startup`.

**Change at line 48:**
```bash
# Before:
v0 startup                          # Start background workers

# After:
v0 start                            # Start background workers
```

**Verification:** Run `v0 prime` and verify it shows `v0 start`.

### Phase 3: Update README Documentation

Update `README.md` to use modern `v0 start`/`v0 stop` commands.

**Line 133:**
```bash
# Before:
v0 shutdown      # Stop all workers and daemons

# After:
v0 stop          # Stop all workers and daemons
```

**Verification:** Check README.md shows updated commands.

### Phase 4: Create Help Output Tests

Create `tests/v0-help.bats` to verify help text formatting across all commands.

```bash
#!/usr/bin/env bats
# Test help output formatting

load '../packages/test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
}

# Main v0 help shows start/stop with worker pattern
@test "v0 help shows 'v0 start [fix|chore|mergeq]' pattern" {
  run v0 --help
  assert_success
  assert_output --partial "v0 start"
  assert_output --partial "v0 stop"
  # Should show the worker sub-options
  assert_output --partial "[fix|chore|mergeq]"
}

# v0-fix help should NOT show --start/--stop
@test "v0 fix help hides --start flag" {
  run v0 fix --help
  assert_success
  refute_output --partial "  --start"
  refute_output --partial "Start worker"
}

@test "v0 fix help hides --stop flag" {
  run v0 fix --help
  assert_success
  refute_output --partial "  --stop"
  refute_output --partial "Stop the worker"
}

# v0 fix help should still show --status (not hidden)
@test "v0 fix help shows --status flag" {
  run v0 fix --help
  assert_success
  assert_output --partial "--status"
}

# Similar tests for chore and mergeq...
@test "v0 chore help hides --start/--stop flags" {
  run v0 chore --help
  assert_success
  refute_output --partial "  --start"
  refute_output --partial "  --stop"
}

@test "v0 mergeq help hides --start/--stop flags" {
  run v0 mergeq --help
  assert_success
  refute_output --partial "  --start"
  refute_output --partial "  --stop"
}

# v0-start and v0-stop help should be clear
@test "v0 start help shows worker options" {
  run v0 start --help
  assert_success
  assert_output --partial "fix"
  assert_output --partial "chore"
  assert_output --partial "mergeq"
}

@test "v0 stop help shows worker options" {
  run v0 stop --help
  assert_success
  assert_output --partial "fix"
  assert_output --partial "chore"
  assert_output --partial "mergeq"
}
```

**Verification:** Run `scripts/test v0-help` and verify all tests pass.

### Phase 5: Create Alias Behavior Tests

Create or extend tests to verify that hidden aliases continue to work.

Add to `tests/v0-aliases.bats`:

```bash
#!/usr/bin/env bats
# Test alias and backward-compatibility behavior

load '../packages/test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  create_v0rc
}

# Hidden --start/--stop flags still work
@test "v0 fix --start still works (hidden alias)" {
  setup_mock_binaries
  export PATH="${TEST_TEMP_DIR}/mock:$PATH"

  # Should delegate to appropriate command
  run v0 fix --start
  # Verify it attempts to start (may fail in test env, but shouldn't be "unknown option")
  refute_output --partial "Unknown option"
}

@test "v0 chore --stop still works (hidden alias)" {
  setup_mock_binaries
  export PATH="${TEST_TEMP_DIR}/mock:$PATH"

  run v0 chore --stop
  refute_output --partial "Unknown option"
}

# startup/shutdown aliases still work
@test "v0 startup still works (hidden alias)" {
  run v0 startup --dry-run
  assert_success
  # Startup with dry-run should show what it would do
}

@test "v0 shutdown still works (hidden alias)" {
  run v0 shutdown --dry-run
  assert_success
}

# Primary commands work
@test "v0 start fix dry-run works" {
  run v0 start fix --dry-run
  assert_success
  assert_output --partial "Would run: v0 fix --start"
}

@test "v0 stop chore dry-run works" {
  run v0 stop chore --dry-run
  assert_success
  assert_output --partial "Would run: v0 chore --stop"
}
```

**Verification:** Run `scripts/test v0-aliases` and verify all tests pass.

### Phase 6: Final Verification

Run full test suite and verify no regressions.

```bash
make check              # All lints and tests
scripts/test            # Incremental test runner
```

**Verification checklist:**
- [ ] `v0 --help` shows `v0 start [fix|chore|mergeq]`
- [ ] `v0 fix --help` does NOT show `--start` or `--stop`
- [ ] `v0 chore --help` does NOT show `--start` or `--stop`
- [ ] `v0 mergeq --help` does NOT show `--start` or `--stop`
- [ ] `v0 start --help` shows worker options clearly
- [ ] `v0 stop --help` shows worker options clearly
- [ ] `v0 prime` shows `v0 start` (not `v0 startup`)
- [ ] README.md shows `v0 stop` (not `v0 shutdown`)
- [ ] `v0 fix --start` still works (hidden)
- [ ] `v0 chore --stop` still works (hidden)
- [ ] `v0 startup` still works (hidden alias)
- [ ] `v0 shutdown` still works (hidden alias)
- [ ] All existing tests pass

## Key Implementation Details

### Hiding Flags from Help

The pattern to hide flags while keeping them functional:

```bash
# In the usage() function, remove the lines about --start/--stop
usage() {
  v0_help <<'EOF'
Usage: v0 fix [options] <bug description>
       v0 fix --status
       v0 fix --history
# ... DO NOT list --start or --stop here ...
EOF
}

# But KEEP the case handlers in argument parsing:
case "$1" in
  --start)
    # Still works when called directly
    start_worker
    exit 0
    ;;
  --stop)
    # Still works when called directly
    stop_worker
    exit 0
    ;;
  # ... rest of parsing ...
esac
```

### Positional Argument Conversion

The workers already support positional `start`/`stop` (auto-converted to flags). This behavior should be preserved:

```bash
# v0 fix start → v0 fix --start (auto-conversion, v0-fix lines 714-723)
```

### Test Isolation

All tests use isolated temporary directories via `setup_v0_env()` and `create_v0rc()`. Mocked binaries prevent actual worker processes from starting during tests.

## Verification Plan

1. **Unit tests for help output** (`tests/v0-help.bats`):
   - Verify hidden flags don't appear in help
   - Verify visible flags still appear
   - Verify main v0 help shows correct format

2. **Integration tests for aliases** (`tests/v0-aliases.bats`):
   - Verify hidden flags still function
   - Verify hidden command aliases work
   - Verify dry-run mode shows expected commands

3. **Manual verification**:
   ```bash
   v0 --help             # Check start/stop format
   v0 fix --help         # Verify no --start/--stop
   v0 fix --start        # Verify it still works
   v0 start fix --dry-run # Verify new pattern works
   v0 prime              # Check updated example
   ```

4. **Regression suite**:
   ```bash
   make check            # Full lint + test
   scripts/test v0       # v0 dispatcher tests
   scripts/test v0-start # Start command tests
   scripts/test v0-stop  # Stop command tests
   ```
