# v0

A tool to ease you in to multi-agent vibe coding.

Orchestrates Claude workers in tmux sessions for planning, feature development, bug fixing, and chore processing. Uses git worktrees for isolated development and a merge queue for automatic integration.

## Directory Structure

```
bin/                    # CLI commands (v0, v0-plan, v0-build, v0-fix, etc.)
packages/               # Modular shell library packages
  core/                 #   Foundation: config, logging, git-verify
  workspace/            #   Workspace management for merge operations
  state/                #   State machine for operation lifecycle
  mergeq/               #   Merge queue management
  merge/                #   Merge conflict resolution
  worker/               #   Worker utilities: nudge, coffee, try-catch
  hooks/                #   Claude Code hooks (stop-*.sh, notify-progress.sh)
  status/               #   Status display formatting
  cli/                  #   Entry point, templates, prompts, build workflow
  test-support/         #   Test helpers, fixtures, mocks
tests/                  # Integration tests (v0-cancel.bats, v0-merge.bats, etc.)
vendor/                 # Third-party tools (bats)
docs/debug/             # Troubleshooting guides
```

## Package Layers

Packages follow a layered dependency model (see `packages/CLAUDE.md`):
- **Layer 0**: core
- **Layer 1**: workspace, state, mergeq
- **Layer 2**: merge, worker
- **Layer 3**: hooks, status
- **Layer 4**: cli (includes build workflow)

## Running Tests

```bash
scripts/test                    # Run all tests (incremental caching)
scripts/test core cli           # Run specific packages
scripts/test v0-cancel          # Run specific integration test
scripts/test --bust v0-merge    # Clear cache for one target
```

## Commits

Use conventional commit format: `type(scope): description`
Types: feat, fix, chore, docs, test, refactor

## Common Commands

- `make check` - Run all lints and tests
- `make lint` - ShellCheck on all scripts
- `scripts/test` - Incremental test runner with caching

## Landing the Plane

- [ ] Run `make check` (lint + test + quench)
- [ ] New lib code needs unit tests in `packages/<pkg>/tests/`
- [ ] New bin commands need integration tests in `tests/`
- [ ] Tag unimplemented tests: `# bats test_tags=todo:implement`
