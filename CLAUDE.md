# v0

A tool to ease you in to multi-agent vibe coding.

Orchestrates Claude workers in tmux sessions for planning, feature development, bug fixing, and chore processing. Uses git worktrees for isolated development and a merge queue for automatic integration.

## Project Structure

```
bin/                    # CLI commands (v0, v0-plan, v0-feature, v0-fix, etc.)
packages/               # Modular shell library packages
  core/                 #   Foundation: config, logging, git-verify
  state/                #   State machine for operation lifecycle
  mergeq/               #   Merge queue management
  merge/                #   Merge conflict resolution
  worker/               #   Worker utilities: nudge, coffee, try-catch
  feature/              #   Feature workflow orchestration
  hooks/                #   Claude Code hooks (stop-*.sh, notify-progress.sh)
  status/               #   Status display formatting
  cli/                  #   Entry point, templates, prompts
  test-support/         #   Test helpers, fixtures, mocks
tests/                  # Integration tests (v0-cancel.bats, v0-merge.bats, etc.)
vendor/                 # Third-party tools (bats)
docs/debug/             # Troubleshooting guides
```

## Package Layers

Packages follow a layered dependency model (see `packages/CLAUDE.md`):
- **Layer 0**: core
- **Layer 1**: state, mergeq
- **Layer 2**: merge, worker
- **Layer 3**: feature, hooks, status
- **Layer 4**: cli

## Running Tests

```bash
scripts/test                    # Run all tests (incremental caching)
scripts/test core cli           # Run specific packages
scripts/test v0-cancel          # Run specific integration test
scripts/test --bust v0-merge    # Clear cache for one target
```

## Common Commands

- `make check` - Run all lints and tests
- `make lint` - ShellCheck on all scripts
- `scripts/test` - Incremental test runner with caching

## Before Committing

- [ ] Run `make check` (lint + test + quench)
- [ ] New lib code needs unit tests in `packages/<pkg>/tests/`
- [ ] New bin commands need integration tests in `tests/`
- [ ] Tag unimplemented tests: `# bats test_tags=todo:implement`
