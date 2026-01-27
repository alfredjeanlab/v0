# v0

![CI](https://github.com/alfredjeanlab/v0/workflows/CI/badge.svg)

A tool to ease you in to multi-agent vibe coding.

Start vibe coding with a team of agents, without a learning curve.  
Ask for features, fixes, and chores and watch them be implemented and merged automatically.

## Installation

### Homebrew (macOS)

```bash
brew install alfredjeanlab/tap/v0
```

### Linux / Manual

macOS:
```bash
brew install flock tmux jq ripgrep
```

Ubuntu:
```bash
sudo apt install flock tmux jq ripgrep
```

Then install wok and v0:
```bash
curl -fsSL https://github.com/alfredjeanlab/wok/releases/latest/download/install.sh | bash
curl -fsSL https://github.com/alfredjeanlab/v0/releases/latest/download/install.sh | bash
```

Then initialize a project:

```bash
cd /path/to/your/project
v0 init
```

This creates:
- A unique branch for your agents: `v0/agent/{you}-{id}`
- A local git remote so worker branches stay off origin

To use a shared branch or push to origin instead:

```bash
v0 init --develop v0/develop         # Shared branch (team coordination)
v0 init --remote origin              # Push worker branches to origin
```

### Requirements

- [wok](https://github.com/alfredjeanlab/wok) - Issue tracking
- [claude](https://claude.ai/claude-code) - Claude Code CLI
- git, tmux, jq, flock
- ripgrep (optional, recommended for performance)

> ⚠️ _**Run at your own risk**_ ⚠️
>
> v0 runs Claude with `--dangerously-skip-permissions`.
>
> If an agent encounters untrusted input, it could execute arbitrary commands, steal passwords, or exfiltrate files.
> See [Anthropic's documentation](https://docs.anthropic.com/en/docs/claude-code) for details.

## Usage

The main workflow is fire-and-forget. Start work and let it run:

```bash
v0 build auth "Add JWT authentication"      # Plans, implements, merges
v0 chore "Update dependencies"              # Files issue, starts worker immediately
v0 fix "Login button broken on mobile"      # Files bug, starts worker immediately
```

A typical session looks like launching parallel work:

```bash
v0 build api "REST API for users"
v0 chore "Refactor auth module"
v0 chore "Add missing tests"
v0 fix "500 error on empty request"
v0 fix "Timeout on large uploads"

# Check on progress
v0 status
v0 watch

# When ready, pull completed agent work into your branch
v0 pull                  # Pull agent changes into current branch
v0 pull --resolve        # Auto-resolve conflicts with Claude
```

Agents work on their own branch (yours is `v0/agent/{you}-{id}`), keeping your branches clean. Sync on your terms:

```bash
v0 pull                  # Pull agent changes into your branch
v0 push                  # Reset agent branch to match yours
```

Use `chore` or `fix` for quick tasks.

They file an issue and a worker starts immediately.

As work completes, it's automatically committed, pushed, and merged into main via a shared merge queue.  
You'll get macOS notifications as tasks complete and branches merge.


### Builds and Plans

Builds go through a planning lifecycle:

1. **Plan** - Creates `plans/<name>.md` with implementation steps
2. **Execute** - Implements the plan in an isolated worktree
3. **Merge** - Completed work merges to main

You can create plans separately for review:

```bash
v0 plan api "Build REST API"           # Creates plans/api.md
# ... review and edit the plan ...
v0 build plans/api.md                  # Execute the plan
```

Or let `v0 build` handle everything:

```bash
v0 build api "Build REST API"          # Plans, executes, merges
```

Completed plans are archived to `plans/archive/`.

### Roadmaps

For big-picture work, use roadmaps:

```bash
v0 roadmap rust "Rewrite this in Rust"
v0 roadmap api "Build a comprehensive REST API"
v0 roadmap tests "Add comprehensive test coverage"
```

Roadmaps decompose large goals into sequenced features. The agent explores your codebase, creates an implementation outline, then queues features with proper dependencies. Each feature goes through the normal build pipeline.

### Mayor (Interactive Orchestration)

For conversational orchestration, use the mayor:

```bash
v0 mayor                 # Start interactive session
```

The mayor is Claude with full v0 context, pre-loaded with your current status.

**Use it when you want to:**
- Describe what you want in plain language and let it dispatch appropriate workers
- Get help breaking down a vague idea into concrete tasks
- Ask "what should I work on next?" when you have a backlog
- Manage dependencies between features

**How to interact:** Just describe what you want. The mayor dispatches work to background workers and tracks progress - it doesn't implement directly. Ask follow-up questions, request status checks, or describe new work as the conversation progresses.

### Other Commands

```bash
v0 talk          # Interactive Haiku for quick questions
v0 status        # Show all operations
v0 watch         # Continuously refresh status
v0 watch --all   # Watch all running projects (works from anywhere)
v0 attach fix    # Attach to a worker (fix, chore, mergeq or <feature>)
v0 coffee        # Keep computer awake
v0 prune         # Clean up completed state
v0 stop          # Stop all workers and daemons
```

While attached to tmux: scroll with `Ctrl-b [`, exit scroll with `q`, detach with `Ctrl-b d`.

## Configuration

Running `v0 init` creates:
- `.v0.rc` - Project configuration (commit this)
- `.v0.profile.rc` - User-specific settings like your unique branch (gitignored)

If you provide `--develop`, only `.v0.rc` is created with the branch inline.

You can override settings by editing the files or by passing flags to `v0 init`:

| Setting | Init Flag | Default |
|---------|-----------|---------|
| V0_DEVELOP_BRANCH | `--develop <branch>` | `v0/agent/{username}-{id}` |
| V0_GIT_REMOTE | `--remote <name>` | `agent` (local bare repo) |

Core configuration settings:

```bash
V0_BUILD_DIR=".v0/build"                 # Build state location
V0_PLANS_DIR="plans"                     # Where plans are written
V0_DEVELOP_BRANCH="v0/agent/alice-1234"  # Target branch for merges
V0_GIT_REMOTE="agent"                    # Git remote (local bare repo by default)
```

The local `agent` remote keeps worker branches off your shared origin. To use origin instead:
```bash
V0_GIT_REMOTE="origin"
```

### Worktree Initialization Hook

The `V0_WORKTREE_INIT` setting lets you run a custom command after each worktree
is created. This is useful for copying cached dependencies or setting up
worktree-specific resources.

The command runs in the new worktree directory with these environment variables:
- `V0_CHECKOUT_DIR` - Path to the main project checkout
- `V0_WORKTREE_DIR` - Path to the new worktree

Example in `.v0.rc`:
```bash
# Copy bats test framework to avoid reinstalling per-worktree
V0_WORKTREE_INIT='cp -r "${V0_CHECKOUT_DIR}/lib/bats" "${V0_WORKTREE_DIR}/lib/"'
```

## Development

```bash
git clone https://github.com/alfredjeanlab/v0.git
cd v0
make install   # Build and install

make test      # Run tests (parallel if GNU parallel installed)
make lint      # Lint scripts (requires shellcheck)
```

## License

MIT - Copyright (c) 2026 Alfred Jean LLC
