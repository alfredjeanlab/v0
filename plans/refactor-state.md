# Plan: Split lib/state-machine.sh into smaller files

## Problem
- `lib/state-machine.sh` is 1255 lines - too big to maintain and for Claude to read effectively
- No separation between pure business logic and code that calls external commands
- Future work (v0-mergeq refactor) would benefit from cleaner organization

## Goals
1. Split into smaller, focused files (~200-400 lines each)
2. Separate **pure** (no subprocess calls) from **impure** (calls jq, tmux, wk, date, etc.)
3. Minimize code changes - reorganize, don't rewrite
4. Impure modules can be integration tested in isolated temp directories

## Proposed File Structure

```
lib/
├── state-machine.sh              # Compat shim - sources lib/operations/state.sh
├── operations/
│   ├── state.sh                  # Orchestrator - sources all modules
│   ├── rules.sh                  # PURE: transition rules, terminal checks, paths
│   ├── format.sh                 # PURE: display formatting (no I/O)
│   ├── io.sh                     # IMPURE: JSON file read/write (jq, mktemp, mv)
│   ├── logging.sh                # IMPURE: event logging (date, mkdir, stat)
│   ├── schema.sh                 # IMPURE: schema versioning/migration
│   ├── transitions.sh            # IMPURE: phase transition functions
│   ├── recovery.sh               # IMPURE: resume/error clearing
│   ├── blocking.sh               # IMPURE: dependency management
│   ├── holds.sh                  # IMPURE: hold management
│   ├── merge-ready.sh            # IMPURE: merge readiness (tmux, wk)
│   └── display.sh                # IMPURE: status queries (tmux, jq)
└── mergeq/                       # (future - same pattern)
    ├── queue.sh                  # Orchestrator
    ├── rules.sh                  # PURE: queue entry states, priority
    ├── io.sh                     # IMPURE: queue.json read/write
    └── ...
```

## Module Breakdown

Function names keep `sm_` prefix (namespace when sourced into scripts).

### operations/rules.sh (~60 lines) - PURE
No subprocess calls. Shell builtins only.

```
SM_STATE_VERSION=1
SM_LOG_MAX_SIZE=102400
SM_LOG_KEEP_COUNT=3

sm_get_state_file()        # Path string construction
sm_state_exists()          # [[ -f ]] check (shell builtin)
sm_allowed_transitions()   # Case statement returning valid transitions
sm_is_terminal_phase()     # Simple string comparison
```

### operations/format.sh (~120 lines) - PURE
No subprocess calls. Formatting logic only.

```
_sm_format_phase_display()  # Format phase for display
_sm_get_phase_color()       # Phase to color name mapping
_sm_get_merge_icon_color()  # Icon to color name mapping
sm_get_status_color()       # Color name to ANSI code (printf builtin)
```

### operations/io.sh (~150 lines) - IMPURE
External: `jq`, `mktemp`, `mv`, `rm`

```
sm_read_state()             # Read single field via jq
sm_update_state()           # Update single field
sm_bulk_update_state()      # Atomic multi-field update
sm_read_state_fields()      # Batch read optimization
sm_read_all_state()         # Read entire state as assoc array
sm_get_state_version()      # Read schema version
```

### operations/logging.sh (~50 lines) - IMPURE
External: `date`, `mkdir`, `stat`, `mv`, `rm`

```
sm_emit_event()             # Log event with rotation
sm_rotate_log()             # Rotate log files
```

### operations/schema.sh (~50 lines) - IMPURE
External: `date` (via sm_bulk_update_state, sm_emit_event)

```
sm_migrate_state()          # Migrate to current schema
sm_ensure_current_schema()  # Auto-migrate on access
sm_get_phase()              # Get phase (ensures schema first)
```

### operations/transitions.sh (~220 lines) - IMPURE
External: `date`, `jq` (via helpers)

```
sm_can_transition()         # Check if transition valid
_sm_do_transition()         # Internal transition helper
sm_transition_to_planned()
sm_transition_to_queued()
sm_transition_to_blocked()
sm_transition_to_executing()
sm_transition_to_completed()
sm_transition_to_pending_merge()
sm_transition_to_merged()
sm_transition_to_failed()
sm_transition_to_conflict()
sm_transition_to_interrupted()
sm_transition_to_cancelled()
```

