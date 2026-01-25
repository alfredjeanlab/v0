# Plan: Rename startup/shutdown to start/stop

## Overview

Rename `startup` and `shutdown` commands to `start` and `stop` as the primary command names. The old names (`startup`/`shutdown`) will continue to work as hidden aliases that don't appear in help output.

## Project Structure

Files to modify:
```
bin/
  v0                    # Main dispatcher - update routing and help
  v0-startup            # Update help text to show "v0 start"
  v0-shutdown           # Update help text to show "v0 stop"
  v0-start              # NEW: symlink to v0-startup
  v0-stop               # NEW: symlink to v0-shutdown

tests/
  v0-startup.bats       # Add tests for "start" name and help verification
  v0-shutdown.bats      # Add tests for "stop" name and help verification
```

## Dependencies

None - pure shell script changes.

## Implementation Phases

### Phase 1: Create Command Symlinks

Create symlinks for the new primary names:

```bash
cd bin/
ln -s v0-startup v0-start
ln -s v0-shutdown v0-stop
```

This allows `v0-start` and `v0-stop` to work immediately.

**Verification:** Run `bin/v0-start --help` and `bin/v0-stop --help`

### Phase 2: Update Main Dispatcher (bin/v0)

Update `bin/v0` to:

1. **Update `PROJECT_COMMANDS`** (line 19): Change `shutdown startup` to `stop start`

2. **Update main help text** (lines 73-74): Change:
   ```
   startup       Start workers (fix, chore, mergeq)
   shutdown      Stop all v0 processes for this project
   ```
   To:
   ```
   start         Start workers (fix, chore, mergeq)
   stop          Stop all v0 processes for this project
   ```

3. **Update case statement routing** (line 206): Replace `shutdown|startup` with `stop|start`

4. **Add hidden aliases section** after the new routing, before the unknown command handler:
   ```bash
   # Hidden aliases (old names, not shown in help)
   startup|shutdown)
       # Map old names to new names
       local new_cmd="${CMD/startup/start}"
       new_cmd="${new_cmd/shutdown/stop}"
       exec "${V0_DIR}/bin/v0-${new_cmd}" "$@"
       ;;
   ```

**Verification:** Run `v0 --help` and confirm `start`/`stop` appear (not `startup`/`shutdown`)

### Phase 3: Update Command Help Text

#### Update bin/v0-startup

Change usage() help text (lines 18-41):
- Line 19: `Usage: v0 startup [workers...]` → `Usage: v0 start [workers...]`
- Line 21: Keep description as-is
- Lines 35-38: Update examples:
  ```
  v0 start              # Start all workers
  v0 start fix          # Start only the fix worker
  v0 start fix chore    # Start fix and chore workers
  v0 start --dry-run    # Preview what would be started
  ```

#### Update bin/v0-shutdown

Change usage() help text (lines 20-48):
- Line 22: `Usage: v0 shutdown [options]` → `Usage: v0 stop [options]`
- Lines 44-46: Update examples:
  ```
  v0 stop              # Stop all v0 processes and clean up
  v0 stop --dry-run    # Preview what would be stopped
  v0 stop --force      # Force kill and delete all branches
  ```

**Verification:** Run `v0 start --help` and `v0 stop --help`

### Phase 4: Update Tests for New Names

#### Update tests/v0-startup.bats

1. **Update existing tests** to use new command name in assertions:
   - Change `assert_output --partial "Usage: v0 startup"` to `assert_output --partial "Usage: v0 start"`
   - Change `assert_output --partial "startup"` to `assert_output --partial "start"` in main help test

2. **Add new tests** for alias functionality:
   ```bash
   @test "startup is a hidden alias for start" {
       local project_dir
       project_dir=$(setup_isolated_project)

       run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
           cd "'"$project_dir"'"
           "'"$PROJECT_ROOT"'/bin/v0" startup --help
       '
       assert_success
       assert_output --partial "Usage: v0 start"
   }

   @test "v0 --help does not show startup (hidden alias)" {
       run "$PROJECT_ROOT/bin/v0" --help
       assert_success
       refute_output --partial "startup"
       assert_output --partial "start"
   }
   ```

#### Update tests/v0-shutdown.bats

1. **Update existing tests** to use new command name in assertions:
   - Change `assert_output --partial "Usage: v0 shutdown"` to `assert_output --partial "Usage: v0 stop"`
   - Change `assert_output --partial "shutdown"` to `assert_output --partial "stop"` in main help test

2. **Add new tests** for alias functionality:
   ```bash
   @test "shutdown is a hidden alias for stop" {
       local project_dir
       project_dir=$(setup_isolated_project)

       run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
           cd "'"${project_dir}"'" || exit 1
           "'"${PROJECT_ROOT}"'/bin/v0" shutdown --help
       '
       assert_success
       assert_output --partial "Usage: v0 stop"
   }

   @test "v0 --help does not show shutdown (hidden alias)" {
       run "${PROJECT_ROOT}/bin/v0" --help
       assert_success
       refute_output --partial "shutdown"
       assert_output --partial "stop"
   }
   ```

**Verification:** Run `scripts/test v0-startup v0-shutdown`

### Phase 5: Update Documentation (Optional)

If `docs/arch/commands/v0-startup.md` and `docs/arch/commands/v0-shutdown.md` exist, consider:
- Renaming to `v0-start.md` and `v0-stop.md`
- Or adding a note about the command rename

**Verification:** Manual review of docs

### Phase 6: Final Verification

Run full test suite:
```bash
make check
```

This runs lints and all tests to ensure nothing is broken.

## Key Implementation Details

### Alias Pattern

The hidden alias pattern routes old command names through the dispatcher without showing them in help:

```bash
# Primary commands (shown in help)
stop|start)
    exec "${V0_DIR}/bin/v0-${CMD}" "$@"
    ;;

# Hidden aliases (old names, not shown in help)
startup)
    exec "${V0_DIR}/bin/v0-start" "$@"
    ;;
shutdown)
    exec "${V0_DIR}/bin/v0-stop" "$@"
    ;;
```

### Symlink vs Copy

Using symlinks (`v0-start -> v0-startup`) allows:
- Single source of truth for implementation
- Both names invoke the same script
- The script can detect how it was called via `$0` if needed (though not required here)

### Help Text Consistency

Both the main dispatcher and individual commands show the new name:
- `v0 --help` shows `start` and `stop`
- `v0 start --help` shows `Usage: v0 start ...`
- `v0 startup --help` also shows `Usage: v0 start ...` (since it runs the same script)

## Verification Plan

1. **Unit tests pass:** `scripts/test v0-startup v0-shutdown`
2. **Lint passes:** `make lint`
3. **Full suite passes:** `make check`
4. **Manual verification:**
   - `v0 --help` shows `start`/`stop`, not `startup`/`shutdown`
   - `v0 start --help` shows correct usage
   - `v0 stop --help` shows correct usage
   - `v0 startup --dry-run` works (alias)
   - `v0 shutdown --dry-run` works (alias)
