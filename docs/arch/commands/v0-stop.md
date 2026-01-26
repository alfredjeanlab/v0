# v0-stop

**Purpose:** Stop v0 workers (individual or all).

## Usage

```bash
# Stop individual workers
v0 stop fix           # Stop the fix worker
v0 stop chore         # Stop the chore worker
v0 stop mergeq        # Stop the merge queue daemon
v0 stop nudge         # Stop the nudge daemon

# Full shutdown (all workers)
v0 stop               # Stop all workers
v0 stop --force       # Force kill, delete unmerged branches
v0 stop --dry-run     # Preview what would be stopped

# Workspace cleanup (full shutdown only)
v0 stop --drop-workspace   # Also remove workspace and worktrees
v0 stop --drop-everything  # Full reset (removes all v0 state)
```

## Workflow (full shutdown)

1. Kill all v0 tmux sessions
2. Stop merge queue daemon
3. Reopen in-progress issues
4. Remove worker worktrees and branches
5. Stop coffee and nudge daemons
6. Optionally remove workspace/state (with --drop-* flags)

## Cleanup Options

| Option | Removes |
|--------|---------|
| (default) | Sessions, daemons, worker branches/worktrees |
| `--drop-workspace` | + `~/.local/state/v0/${PROJECT}/workspace/` and `tree/` |
| `--drop-everything` | + `~/.local/state/v0/${PROJECT}/` and `.v0/build/` and `agent` remote |

The `--drop-everything` option performs a full reset. Run `v0 init` to reinitialize.

## Related

- [v0-start](v0-start.md) - Start workers
