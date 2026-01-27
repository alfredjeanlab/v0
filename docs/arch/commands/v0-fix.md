# v0-fix

**Purpose:** Sequential bug fix worker.

## Workflow

**Start worker:**
1. Create worktree at `${V0_DEVELOP_BRANCH}-bugs` branch (e.g., `v0/agent/alice-a3f2-bugs`)
2. Setup hooks and helper scripts
3. Start polling loop and launch Claude in tmux

**Worker loop:**
1. Poll for bugs with `wk ready --type bug`
2. Run `./new-branch <id>` to reset to main
3. Claude implements the fix
4. Run `./fixed <id>` to push, queue merge, close issue
5. Exit session and repeat

## The `./fixed` Script

When Claude completes a fix, it runs `./fixed <id>` which performs:

```
┌─────────────────────────────────────────────────┐
│               ./fixed <issue-id>                │
├─────────────────────────────────────────────────┤
│ 1. Push commits as fix/<id> branch to agent     │
│ 2. Create state file in .v0/build/fix/<id>/     │
│ 3. Call v0-mergeq --enqueue fix/<id>            │
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
v0 fix "Button not working"   # Report a bug
v0 fix --start                # Start worker
v0 fix --stop                 # Stop worker
v0 fix --status               # Show status
v0 fix --logs                 # Show logs
v0 fix --history              # Show completed
```
