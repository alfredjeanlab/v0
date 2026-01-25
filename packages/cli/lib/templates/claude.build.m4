changequote(`[[', `]]')dnl
ifdef([[AGENT_ROLE]], [[You are the **AGENT_ROLE**.
]])dnl

## Your Mission

ifdef([[DESIGN]], [[See DESIGN.
]])dnl
ifdef([[HAS_PLAN]], [[Implement PLAN.md.
]])dnl

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

When work is complete, run this checklist then exit:

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

**IMPORTANT**: Call `./done` to signal completion. This exits the session.

If you cannot complete the work (blocked, need help, etc.), use `./incomplete` instead:

```bash
./incomplete  # Generates debug report and exits
```
