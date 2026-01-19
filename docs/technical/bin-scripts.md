# Bin Scripts Reference

This document describes the workflow of each script in the `bin/` directory.

## Overview

```
bin/
├── v0                    # Main entry point / dispatcher
├── v0-attach             # Attach to tmux sessions
├── v0-cancel             # Cancel running operations
├── v0-chore              # Chore processing worker
├── v0-coffee             # System wake lock management
├── v0-decompose          # Convert plans to issues
├── v0-feature            # Full feature pipeline
├── v0-feature-worker     # Background worker for features
├── v0-fix                # Bug fix worker
├── v0-hold               # Pause operations
├── v0-merge              # Merge worktree to main
├── v0-mergeq             # Merge queue daemon
├── v0-monitor            # Auto-shutdown monitor
├── v0-nudge              # Idle session monitoring
├── v0-plan               # Create implementation plans
├── v0-plan-exec          # Plan execution helper
├── v0-prune              # Clean up old state
├── v0-self-debug         # Generate debug reports
├── v0-shutdown           # Stop all workers
├── v0-startup            # Start all workers
├── v0-status             # Show operation status
├── v0-talk               # Quick Claude conversations
├── v0-tree               # Worktree management
└── v0-watch              # Continuous status display
```

---

## v0

**Purpose:** Main CLI entry point and command dispatcher.

**Workflow:**
1. Parse command from arguments
2. Handle special commands (`init`, `help`, `version`)
3. Dispatch to appropriate `v0-<command>` script
4. Support command aliases (`feat` → `feature`, `decomp` → `decompose`)

**Commands:**
- `v0 init` → Initialize `.v0.rc` in current directory
- `v0 <command> [args]` → Dispatch to `v0-<command>`

---

## v0-attach

**Purpose:** Attach to running tmux sessions for workers or operations.

**Workflow:**
1. Parse target type (fix, chore, mergeq, feature)
2. Determine session name from project config
3. For features: look up session name from state file
4. Attach to tmux session if it exists

**Usage:**
```bash
v0 attach fix                # Attach to fix worker
v0 attach chore              # Attach to chore worker
v0 attach mergeq             # Attach to merge queue
v0 attach feature <name>     # Attach to feature session
```

---

## v0-cancel

**Purpose:** Cancel running operations and clean up resources.

**Workflow:**
1. Find operation state file
2. Kill associated tmux session if running
3. Update state to `cancelled`
4. Optionally clean up worktree

**Usage:**
```bash
v0 cancel <operation-name>
v0 cancel <operation-name> --clean  # Also remove worktree
```

---

## v0-chore

**Purpose:** Sequential chore processing worker.

**Workflow:**
1. **Start worker** (`--start`):
   - Create worktree at `v0/worker/chore` branch
   - Copy `claude.chore.md` template
   - Set up hooks (Stop, PostToolUse, PreCompact, SessionStart)
   - Start polling loop for new chores
   - Launch Claude in tmux session

2. **Report chore** (`v0 chore "description"`):
   - Create chore issue via `wk new chore`
   - Ensure worker is running

3. **Worker loop**:
   - Poll for chores with `wk ready --type chore`
   - Start chore: `wk start <id>`
   - Reset to main: `./new-branch <id>`
   - Claude implements fix
   - Complete: `./fixed <id>` (push, queue merge, close)
   - Exit session to keep context small
   - Polling manager relaunches for next chore

**Scripts created in worktree:**
- `new-branch <id>` - Reset to main, prepare branch
- `fixed <id>` - Push, queue merge, close chore, exit
- `done` - Clean exit for worker

---

## v0-coffee

**Purpose:** Keep system awake during long-running operations.

**Workflow:**
1. Start: Launch `caffeinate` process in background
2. Stop: Kill `caffeinate` process
3. Status: Check if caffeinate is running

**Usage:**
```bash
v0 coffee              # Start default (8 hours)
v0 coffee 4            # Start for 4 hours
v0 coffee --stop       # Stop
v0 coffee --status     # Check status
```

---

## v0-decompose

