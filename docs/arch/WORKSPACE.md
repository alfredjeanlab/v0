# Workspace Architecture: Clone vs Worktree

This document provides an in-depth explanation of v0's workspace modes, their differences, and implications for operations, merges, and push/pull workflows.

## Overview

v0 uses a dedicated **workspace** for merge operations, separate from the main repository. This workspace can be created in two modes:

| Mode | Creation | Git Structure | Use Case |
|------|----------|---------------|----------|
| **Worktree** | `git worktree add` | Shared `.git` | When develop branch ≠ main |
| **Clone** | `git clone` (local) | Independent `.git` | When develop branch = main |

## Why a Separate Workspace?

The workspace exists because:

1. **Branch isolation**: Merge operations need to checkout the develop branch, but users may be working on other branches in `V0_ROOT`
2. **Conflict safety**: If a merge conflicts, the workspace can be reset without affecting user work
3. **Daemon operations**: The merge queue daemon runs continuously and needs a stable checkout

## Mode Selection

### Auto-Detection Logic

```bash
# packages/core/lib/config.sh
v0_infer_workspace_mode() {
  local develop_branch="${1:-${V0_DEVELOP_BRANCH:-main}}"
  case "${develop_branch}" in
    main|develop|master) echo "clone" ;;
    *) echo "worktree" ;;
  esac
}
```

### When Each Mode is Used

| Develop Branch | Mode | Reason |
|----------------|------|--------|
| `main` | Clone | Cannot have `main` checked out in two worktrees simultaneously |
| `master` | Clone | Same as above |
| `develop` | Clone | Same as above |
| `v0/develop` | Worktree | Dedicated branch, unlikely to conflict |
| `feature/*` | Worktree | Any non-standard branch |

### Manual Override

```bash
# In .v0.rc
V0_WORKSPACE_MODE="clone"  # Force clone mode
```

## Worktree Mode

### How It Works

```diagram
Main Repository                    Workspace (Worktree)
/Users/dev/myproject/              ~/.local/state/v0/myproject/workspace/myproject/
├── .git/                          ├── .git  (file, points to main)
│   └── worktrees/                 ├── .v0.rc  (tracked in git)
│       └── myproject/             ├── src/
├── .v0/  (gitignored)             └── ...
├── .v0.rc
└── src/
```

### Git Internals

The workspace's `.git` is a **file** (not directory) containing:
```
gitdir: /Users/dev/myproject/.git/worktrees/myproject
```

This links the worktree back to the main repository's git directory.

### Advantages

- **Faster creation**: No network access needed, just creates index
- **Shared objects**: Commits, blobs, trees are shared with main repo
- **Consistent history**: Both checkouts share the same refs

### Limitations

- **Branch exclusivity**: A branch can only be checked out in one worktree at a time
- **Tied to main repo**: If main repo moves, worktree breaks

### Control Flow for Operations

```diagram
1. Feature starts
   └── Creates worktree at ~/.local/state/v0/${PROJECT}/tree/feature/${name}/
       └── Uses: git worktree add <path> <branch>

2. Feature completes
   └── Merge queue daemon picks up
       └── Daemon runs from workspace (on v0/develop)
       └── Merges feature branch into v0/develop
       └── Pushes to origin

3. Cleanup
   └── git worktree remove <path>
   └── git push origin --delete <branch>
```

## Clone Mode

### How It Works

```diagram
Main Repository                    Workspace (Clone)
/Users/dev/myproject/              ~/.local/state/v0/myproject/workspace/myproject/
├── .git/                          ├── .git/  (full clone)
├── .v0/  (gitignored)             ├── .v0/  (empty, gitignored)
├── .v0.rc                         ├── .v0.rc  (from clone)
└── src/                           └── src/
```

### Git Internals

The workspace is a full clone with its own `.git` directory. Remote `origin` is reconfigured to point to the same remote as the main repo (not the local path).

```bash
# After clone creation
git remote set-url origin <same-url-as-main-repo>
```

### Advantages

- **No branch conflicts**: Can checkout any branch regardless of main repo state
- **Full isolation**: Independent git state, can be manipulated freely
- **Portable**: Not tied to main repo location

### Limitations

