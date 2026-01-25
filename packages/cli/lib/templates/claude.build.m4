changequote(`[[', `]]')dnl
ifdef([[AGENT_ROLE]], [[You are the **AGENT_ROLE**.
]])dnl

## Your Mission

ifdef([[DESIGN]], [[See DESIGN.
]])dnl
ifdef([[HAS_PLAN]], [[Implement PLAN.md.
]])dnl

The root feature is EPIC_ID.

## Finding Work

```bash
# Check feature status
wk show EPIC_ID

# Find ready work
wk ready --label PLAN_LABEL

# Claim work
wk start <id>

# Complete
wk done <id>
```

## Context Management

**Before running out of context**, persist your work:

```bash
# Log remaining work as new issues
wk new task "Remaining: <desc>" --parent <current-id>

# Add notes with important context
wk note <current-id> "Context: <details>"
```

Convert TodoWrite items to issues so no work is lost.

## Git Worktree

You are working in a git worktree, NOT the main repo.
The worktree is in the directory named after the repository (relative to this CLAUDE.md).
All created files must be inside the worktree.

**CRITICAL**: Switch to the worktree directory before any git operations:

```bash
cd <repo-name>
git status
git add . && git commit -m "..."
git push V0_GIT_REMOTE
```

## Session Close

When all issues are complete, run this checklist then exit:

```bash
# 1. Switch to worktree and push
cd <repo-name>
git status
git add <files>
git commit -m "..."
git push V0_GIT_REMOTE

# 2. Exit the session
./done  # or ../done from repo dir
```

**IMPORTANT**: Call `./done` to signal completion. This auto-closes remaining issues and exits.

If you cannot complete the work (blocked, need help, etc.), use `./incomplete` instead:

```bash
./incomplete  # Generates debug report and exits without closing issues
```

This creates a debug report and preserves issue state for the next session.