**Purpose:** Convert a plan file into trackable issues.

**Workflow:**
1. Read plan file
2. Launch Claude to:
   - Parse plan structure
   - Create feature issue as epic
   - Create task issues for each work item
   - Label all issues with `plan:<name>`
3. Update plan file with feature ID

**Usage:**
```bash
v0 decompose plans/auth.md
```

---

## v0-feature

**Purpose:** Full autonomous feature pipeline.

**Workflow:**

1. **Initialize** (new operation):
   - Create state file in `operations/<name>/`
   - Handle `--after` dependencies
   - Handle `--plan` for existing plans

2. **Plan phase** (`init` → `planned`):
   - Create worktree
   - Launch `v0-plan` in tmux
   - Wait for plan file creation
   - Auto-commit plan

3. **Decompose phase** (`planned` → `queued`):
   - Run `v0-decompose` on plan
   - Create issues labeled `plan:<name>`
   - Extract epic ID

4. **Execute phase** (`queued` → `executing` → `completed`):
   - Create worktree with feature branch
   - Generate `CLAUDE.md` from template
   - Set up hooks
   - Launch Claude with plan context
   - On completion, run `on-complete.sh`

5. **Merge phase** (if `merge_queued`):
   - Add to merge queue
   - Transition to `pending_merge`

**Modes:**
- Default: Queue and run in background
- `--foreground`: Run blocking
- `--enqueue`: Plan + decompose only
- `--resume`: Continue from current phase

---

## v0-feature-worker

**Purpose:** Background worker process for feature operations.

**Workflow:**
1. Load operation state
2. Execute phases based on current state
3. Handle transitions and errors
4. Log progress to worker log

---

## v0-fix

**Purpose:** Sequential bug fix worker.

**Workflow:**
1. **Start worker** (`--start`):
   - Create worktree at `v0/worker/fix` branch
   - Copy `claude.fix.md` template
   - Set up hooks
   - Start polling loop
   - Launch Claude in tmux

2. **Report bug** (`v0 fix "description"`):
   - Create bug issue via `wk new bug`
   - Ensure worker is running

3. **Worker loop**:
   - Poll for bugs with `wk ready --type bug`
   - Start bug: `wk start <id>`
   - Reset to main: `./new-branch <id>`
   - Claude implements fix
   - Complete: `./fixed <id>`
   - Exit and relaunch

**Scripts created in worktree:**
- `new-branch <id>` - Reset to main, prepare branch
- `fixed <id>` - Push, queue merge, close bug, exit
- `done` - Clean exit

---

## v0-hold

**Purpose:** Pause operation phase transitions.

**Workflow:**
1. Find operation state
2. Set `held = true` and `held_at` timestamp
3. Operation completes current work then stops

**Usage:**
```bash
v0 hold <operation-name>     # Put on hold
v0 resume <operation-name>   # Release hold (via v0-feature --resume)
```

---

## v0-merge

**Purpose:** Merge a worktree branch to main.

**Workflow:**
1. Verify worktree has commits
2. Fetch latest main
3. Attempt merge (fast-forward or regular)
4. If conflict:
   - `--resolve`: Launch Claude to resolve
   - Otherwise: Report conflict
5. Push merged main
6. Delete feature branch

**Usage:**
```bash
v0 merge /path/to/worktree
v0 merge /path/to/worktree --resolve  # Auto-resolve conflicts
```

---

## v0-mergeq

**Purpose:** Merge queue daemon for processing merges sequentially.

**Workflow:**
1. **Start** (`--start`):
   - Start daemon process in background
   - Write PID file

2. **Enqueue** (`--enqueue <op>`):
   - Add operation to queue.json
   - Ensure daemon is running

3. **Watch loop** (`--watch`):
   - Poll every 30 seconds
   - Check for ready operations
   - Process one merge at a time
   - Handle conflicts with auto-resolution
   - Trigger dependent operations on success

**Queue entry states:**
- `pending` → `processing` → `completed`
- `pending` → `processing` → `failed`
- `pending` → `processing` → `conflict`

---