- **Duplicate storage**: Objects are not shared (though local clone is fast)
- **Separate refs**: Must fetch to see main repo's new commits
- **Includes `.v0.rc`**: Clone contains the tracked `.v0.rc` file, which could cause `v0_load_config()` to set `V0_ROOT` to the workspace path. The `v0_register_project()` function detects this and skips registration to prevent corrupting `.v0.root`.

### Control Flow for Operations

```diagram
1. Feature starts
   └── Creates worktree at ~/.local/state/v0/${PROJECT}/tree/feature/${name}/
       └── Note: Feature worktrees are ALWAYS worktrees, even in clone mode
       └── The "clone" mode only affects the merge workspace

2. Feature completes
   └── Merge queue daemon picks up
       └── Daemon runs from workspace (clone on main)
       └── Fetches feature branch from origin
       └── Merges into main
       └── Pushes to origin

3. Cleanup
   └── git worktree remove <path>  (feature worktree)
   └── git push origin --delete <branch>
```

## Critical Difference: The Merge Workspace

The key distinction is **where the merge daemon runs**:

### Worktree Mode
```diagram
Main repo (.v0/build/)  ←──── State files here
     │
     └── Worktree (workspace)  ←── Daemon runs here
              │
              └── v0/develop checked out
```

### Clone Mode
```diagram
Main repo (.v0/build/)  ←──── State files here
     │
     └── Clone (workspace)  ←── Daemon runs here
              │
              └── main checked out
```

### Child Process Working Directory

Workers that run from the workspace launch child processes via `nohup`. These
child processes inherit the **workspace** as their working directory, not the
main repository.

