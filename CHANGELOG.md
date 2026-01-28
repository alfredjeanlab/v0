# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2026-01-27

Collaboration-friendly release: agents now work in isolation with user-specific branches and local remotes, with `v0 push` and `v0 pull` commands to sync changes on your terms. Internals restructured for maintainability.

### Added

- **`v0 push` and `v0 pull` commands**: Sync changes between user and agent branches on your terms.

- **`v0 mayor` command**: Interactive orchestration assistant for high-level project guidance.

- **`v0 watch --all` flag**: System-wide project monitoring across all v0-enabled repositories.

- **`v0 log` command**: Combined history view for all operations with filtering options.

- **`v0 archive` command**: Move completed plans to icebox for long-term storage.

- **`v0 start` and `v0 stop` commands**: Control workers directly; `--drop-workspace` and `--drop-everything` flags clean up on shutdown.

- **Worker flags**: `--restart` to restart workers, `--after` to specify dependencies between fix/chore operations, `--force` to bypass blockers on resume.

- **`--short` flag for `v0 status` and `v0 watch`**: Compact display; `v0 watch --all` uses short mode by default.

- **`.v0.profile.rc` configuration file**: Project-specific settings separated from `.v0.rc`.

- **Background pruning daemon**: Automatic cleanup of stale worktrees and branches.

- **Dedicated merge workspace**: Isolated workspace for merge conflict resolution.

- **Developer tooling**: Release script (`scripts/release`), ANSI color support in help output.

### Changed

- **`v0 build` simplified**: Renamed from `v0 feature`, removed decompose phase (now plan -> implement -> verify), removed `--eager`, `--foreground`, `--safe`, `--enqueue` flags.

- **New defaults for isolation**: Develop branch defaults to user-specific `v0/agent/{username}-{shortid}`, git remote defaults to local `agent` remote (`~/.local/state/v0/${PROJECT}/remotes/agent.git`) instead of `origin`, worker branches derive from develop branch.

- **Status display**: Renamed "Operations" to "Plans", "Bugfix" to "Bugs", "Check" to "Status"; `--after` accepts operation names in addition to wok IDs.

- **`v0 init` output more concise**: Agent remote setup messages streamlined.

### Documentation

- Synced architecture and merge docs with implementation; fixed broken links in SYSTEM.md.

### Refactored

- **Monorepo package structure**: Modular shell libraries with incremental test caching.

- **Merge module**: Unified error handling, extracted `mg_finalize_merge` for post-merge steps.

- **State machine**: Migrated blocking to wok, removed blocked phase.

### Performance

- **Optimized `v0 status` display**: Batched wok queries, eliminated subprocess spawns in cache lookups, and pre-computed date strings in jq.

- **Ripgrep wrapper**: Faster grep operations via `v0_grep` function.

### Fixed

- Workspace no longer overwrites `.v0.root` in `v0 watch`.
- Merge queue reliability: fetch remote refs before readiness check, recover stuck PROCESSING entries on startup, verify already-merged operations, push HEAD explicitly to develop branch.
- Worktree handling: resolve branch from remote before reporting `worktree:missing`, push before cleanup to preserve worktree on failure.
- Status display: exit early when wk commands fail, respect `V0_FORCE_COLOR` in branch-status.
- Wok epic marked as done when operation merges.
- `.claude` directory created before writing settings and hooks.
- Stale tmux session cleanup when resuming features.
- Inherited `BUILD_DIR` preserved when merge daemon runs in workspace.
- Batch log pruning to avoid per-line subprocess spawning.

## [0.2.2] - 2026-01-24

### Added

- **`v0 roadmap` command**: Autonomous goal orchestration for multi-step workflows.

- **`v0 prime` command**: Quick-start guide for new users.

- **Terminal title in `v0 watch`**: Sets terminal window title for easier identification.

- **Auto-commit for archived plans**: Plan files are automatically committed when archived.

- **`make install` target**: Install v0 locally for development.

### Changed

- **CI**: Bump actions/checkout from 4 to 6.

- **`v0 status` shows all operations**: Full operation list in status view; `v0 watch` retains 15-entry limit with intelligent pruning.

- **Refactored merge and status modules**: Split state-machine.sh, v0-merge, and v0-mergeq into focused, modular libraries.

### Performance

- **Optimized test suite**: Faster test execution with reduced overhead.

- **Optimized `v0 status` list view**: Improved performance for status display.

### Fixed

- Feature worktrees now link to shared `.wok` workspace.
- Nudge daemon finding plan/decompose sessions.
- ANSI escape sequences cleaned from plan.log after session ends.
- Terminal width defaults to 80 when COLUMNS is invalid.
- Active merge-resolve sessions detected correctly in `v0 status`.
- Mergeq daemon always uses `--resolve` mode.
- Plan file auto-committed in decompose phase.
- `./done` script auto-closes plan issues before exiting.
- `V0_PLAN_LABEL` exported so `./done` can close issues.
- `v0-merge` path handling when worktree path is passed.

## [0.2.1] - 2026-01-21

### Added

- **`v0 self update` command**: Switch between stable, nightly, or specific versions.

- **Last-updated timestamps**: `v0 status` displays when workers were last active.

- **Auto-hold on plan/decompose completion**: Workers pause automatically after completing planning phases for review.

- **Issue cleanup on stop**: `v0 chore --stop` and `v0 fix --stop` commands now clean up associated issues.

- **Resilient merge verification**: Merge queue includes retry logic with timing metrics for more reliable integrations.

- **`V0_GIT_REMOTE` configuration**: Customize which git remote to use (defaults to `origin`).

- **`--develop` and `--remote` flags for `v0 init`**: Configure target branch and git remote during initialization.

- **Closed-with-note handling**: Fix worker handles issues closed with notes appropriately.

### Changed

- **Renamed `V0_MAIN_BRANCH` to `V0_DEVELOP_BRANCH`**: Configurable target branch for integrations.

- **Watch header improvements**: Added project name display, responsive width, and refined color styling.

- **Status display formatting**: Merged status renders as `[merged]` instead of `(merged)`; Fix/Chore Worker status combined onto single line.

- **Watch refresh interval**: Updated to 5 seconds.

- **Removed deprecated functions**: `v0_verify_push_with_retry` and `v0_verify_merge` removed.

### Performance

- **Consolidated jq calls in v0-status**: Faster status retrieval with fewer subprocess invocations.

### Fixed

- Nudge daemon unable to find plan sessions.
- Missing `working_dir` in state for plan and decompose phases.
- Plan phase prompt missing exit instructions.
- Plan file changes not auto-committed after decompose.
- `V0_ROOT` not exported when calling v0-mergeq from on-complete.sh.
- Status incorrectly detecting active fix worker.
- Push verification now trusts git push exit code.
- macOS compatibility for v0-watch header bar width calculation.
- Re-queuing operations with resumed/completed status now allowed.
- v0-watch terminal width detection in headless environments.

## [0.2.0] - 2026-01-20

Initial tracked release.
