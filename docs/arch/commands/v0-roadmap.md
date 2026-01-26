# v0-roadmap

**Purpose:** Orchestrate autonomous work using a roadmap.

See [roadmap/state.md](../roadmap/state.md) for state machine, phases, and state file schema.

## Usage

```bash
v0 roadmap rewrite "Rewrite the entire frontend in React"
v0 roadmap api "Build a comprehensive REST API"
v0 roadmap --status                    # Show status of all roadmaps
v0 roadmap rewrite --resume            # Resume existing roadmap
v0 roadmap api --resume --attach       # Resume and follow logs
v0 roadmap test --foreground           # Run in foreground (blocking)
v0 roadmap test --dry-run              # Show what would happen
```

## Options

| Flag | Description |
|------|-------------|
| `--resume` | Resume an existing roadmap operation |
| `--status` | Show status of all roadmaps |
| `--dry-run` | Show what would happen without executing |
| `--attach` | Follow worker logs after launching |
| `--foreground` | Run in foreground (blocking) |

## Session Setup (v0-roadmap-worker)

Creates in worktree:
- `CLAUDE.md` - From `lib/templates/claude.roadmap.m4`
- `ROADMAP.md` - From `lib/prompts/roadmap.md`
- `done` / `incomplete` - Exit scripts

## Worktree Structure

The `v0-tree` command returns two paths:
- `TREE_DIR`: Parent directory where the worktree is created
- `WORKTREE`: The actual git worktree directory (repo checkout)

Files like `CLAUDE.md`, `done`, and `incomplete` are placed in `TREE_DIR`.
The agent should `cd` into the repository subdirectory for git operations.

Example:
```
TREE_DIR=/Users/x/.local/state/v0/proj/tree/roadmap/rewrite/
WORKTREE=/Users/x/.local/state/v0/proj/tree/roadmap/rewrite/myrepo/
```

## Logs

- `.v0/build/roadmaps/<name>/logs/worker.log`
- `.v0/build/roadmaps/<name>/logs/events.log`