See [SYSTEM.md - Environment Variable Inheritance](SYSTEM.md#environment-variable-inheritance)
for required exports and the pattern used by scripts.

## v0 Push/Pull Commands

The `v0 push` and `v0 pull` commands synchronize changes between user branches and the agent branch (`V0_DEVELOP_BRANCH`). These commands operate in `V0_ROOT`, not the workspace.

### Conceptual Model

```diagram
User Branch (main, feature/x)     Agent Branch (V0_DEVELOP_BRANCH)
         │                                    │
         │  ←─── v0 pull ───────────────────  │  (merge agent → user)
         │                                    │
         │  ───── v0 push ─────────────────→  │  (reset agent = user)
         │                                    │
```

### v0 push

**Purpose**: Reset the agent branch to match the user's current branch.

```bash
v0 push [branch] [-f|--force]
```

**Implementation** (`packages/pushpull/lib/push.sh`):

1. **Divergence check**: Compares HEAD with `origin/${V0_DEVELOP_BRANCH}`
   - If agent has commits not in HEAD, requires `--force`
   - Uses `git merge-base --is-ancestor` to detect divergence

2. **Force push**: `git push origin <source>:<agent_branch> --force`

3. **Marker update**: Writes commit SHA to `.v0/last-push` for tracking

4. **Local branch update**: If local agent branch exists and isn't checked out in a worktree, updates it via `git branch -f`

**Invariants by Workspace Mode**:

| Aspect | Worktree Mode | Clone Mode |
|--------|---------------|------------|
| Agent branch | `v0/develop` | `main` |
| User typically on | `main` | feature branch |
| Divergence common | Yes (agents work on v0/develop) | Less common |
| Force needed | Often (to overwrite agent work) | Rarely |

### v0 pull

**Purpose**: Merge changes from the agent branch into the user's current branch.

```bash
v0 pull [branch] [--resolve]
```

**Implementation** (`packages/pushpull/lib/pull.sh`):

1. **Fetch**: `git fetch origin ${V0_DEVELOP_BRANCH}`

2. **Merge strategy**:
   - Try fast-forward: `git merge --ff-only`
   - Fall back to merge commit: `git merge --no-edit`
   - If conflicts: abort or resolve (with `--resolve`)

3. **Conflict resolution** (with `--resolve`):
   - Starts merge with `--no-commit`
   - Creates temporary `./done` script for Claude to signal completion
   - Runs Claude in foreground with conflict resolution prompt
   - Verifies no conflicts remain after resolution

**Invariants by Workspace Mode**:

| Aspect | Worktree Mode | Clone Mode |
|--------|---------------|------------|
| Pulling into | `main` (user's branch) | `main` or feature branch |
| Source | `v0/develop` | `main` |
| Fast-forward likely | Yes (if user hasn't diverged) | Depends on workflow |
| Conflicts from | Parallel agent work | Less common |

### Workflow Patterns

**Worktree Mode (v0/develop)**:
```diagram
1. User works on main
2. Agent works on v0/develop (via feature branches merged there)
3. User runs: v0 pull        # merge v0/develop → main
4. User runs: v0 push        # reset v0/develop = main (after review)
```

**Clone Mode (main)**:
```diagram
1. User works on main or feature branches
2. Agent works on main (via feature branches merged there)
3. User runs: v0 pull        # merge origin/main → local main
4. User runs: v0 push        # less common, agents already on main
```

### Key Differences from git push/pull

| Aspect | git push/pull | v0 push/pull |
|--------|---------------|--------------|
| Target | Any branch | Always agent branch (`V0_DEVELOP_BRANCH`) |
| Direction | Bidirectional | push = user→agent, pull = agent→user |
| Push behavior | Updates remote | **Resets** remote to match local |
| Conflict resolution | Manual | `--resolve` uses Claude |
| Tracking | reflog | `.v0/last-push` marker |

## Finding the Main Repository

The function `v0_find_main_repo()` resolves the main repository from any worktree:

```bash
v0_find_main_repo() {
  local dir="${1:-${V0_ROOT:-$(pwd)}}"

  # Get the common git directory (shared between all worktrees)
  local git_common_dir
  git_common_dir=$(git -C "${dir}" rev-parse --git-common-dir)

  # The main repo is the parent of the .git directory
  local main_repo
  main_repo=$(dirname "${git_common_dir}")

  echo "${main_repo}"
}
```

For worktrees: Returns the main repo path
For clones: Returns the clone's own path (clone is independent)

## Workspace Creation

### ws_create_worktree

```bash
ws_create_worktree() {
  # Check branch isn't already checked out
  ws_check_branch_conflict || return 1

  # Create worktree on develop branch
  git -C "${V0_ROOT}" worktree add "${V0_WORKSPACE_DIR}" "${V0_DEVELOP_BRANCH}"
}
```

### ws_create_clone

```bash
ws_create_clone() {
  # Clone from local (fast)
  git clone "${V0_ROOT}" "${V0_WORKSPACE_DIR}"

  # Point origin to actual remote
  local remote_url=$(git -C "${V0_ROOT}" remote get-url "${V0_GIT_REMOTE}")
  git -C "${V0_WORKSPACE_DIR}" remote set-url origin "${remote_url}"

  # Checkout develop branch
  git -C "${V0_WORKSPACE_DIR}" checkout "${V0_DEVELOP_BRANCH}"
}
```

## Workspace Validation

On each operation, `ws_ensure_workspace` validates:

1. Workspace exists and is a valid git directory
2. Workspace type matches `V0_WORKSPACE_MODE` (worktree vs clone)
3. Workspace is on `V0_DEVELOP_BRANCH`
4. Remote URL matches (clone mode only - worktrees share remotes)

If any validation fails, the workspace is automatically recreated.

### Remote URL Sync (Clone Mode)

For clone workspaces, `ws_remote_matches()` verifies that the workspace's `origin` URL matches the main repo's `V0_GIT_REMOTE` URL. This handles cases where:

- The remote URL changes in `.v0.rc` or the main repo
- The workspace was created with a stale remote configuration

Worktrees don't need this check since they share the `.git` directory with the main repo.

## Summary: When to Use Each Mode

| Situation | Recommended Mode |
|-----------|------------------|
| Development on `main` | Clone (required) |
| Development on `v0/develop` | Worktree (default) |
| Shared development branch | Clone (safer) |
| Solo development | Worktree (faster) |
| CI/CD environments | Clone (isolated) |

## Multi-User Cooperation

When multiple users work on the same repository, v0 uses two features to prevent conflicts:

### User-Specific Branches

By default, `v0 init` generates a unique branch for each user:

```
v0/agent/{username}-{shortid}
```

Example: `v0/agent/alice-a3f2`, `v0/agent/bob-7e91`

This prevents branch conflicts when multiple developers run v0 agents on the same repository.

**Branch generation** (`packages/core/lib/config.sh`):
```bash
v0_generate_user_branch() {
  local username shortid
  username=$(whoami | tr '[:upper:]' '[:lower:]')
  shortid=$(head -c 2 /dev/urandom | xxd -p)
  echo "v0/agent/${username}-${shortid}"
}
```

### Local Agent Remote

Instead of pushing worker branches to the shared `origin` remote, v0 creates a local bare git repository called `agent`:

```
~/.local/state/v0/${PROJECT}/remotes/agent.git
```

This prevents polluting the shared remote with temporary worker branches.

**Directory structure**:
```
~/.local/state/v0/${PROJECT}/
├── workspace/           # Merge workspace
├── tree/               # Feature worktrees
└── remotes/            # Local remotes
    └── agent.git/      # Bare repo for worker branches
```

**Initialization** (`v0 init`):
1. Creates bare clone: `git clone --bare ${V0_ROOT} ${agent_dir}`
2. Adds `agent` remote to project: `git remote add agent ${agent_dir}`
3. Sets `V0_GIT_REMOTE="agent"` in `.v0.rc`

**Sync strategy**:
- Workers push feature branches to `agent` remote
- `v0 push` / `v0 pull` sync between user and agent environments
- No automatic sync with `origin` - user decides when to push upstream

### Configuration

Both features are configured via `.v0.rc`:

```bash
# User-specific branch (auto-generated)
V0_DEVELOP_BRANCH="v0/agent/alice-a3f2"

# Local agent remote (new default)
V0_GIT_REMOTE="agent"
```

To use shared `origin` instead (legacy behavior):
```bash
V0_GIT_REMOTE="origin"
```

## Shutdown and Cleanup

Cleanup behavior differs by workspace mode and option used.

### --drop-workspace

Removes workspace and worktrees but preserves state (logs, build cache).

**Worktree mode:**
```bash
# Removes:
# - All worktrees (workspace, feature trees, worker trees)
# - Worker branches (*-bugs, *-chores)
# - Agent develop branch (v0/agent/{user}-{id})

# Preserves:
# - State directory (~/.local/state/v0/${PROJECT}/)
# - Build directory (.v0/build/)
```

**Clone mode:**
```bash
# Removes:
# - Workspace clone
# - Feature worktrees
# - Worker branches (*-bugs, *-chores)

# Preserves:
# - Develop branch (main/develop/master)
# - State directory
# - Build directory
```

### --drop-everything

Full reset - removes all v0 state for the project.

**Worktree mode:**
```bash
# Removes:
# - All worktrees (workspace, feature trees, worker trees)
# - Worker branches (*-bugs, *-chores)
# - Agent develop branch (v0/agent/{user}-{id})
# - State directory (~/.local/state/v0/${PROJECT}/)
# - Build directory (.v0/build/)
# - Agent remote
```

**Clone mode:**
```bash
# Removes:
# - Workspace clone
# - Feature worktrees
# - Worker branches (*-bugs, *-chores)
# - State directory
# - Build directory
# - Agent remote

# Preserves:
# - Develop branch (main/develop/master)
```

### Why the Difference?

In worktree mode, `v0/agent/*` branches are **user-specific** and isolated. Each user has their own branch (e.g., `v0/agent/alice-a3f2`), so removing it doesn't affect other users.

In clone mode, the develop branch is a **shared branch** (like `main`). Deleting it would affect the entire team.

### Summary

| Option | Mode | Worktree | Branch | State |
|--------|------|----------|--------|-------|
| `--drop-workspace` | Worktree | Removed | Removed | Preserved |
| `--drop-workspace` | Clone | Removed | Preserved | Preserved |
| `--drop-everything` | Worktree | Removed | Removed | Removed |
| `--drop-everything` | Clone | Removed | Preserved | Removed |

## Related Documentation

- [SYSTEM.md](SYSTEM.md) - System architecture overview
- [operations/state.md](operations/state.md) - Operation state machine
- [mergeq/state.md](mergeq/state.md) - Merge queue state machine
- [commands/v0-merge.md](commands/v0-merge.md) - Merge command details
