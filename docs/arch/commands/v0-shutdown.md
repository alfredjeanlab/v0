# v0-shutdown

**Purpose:** Stop all v0 workers for the project.

## Workflow

1. Kill all v0 tmux sessions
2. Stop merge queue daemon
3. Reopen in-progress issues
4. Remove worker worktrees and branches
5. Stop coffee and nudge daemons
6. Optionally remove workspace/state (with --drop-* flags)

## Usage

```bash
v0 shutdown                    # Stop all
v0 shutdown --dry-run          # Preview
v0 shutdown --force            # Force kill, delete unmerged branches
v0 shutdown --drop-workspace   # Also remove workspace and worktrees
v0 shutdown --drop-everything  # Full reset (removes all v0 state)
```

## Cleanup Options

| Option | Removes |
|--------|---------|
| (default) | Sessions, daemons, worker branches/worktrees |
| `--drop-workspace` | + `~/.local/state/v0/${PROJECT}/workspace/` and `tree/` |
| `--drop-everything` | + `~/.local/state/v0/${PROJECT}/` and `.v0/build/` and `agent` remote |

The `--drop-everything` option performs a full reset. Run `v0 init` to reinitialize.