## v0-monitor

**Purpose:** Monitor worker queues for auto-shutdown.

**Workflow:**
1. Check if workers have pending work
2. If all queues empty for threshold time:
   - Trigger shutdown
3. Used for unattended operation

---

## v0-nudge

**Purpose:** Monitor for idle Claude sessions.

**Workflow:**
1. Start monitor daemon
2. Periodically check tmux sessions
3. If session idle (no output):
   - Send nudge input to Claude
4. Helps prevent stuck sessions

---

## v0-plan

**Purpose:** Create implementation plans using Claude.

**Workflow:**
1. Parse name and instructions
2. Create state tracking
3. Launch `v0-plan-exec` (directly or in tmux)
4. Claude generates plan at `plans/<name>.md`
5. Auto-commit plan (unless `--draft`)

**Modes:**
- Default: Background execution
- `--foreground`: Blocking execution
- `--direct`: Direct execution (no tmux)

---

## v0-plan-exec

**Purpose:** Execute plan creation with Claude.

**Workflow:**
1. Set up Claude with plan prompt
2. Claude analyzes codebase
3. Creates structured plan file
4. Returns success/failure

---

## v0-prune

**Purpose:** Clean up old operation state and logs.

**Workflow:**
1. Find operations in terminal states
2. Remove state directories older than threshold
3. Prune log entries older than 6 hours
4. Clean up merge queue entries

**Usage:**
```bash
v0 prune              # Prune old state
v0 prune --dry-run    # Preview what would be pruned
```

---

## v0-self-debug

**Purpose:** Generate debug reports for troubleshooting.

**Workflow:**
1. Collect system info
2. Gather operation state
3. Extract relevant logs
4. Package into debug report

**Usage:**
```bash
v0 self debug <operation>
v0 self debug fix
v0 self debug mergeq
```

---

## v0-shutdown

**Purpose:** Stop all v0 workers for the project.

**Workflow:**
1. Find all v0 tmux sessions
2. Kill worker sessions (fix, chore)
3. Stop merge queue daemon
4. Stop coffee (caffeinate)
5. Stop nudge monitor

**Usage:**
```bash
v0 shutdown           # Stop all
v0 shutdown fix       # Stop only fix worker
```

---

## v0-startup

**Purpose:** Start all v0 workers for the project.

**Workflow:**
1. Parse worker list (default: all)
2. Start each worker via `v0-<worker> --start`
3. Start coffee for system wake lock
4. Start nudge for idle monitoring

**Usage:**
```bash
v0 startup              # Start all (fix, chore, mergeq)
v0 startup fix          # Start only fix
v0 startup fix chore    # Start fix and chore
```

---

## v0-status

**Purpose:** Show operation and worker status.

**Workflow:**
1. List all operations with current phase
2. Show worker status (running/stopped)
3. Show merge queue status
4. Display recent activity

**Usage:**
```bash
v0 status                  # Overview
v0 status <name>           # Specific operation
v0 status --fix            # Fix worker details
v0 status --merge          # Merge queue details
```

---

## v0-talk

**Purpose:** Quick Claude conversations (haiku model).

**Workflow:**
1. Launch Claude with haiku model
2. No persistent state
3. For quick questions/conversations

**Usage:**
```bash
v0 talk
```

---

## v0-tree

**Purpose:** Create and manage git worktrees.

**Workflow:**
1. Create worktree directory in state directory
2. Set up worktree with specified branch
3. Run worktree init hook if configured
4. Return worktree path

**Usage:**
```bash
v0 tree feature/auth
v0 tree v0-fix-worker --branch v0/worker/fix
```

**Output:**
```
/path/to/state/tree/feature/auth
/path/to/state/tree/feature/auth/repo
```

---

## v0-watch

**Purpose:** Continuously watch operation status.

**Workflow:**
1. Clear screen
2. Display current status
3. Refresh every N seconds
4. Exit on Ctrl+C

**Usage:**
```bash
v0 watch                # Default refresh
v0 watch -n 5           # 5 second refresh
v0 status --watch       # Alias
```
