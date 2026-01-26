# v0 System Architecture

This document describes the runtime architecture of v0: processes, directories, environment variables, and inter-process coordination.

## Workers and Processes

v0 runs several background workers, each with its own PID file for lifecycle management.

### Worker Types

| Worker | Command | PID File | Purpose |
|--------|---------|----------|---------|
| **Merge Queue** | `v0 mergeq --watch` | `${BUILD_DIR}/mergeq/.daemon.pid` | Serializes merges to develop branch |
| **Fix Worker** | `v0 fix --start` | `${BUILD_DIR}/fix/.daemon.pid` | Processes bug issues from wok |
| **Chore Worker** | `v0 chore --start` | `${BUILD_DIR}/chore/.daemon.pid` | Processes chore issues |
| **Nudge Daemon** | `v0 nudge daemon` | `${BUILD_DIR}/nudge/.daemon.pid` | Monitors idle tmux sessions |
| **Coffee** | `v0 coffee` | `${BUILD_DIR}/coffee/.pid` | Prevents system sleep |
| **Prune Daemon** | (internal) | `${BUILD_DIR}/prune/.daemon.pid` | Cleans stale state |

### Starting/Stopping Workers

```bash
v0 startup              # Start fix, chore, mergeq workers
v0 shutdown             # Stop all workers gracefully
v0 status               # Show worker status
```

### Process Lifecycle

Each worker follows a common pattern:
1. Check PID file exists and process is running (`kill -0 $pid`)
2. If stale PID file (process dead), remove it
3. Start new process via `nohup` with output to log file
4. Write new PID to PID file

See: [v0-start](commands/v0-start.md), [v0-stop](commands/v0-stop.md)

## Directory Structure

### Project-Local Directories

| Path | Purpose |
|------|---------|
| `${V0_ROOT}/` | Project root (contains `.v0.rc`) |
| `${V0_ROOT}/.v0/` | Local build state (gitignored) |
| `${V0_ROOT}/.v0/build/` | `BUILD_DIR` - operations, workers, queues |
| `${V0_ROOT}/.v0/build/operations/<name>/` | Per-operation state and logs |
| `${V0_ROOT}/.v0/build/mergeq/` | Merge queue state |
| `${V0_ROOT}/plans/` | Implementation plans (git-tracked) |

### Global State Directory

| Path | Purpose |
|------|---------|
| `~/.local/state/v0/` | Per-project state |
| `~/.local/state/v0/${PROJECT}/` | `V0_STATE_DIR` - project-specific |
| `~/.local/state/v0/${PROJECT}/workspace/` | Workspace for merge operations |
| `~/.local/state/v0/${PROJECT}/tree/` | Feature worktrees |
| `~/.local/state/v0/${PROJECT}/remotes/agent.git` | Local bare repo for worker branches |
| `~/.local/state/v0/standalone/` | Standalone chore worker state |

### Key Files

| File | Purpose |
|------|---------|
| `.v0.rc` | Project configuration |
| `.v0.root` | Project root path (for `v0 watch --all`) |
| `state.json` | Operation state (per-operation) |
| `queue.json` | Merge queue entries |
| `.daemon.pid` | Worker process ID |
| `daemon.log` | Worker output log |

## Git Remote Architecture

v0 uses a configurable git remote (`V0_GIT_REMOTE`) for all push/fetch operations. By default, this is a **local bare repository** rather than the shared origin.

### Local Agent Remote (Default)

When you run `v0 init`, it creates a local bare git repository:

```
~/.local/state/v0/${PROJECT}/remotes/agent.git
```

**Initialization steps:**
1. Creates bare clone: `git clone --bare ${V0_ROOT} ${agent_dir}`
2. Adds remote to project: `git remote add agent ${agent_dir}`
3. Sets `V0_GIT_REMOTE="agent"` in `.v0.rc`

**Benefits:**
- Worker branches don't pollute shared origin
- Multiple users can run v0 without branch conflicts
- Faster push/fetch (local filesystem)
- Works offline

**Workflow:**
```
User Branch ←──v0 pull──→ Agent Branch (local) ──manual push──→ Origin
            ───v0 push──→
```

### Shared Origin Remote

To use the traditional shared remote instead:

```bash
# During init
v0 init --remote origin

# Or edit .v0.rc
V0_GIT_REMOTE="origin"
```

**When to use origin:**
- CI/CD environments (no persistent local state)
- Team wants centralized branch visibility
- Single-user projects where simplicity preferred

**Workflow:**
```
User Branch ←──v0 pull──→ Agent Branch (origin)
            ───v0 push──→
```

### Remote Configuration Summary

| Setting | `V0_GIT_REMOTE="agent"` | `V0_GIT_REMOTE="origin"` |
|---------|-------------------------|--------------------------|
| Worker branches | Local only | Visible to team |
| Multi-user safe | Yes (isolated) | Requires coordination |
| Offline capable | Yes | No |
| Setup | Automatic (`v0 init`) | `v0 init --remote origin` |

## Environment Variables

### Required (set by `.v0.rc`)

| Variable | Description | Example |
|----------|-------------|---------|
| `PROJECT` | Project identifier | `"myproject"` |
| `ISSUE_PREFIX` | Wok issue prefix | `"proj"` |

### Computed (set by `v0_load_config`)

