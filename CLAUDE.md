# v0

A tool to ease you in to multi-agent vibe coding.

Orchestrates Claude workers in tmux sessions for planning, feature development, bug fixing, and chore processing. Uses git worktrees for isolated development and a merge queue for automatic integration.

## Directory Structure

```
bin/            # CLI commands (v0, v0-plan, v0-feature, v0-fix, v0-chore, etc.)
lib/            # Shared shell functions and resources
  *.sh          #   Shell functions (v0-common.sh, worker-common.sh)
  hooks/        #   Claude Code hooks (notify-progress.sh, stop-*.sh)
  templates/    #   Worker CLAUDE.md templates (claude.feature.m4, claude.fix.md)
  prompts/      #   Prompt templates for planning and merging
docs/debug/     # Troubleshooting guides (workflows, hooks, lost work recovery)
tests/          # Bats unit tests
```

## Common Commands

- `make check` - Run all lints and all tests
- `make lint` - Run all lints
- `make test` - Run all tests
- `make test-file FILE=tests/unit/v0-common.bats` - Run a specific test file

## Landing the Plane

Before committing changes:

- [ ] Run `make check` which will
  - `make lint` (ShellCheck on scripts and tests)
  - `make test` (bats unit tests)
  - `quench check` (shellcheck policy, cloc, etc.)
- [ ] New features need corresponding tests in `tests/unit/`
- [ ] If a test is not yet implemented, tag it: `# bats test_tags=todo:implement`
