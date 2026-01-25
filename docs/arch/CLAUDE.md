# Architecture Documentation

## State Machines
- [operations/state.md](operations/state.md) - Features, fixes, chores lifecycle
- [mergeq/state.md](mergeq/state.md) - Merge queue processing
- [roadmap/state.md](roadmap/state.md) - Roadmap orchestration

## Commands
- [v0](commands/v0.md) - Main entry point
- [v0-attach](commands/v0-attach.md) - Attach to tmux sessions
- [v0-cancel](commands/v0-cancel.md) - Cancel operations
- [v0-chore](commands/v0-chore.md) - Chore worker
- [v0-coffee](commands/v0-coffee.md) - System wake lock
- [v0-feature](commands/v0-feature.md) - Feature pipeline
- [v0-fix](commands/v0-fix.md) - Bug fix worker
- [v0-hold](commands/v0-hold.md) - Pause operations
- [v0-merge](commands/v0-merge.md) - Merge branches
- [v0-mergeq](commands/v0-mergeq.md) - Merge queue daemon
- [v0-monitor](commands/v0-monitor.md) - Auto-shutdown monitor
- [v0-nudge](commands/v0-nudge.md) - Idle session monitor
- [v0-plan](commands/v0-plan.md) - Create plans
- [v0-prime](commands/v0-prime.md) - Quick-start guide
- [v0-prune](commands/v0-prune.md) - Clean up state
- [v0-roadmap](commands/v0-roadmap.md) - Roadmap orchestration
- [v0-self](commands/v0-self.md) - Self-management dispatcher
- [v0-self-debug](commands/v0-self-debug.md) - Debug reports
- [v0-self-update](commands/v0-self-update.md) - Update v0
- [v0-self-version](commands/v0-self-version.md) - Version info
- [v0-shutdown](commands/v0-shutdown.md) - Stop workers
- [v0-startup](commands/v0-startup.md) - Start workers
- [v0-status](commands/v0-status.md) - Show status
- [v0-talk](commands/v0-talk.md) - Quick Claude conversations
- [v0-tree](commands/v0-tree.md) - Worktree management
- [v0-watch](commands/v0-watch.md) - Continuous status display

When updating command docs, read the actual `bin/` script to verify accuracy.
