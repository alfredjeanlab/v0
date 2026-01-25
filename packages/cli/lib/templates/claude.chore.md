# Chore Worker

You are completing ONE chore per session, then exiting to keep context windows small.

## Workflow

1. **Find a chore**: `wk ready --type chore` to see available chores
2. **If a chore is available**:
   - Claim chore: `wk start <id>`
   - Create branch: `./new-branch <id>` - creates `chore/<id>` branch from main
   - Understand: `wk show <id>` to read the chore details
   - Complete: Read code, make changes, test
   - Commit: `cd <repo-name> && git add <files> && git commit -m "Chore: ..."`
   - Complete: `./fixed <id>` - pushes, queues merge, closes chore, **exits session**
3. **If no chores available**: Run `./done` (or `../done` from worktree dir) to exit cleanly

The polling manager will detect the exit and relaunch automatically for the next chore.

## Helper Scripts

- `./new-branch <id>` - Reset worktree to latest main, ready to work
- `./fixed <id>` - Push as `chore/<id>`, queue merge, close chore, **exit session**
- `./done` (or `../done` from worktree dir) - Exit when no chores available

## Example Session

```bash
wk ready --type chore
# proj-abc1: Update dependencies

wk start proj-abc1
./new-branch proj-abc1
# Reset to latest main
# Ready to fix proj-abc1

wk show proj-abc1
# ... read and understand ...

# ... make changes ...

cd <repo-name> && git add Cargo.toml Cargo.lock && git commit -m "Chore: update dependencies"
./fixed proj-abc1
# Pushing chore/proj-abc1...
# Queueing for merge...
# Closing proj-abc1...
# Resetting to latest main...
#
# Completed proj-abc1
# Branch chore/proj-abc1 queued for merge
# Exiting session...
# (session ends here - polling manager will launch new session for next chore)
```

## Important Notes

- **One chore per session** - keeps context windows small and costs low
- Each chore gets its own branch - changes are isolated
- Merges happen automatically via merge queue
- If merge fails, it doesn't block other chores
- If you cannot complete a chore, add a note with `wk note <id> "reason"` and move on
- Always use `./fixed` to complete - it handles the merge queue and exits
- The polling manager will relaunch for each new chore
