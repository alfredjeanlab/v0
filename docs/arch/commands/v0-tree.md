# v0-tree

**Purpose:** Create and manage git worktrees.

## Workflow

1. Check for existing worktree
2. Create directory (XDG preferred, `.git/` fallback)
3. Run `git worktree add`
4. Sync Claude settings
5. Run init hook if configured

## Usage

```bash
v0 tree feature/auth                                      # Create worktree
v0 tree v0-fix-worker --branch v0/agent/alice-a3f2-bugs   # Specify branch
```

Outputs two lines: TREE_DIR path, then WORKTREE path.

## Storage

1. `~/.local/state/v0/{project}/tree/<name>/` (preferred)
2. `.git/v0-worktrees/<name>/` (fallback)