### operations/recovery.sh (~60 lines) - IMPURE
External: via sm_read_state, sm_bulk_update_state, sm_emit_event

```
sm_get_resume_phase()       # Determine resume point
sm_clear_error_state()      # Clear error and set resume phase
```

### operations/blocking.sh (~120 lines) - IMPURE
External: `jq`, spawns `v0-feature`

```
sm_is_blocked()
sm_get_blocker()
sm_get_blocker_status()
sm_is_blocker_merged()
sm_unblock_operation()
sm_find_dependents()
sm_trigger_dependents()     # Spawns v0-feature in background
```

### operations/holds.sh (~120 lines) - IMPURE
External: `date` (via helpers)

```
sm_is_held()
sm_set_hold()
sm_clear_hold()
sm_exit_if_held()
sm_transition_to_planned_and_hold()
sm_transition_to_queued_and_hold()
```

### operations/merge-ready.sh (~100 lines) - IMPURE
External: `tmux`, `wk`, `wc`, `tr`

```
sm_is_merge_ready()
sm_all_issues_closed()
sm_merge_ready_reason()
sm_should_auto_merge()
```

### operations/display.sh (~100 lines) - IMPURE
External: `tmux`, `jq`

```
sm_get_display_status()
sm_get_merge_display_status()
sm_is_active_operation()
```

### operations/state.sh (~30 lines) - Orchestrator
Sources all modules in dependency order:

```bash
#!/bin/bash
# Orchestrator - sources all operations state machine modules

_OP_LIB_DIR="${V0_DIR}/lib/operations"

source "${_OP_LIB_DIR}/rules.sh"
source "${_OP_LIB_DIR}/format.sh"
source "${_OP_LIB_DIR}/io.sh"
source "${_OP_LIB_DIR}/logging.sh"
source "${_OP_LIB_DIR}/schema.sh"
source "${_OP_LIB_DIR}/transitions.sh"
source "${_OP_LIB_DIR}/recovery.sh"
source "${_OP_LIB_DIR}/blocking.sh"
source "${_OP_LIB_DIR}/holds.sh"
source "${_OP_LIB_DIR}/merge-ready.sh"
source "${_OP_LIB_DIR}/display.sh"
```

### lib/state-machine.sh (~5 lines) - Compat shim
Backward compatibility for existing code:

```bash
#!/bin/bash
# Compat shim - sources lib/operations/state.sh
source "${V0_DIR}/lib/operations/state.sh"
```

## Dependency Order

```
Level 0 (no dependencies):
  operations/rules.sh
  operations/format.sh

Level 1 (depends on rules):
  operations/io.sh
  operations/logging.sh

Level 2 (depends on io, logging):
  operations/schema.sh

Level 3 (depends on schema, io, logging):
  operations/transitions.sh
  operations/recovery.sh
  operations/display.sh

Level 4 (depends on transitions):
  operations/blocking.sh
  operations/holds.sh
  operations/merge-ready.sh
```

## Implementation Steps

1. Create `lib/operations/` directory
2. Create new files with appropriate headers (copy license/copyright)
3. Move functions to their new homes (cut/paste, no rewrites)
4. Create `lib/operations/state.sh` orchestrator
5. Update `lib/state-machine.sh` to be a compat shim
6. Run `make lint` and `make test` to verify
7. Commit as single commit (atomic refactor)

## Future: lib/mergeq/

When refactoring v0-mergeq, follow same pattern:

```
lib/mergeq/
├── queue.sh             # Orchestrator
├── rules.sh             # PURE: entry states, priority logic
├── io.sh                # IMPURE: queue.json read/write
├── transitions.sh       # IMPURE: entry status changes
├── locking.sh           # IMPURE: queue file locking
└── display.sh           # IMPURE: queue status display
```

Functions would use `mq_` prefix (e.g., `mq_enqueue()`, `mq_dequeue()`).

## Verification

1. `make lint` - all new files pass shellcheck
2. `make test` - existing tests still pass
3. Manual: `v0 status`, `v0 feature --help` work as before
