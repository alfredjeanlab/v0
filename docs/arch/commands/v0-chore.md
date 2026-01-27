# v0-chore

**Purpose:** Sequential chore processing worker.

## Workflow

**Start worker:**
1. Create worktree at `${V0_DEVELOP_BRANCH}-chores` branch (e.g., `v0/agent/alice-a3f2-chores`)
2. Setup hooks and helper scripts
3. Start polling loop and launch Claude in tmux

**Worker loop:**
1. Poll for chores with `wk ready --type chore`
2. Run `./new-branch <id>` to reset to main
3. Claude implements the chore
4. Run `./fixed <id>` to push, queue merge, close issue
5. Exit session and repeat

## The `./fixed` Script

When Claude completes a chore, it runs `./fixed <id>` which performs:

```
┌─────────────────────────────────────────────────┐
│               ./fixed <issue-id>                │
├─────────────────────────────────────────────────┤
│ 1. Push commits as chore/<id> branch to agent   │
│ 2. Create state file in .v0/build/chore/<id>/   │
│ 3. Call v0-mergeq --enqueue chore/<id>          │
│    └─ Adds entry to queue.json                  │
│    └─ Calls mq_ensure_daemon_running            │
│       └─ If daemon not running, starts it       │
│       └─ If workspace missing, creates it       │
│ 4. Transfer issue ownership to worker:mergeq    │
│ 5. Mark issue as done (wk done)                 │
│ 6. Reset worktree to V0_DEVELOP_BRANCH          │
│ 7. Exit Claude session (touch .done-exit, kill) │
└─────────────────────────────────────────────────┘
```

**If enqueue fails:**
- Error logged to `merges.log` as `enqueue:failed`
- Warning printed to stderr
- Script continues (issue may need manual merge)

**If daemon fails to start:**
- Warning logged to `merges.log` as `enqueue:warning`
- Entry exists in queue but won't be processed
- Run `v0 mergeq --restart` to recover

## Usage

```bash
v0 chore "Update dependencies"   # Report a chore
v0 chore --start                 # Start worker
v0 chore --stop                  # Stop worker
v0 chore --status                # Show status
v0 chore --logs                  # Show logs
v0 chore --history               # Show completed
```

## Modes

- **Project mode**: Creates worktree, pushes branches, queues merges
- **Standalone mode**: No git/merge queue, works in current directory
