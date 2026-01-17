# v0

![CI](https://github.com/alfredjeanlab/v0/workflows/CI/badge.svg)

A first step into multi-agent coding.

Start vibe coding with a team of agents, without a learning curve.  
Ask for features, fixes, and chores and watch them be implemented and merged automatically.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/alfredjeanlab/v0/main/install-remote.sh | bash
```

Then initialize a project:

```bash
cd /path/to/your/project
v0 init
```

### Requirements

- [wk](https://github.com/alfredjeanlab/wok) - Issue tracking
- [claude](https://claude.ai/claude-code) - Claude Code CLI
- git, tmux, jq

> ⚠️ _**Run at your own risk**_ ⚠️
>
> v0 runs Claude with `--dangerously-skip-permissions`.
>
> If an agent encounters untrusted input, it could execute arbitrary commands, steal passwords, or exfiltrate files.
> See [Anthropic's documentation](https://docs.anthropic.com/en/docs/claude-code) for details.

## Usage

The main workflow is fire-and-forget. Start work and let it run:

```bash
v0 feature auth "Add JWT authentication"   # Plans, decomposes, implements, merges
v0 chore "Update dependencies"              # Files issue, starts worker immediately
v0 fix "Login button broken on mobile"      # Files bug, starts worker immediately
```

A typical session looks like launching parallel work:

```bash
v0 feature api "REST API for users"
v0 chore "Refactor auth module"
v0 chore "Add missing tests"
v0 fix "500 error on empty request"
v0 fix "Timeout on large uploads"

# Check on progress
v0 status
v0 watch
```

Use `chore` or `fix` for quick tasks.

They file an issue and a worker starts immediately.

As work completes, it's automatically committed, pushed, and merged into main via a shared merge queue.  
You'll get macOS notifications as tasks complete and branches merge.


### Features and Plans

Features go through a planning lifecycle:

1. **Plan** - Creates `plans/<name>.md` with implementation steps
2. **Decompose** - Converts the plan into trackable issues
3. **Execute** - Works through issues in isolated worktrees
4. **Merge** - Completed work merges to main

You can create plans separately for review:

```bash
v0 plan api "Build REST API"           # Creates plans/api.md
# ... review and edit the plan ...
v0 feature plans/api.md                # Execute the plan
```

Or let `v0 feature` handle everything:

```bash
v0 feature api "Build REST API"        # Plans, decomposes, executes, merges
```

Completed plans are archived to `plans/archive/`.

### Other Commands

```bash
v0 talk                     # Interactive Haiku for quick questions
v0 status                   # Show all operations
v0 watch                    # Continuously refresh status
v0 attach fix               # Attach to a worker (fix, chore, mergeq)
v0 coffee                   # Keep computer awake
v0 prune                    # Clean up completed state
v0 shutdown                 # Stop all workers and daemons
```

While attached to tmux: scroll with `Ctrl-b [`, exit scroll with `q`, detach with `Ctrl-b d`.

## Configuration

Running `v0 init` creates a `.v0.rc` file with optional settings:

```bash
PROJECT="myproject"         # Project name (default: directory name)
ISSUE_PREFIX="proj"         # Issue ID prefix (default: project name)
V0_BUILD_DIR=".v0/build"    # Build state location
V0_PLANS_DIR="plans"        # Where plans are written
V0_FEATURE_BRANCH="feature/{name}"
V0_BUGFIX_BRANCH="fix/{id}"
V0_CHORE_BRANCH="chore/{id}"
```

## Development

```bash
make test      # Run tests (parallel if GNU parallel installed)
make lint      # Lint scripts (requires shellcheck)
make install   # Build and install
```

## License

MIT - Copyright (c) 2026 Alfred Jean LLC
