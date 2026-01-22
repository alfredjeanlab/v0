# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- **`make install` target**: Install v0 locally for development.

### Changed

- **CI**: Bump actions/checkout from 4 to 6.

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