| Variable | Description | Default |
|----------|-------------|---------|
| `V0_ROOT` | Project root directory | (from `.v0.rc` location) |
| `V0_STATE_DIR` | Global state directory | `~/.local/state/v0/${PROJECT}` |
| `V0_AGENT_REMOTE_DIR` | Local agent remote | `${V0_STATE_DIR}/remotes/agent.git` |
| `BUILD_DIR` | Build state directory | `${V0_ROOT}/.v0/build` |
| `PLANS_DIR` | Plans directory | `${V0_ROOT}/plans` |
| `REPO_NAME` | Repository name | `$(basename ${V0_ROOT})` |

### Configurable (in `.v0.rc`)

| Variable | Description | Default |
|----------|-------------|---------|
| `V0_DEVELOP_BRANCH` | Target branch for merges | `v0/agent/{username}-{id}` |
| `V0_WORKSPACE_MODE` | `"worktree"` or `"clone"` | (auto-detected) |
| `V0_GIT_REMOTE` | Git remote name | `"agent"` |
| `V0_FEATURE_BRANCH` | Feature branch pattern | `"feature/{name}"` |
| `V0_BUGFIX_BRANCH` | Bugfix branch pattern | `"fix/{id}"` |
| `V0_CHORE_BRANCH` | Chore branch pattern | `"chore/{id}"` |
| `V0_WORKTREE_INIT` | Hook to run in new worktrees | (none) |

### Runtime Variables

| Variable | Description |
|----------|-------------|
| `V0_DIR` / `V0_INSTALL_DIR` | v0 installation directory |
| `V0_WORKSPACE_DIR` | Workspace path for merge operations |
| `MERGEQ_DIR` | Merge queue directory |
| `DAEMON_PID_FILE` | Current daemon's PID file |
| `DAEMON_LOG_FILE` | Current daemon's log file |

## Inter-Process Coordination

### File-Based Locking

The merge queue uses file-based locking to prevent concurrent modifications:

```
${MERGEQ_DIR}/.queue.lock
```

- Lock acquired with `flock` before queue modifications
- Released immediately after update
- Stale lock detection via PID check

### State Machine Transitions

Operations follow a state machine (see [operations/state.md](operations/state.md)):

```
init → planned → queued → executing → completed → pending_merge → merged
```

State transitions are atomic JSON updates to `state.json`.

### Daemon Coordination

- **Single daemon per project**: PID files prevent duplicate workers
- **Workspace isolation**: Merge operations run in dedicated workspace
- **Queue serialization**: Only one merge processes at a time

### Tmux Sessions

Feature operations run in tmux sessions:

| Session Pattern | Purpose |
|-----------------|---------|
| `v0-${PROJECT}-${name}-feature` | Feature development |
| `v0-${PROJECT}-fix-worker` | Fix worker |
| `v0-${PROJECT}-chore-worker` | Chore worker |
| `v0-${PROJECT}-merge-${branch}` | Conflict resolution |

### Worker Branches

Worker branches are derived from `V0_DEVELOP_BRANCH` using a hyphenated suffix:

| Worker | Branch Pattern | Example |
|--------|----------------|---------|
| Fix | `${V0_DEVELOP_BRANCH}-bugs` | `v0/agent/alice-a3f2-bugs` |
| Chore | `${V0_DEVELOP_BRANCH}-chores` | `v0/agent/alice-a3f2-chores` |

**Why user-specific worker branches?**
- Prevents conflicts when multiple users share the same remote
- Prevents conflicts when multiple v0 instances run on the same project
- Clear ownership (branch path shows who it belongs to)

Legacy branches (`v0/worker/fix`, `v0/worker/chore`) are still cleaned up by `v0 shutdown`.

The helper function `v0_worker_branch()` in `packages/core/lib/config.sh` generates these names.

### Event Hooks

Claude Code hooks in `packages/hooks/` handle session events:
- `stop-fix.sh` - Fix worker completion
- `stop-feature.sh` - Feature completion
- `notify-progress.sh` - Progress notifications

## Critical Path: Main Repo vs Workspace

When running from a workspace (worktree or clone), certain paths must point to the main repository:

| Variable | Must Point To | Why |
|----------|---------------|-----|
| `MERGEQ_DIR` | Main repo | Single queue shared across worktrees |
| `BUILD_DIR` | Main repo | State files live in main repo's `.v0/` |
| `V0_WORKSPACE_DIR` | Workspace | Git operations run here |

The function `v0_find_main_repo()` resolves the main repository from any worktree.

See: [WORKSPACE.md](WORKSPACE.md) for detailed workspace architecture.

## State Cleanup

The `v0 stop` command supports progressive cleanup levels:

| Command | What it removes |
|---------|-----------------|
| `v0 stop` | Sessions, daemons, worker branches/worktrees |
| `v0 stop --drop-workspace` | + workspace and feature worktrees |
| `v0 stop --drop-everything` | + entire state dir, build state, agent remote |

**Directories affected:**

```
v0 stop --drop-workspace removes:
  ~/.local/state/v0/${PROJECT}/workspace/   # Merge workspace
  ~/.local/state/v0/${PROJECT}/tree/        # Feature worktrees

v0 stop --drop-everything additionally removes:
  ~/.local/state/v0/${PROJECT}/             # Entire state dir (includes agent.git)
  ${V0_ROOT}/.v0/build/                     # Build state
  'agent' git remote                        # Local bare repo reference
```

After `--drop-everything`, run `v0 init` to reinitialize the project.

## Related Documentation

- [WORKSPACE.md](WORKSPACE.md) - Clone vs worktree workspace modes
- [operations/state.md](operations/state.md) - Operation lifecycle state machine
- [mergeq/state.md](mergeq/state.md) - Merge queue state machine
- [commands/](commands/) - Individual command documentation
