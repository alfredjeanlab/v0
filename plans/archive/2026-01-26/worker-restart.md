# Implementation Plan: Worker Restart

## Overview

Add support for `v0 [chore/fix/mergeq/nudge] --restart` flag that performs a stop followed by a start. Also add `restart` as a hidden positional alias (e.g., `v0 fix restart`) for consistency with existing `start`/`stop` aliases.

## Project Structure

Files to modify:
```
bin/v0-fix      # Worker command for bug fixing
bin/v0-chore    # Worker command for chores
bin/v0-mergeq   # Daemon command for merge queue
bin/v0-nudge    # Daemon command for session monitoring
```

## Dependencies

None - uses existing start/stop functions in each command.

## Implementation Phases

### Phase 1: Add --restart to v0-fix

**File:** `bin/v0-fix`

1. Add `--restart` case to argument parsing (~line 677, after `--stop`):
   ```bash
   --restart)
     ACTION="restart"
     shift
     ;;
   ```

2. Add `restart` positional alias (~line 739, after `stop)` case):
   ```bash
   restart)
     # Auto-correct 'v0 fix restart' to 'v0 fix --restart'
     ACTION="restart"
     shift
     ;;
   ```

3. Add `restart)` case to main dispatch (~line 755, after `stop)`):
   ```bash
   restart)
     stop_worker
     start_worker
     ;;
   ```

### Phase 2: Add --restart to v0-chore

**File:** `bin/v0-chore`

1. Add `--restart` case to argument parsing (~line 852, after `--stop`):
   ```bash
   --restart)
     ACTION="restart"
     shift
     ;;
   ```

2. Add `restart` positional alias (~line 914, after `stop)` case):
   ```bash
   restart)
     # Auto-correct 'v0 chore restart' to 'v0 chore --restart'
     ACTION="restart"
     shift
     ;;
   ```

3. Add `restart)` case to main dispatch (~line 930, after `stop)`):
   ```bash
   restart)
     stop_worker
     start_worker
     ;;
   ```

### Phase 3: Add --restart to v0-mergeq

**File:** `bin/v0-mergeq`

1. Add `--restart` case to argument parsing (~line 88, after `--stop`):
   ```bash
   --restart) ACTION="restart"; shift ;;
   ```

2. Add `restart)` case to main dispatch (~line 132, after `stop)`):
   ```bash
   restart)
     mq_stop_daemon
     mq_start_daemon
     ;;
   ```

### Phase 4: Add restart to v0-nudge

**File:** `bin/v0-nudge`

1. Add `cmd_restart()` function (~line 274, after `cmd_stop()`):
   ```bash
   cmd_restart() {
     cmd_stop
     cmd_start
   }
   ```

2. Add `restart` case to main dispatch (~line 319, after `stop)`):
   ```bash
   restart) cmd_restart ;;
   ```

3. Update usage() to document the restart command (~line 34, after `stop`):
   ```bash
   restart   Restart the nudge daemon (stop + start)
   ```

## Key Implementation Details

### Restart Semantics

The restart operation is intentionally simple: stop followed by start. This ensures:
- Clean shutdown of existing processes/sessions
- Fresh initialization with current configuration
- No complex state preservation needed

### Error Handling

- If stop fails (e.g., worker not running), start should still proceed
- The existing `stop_worker`/`cmd_stop` functions already handle "not running" cases gracefully
- Start functions already check if worker is running and exit early if so

### Hidden vs Documented Aliases

- `--restart` flag: Documented in v0-nudge only (it uses positional subcommands)
- `restart` positional: Hidden in v0-fix/v0-chore/v0-mergeq (like `start`/`stop`)
- This maintains consistency with the existing pattern where worker commands document flags and daemon commands document subcommands

## Verification Plan

1. **Manual verification of each command:**
   ```bash
   # Test v0 fix --restart
   v0 fix --start && sleep 2 && v0 fix --restart && v0 fix --status
   v0 fix --stop

   # Test v0 chore --restart
   v0 chore --start && sleep 2 && v0 chore --restart && v0 chore --status
   v0 chore --stop

   # Test v0 mergeq --restart
   v0 mergeq --start && sleep 2 && v0 mergeq --restart && v0 mergeq --status
   v0 mergeq --stop

   # Test v0 nudge restart
   v0 nudge start && sleep 2 && v0 nudge restart && v0 nudge status
   v0 nudge stop
   ```

2. **Test hidden positional aliases:**
   ```bash
   v0 fix restart      # Should work like --restart
   v0 chore restart    # Should work like --restart
   ```

3. **Test restart when not running:**
   ```bash
   v0 fix --stop       # Ensure stopped
   v0 fix --restart    # Should start successfully
   v0 fix --stop
   ```

4. **Lint check:**
   ```bash
   make lint
   ```

5. **Run existing tests:**
   ```bash
   scripts/test
   ```
