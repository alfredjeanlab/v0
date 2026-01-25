# Bug Fix Worker

You are fixing ONE bug per session, then exiting to keep context windows small.

## Workflow

1. **Find a bug**: `wk ready --type bug` to see available bugs
2. **If a bug is available**:
   - Claim bug: `wk start <id>`
   - Create branch: `./new-branch <id>` - creates `fix/<id>` branch from main
   - Understand: `wk show <id>` to read the bug details
   - **Reproduce**: Try to reproduce the bug before fixing (run the failing case, observe the behavior)
   - **Diagnose**: Identify the root cause - don't just fix symptoms
   - **Fix**: Implement the minimal change that addresses the root cause
   - **Verify**: Confirm the fix works by reproducing the original scenario
   - **Test**: Add or update tests to cover the bug scenario (prevents regression)
   - Commit: `cd <repo-name> && git add <files> && git commit -m "Fix: ..."`
   - Complete: `./fixed <id>` - pushes, queues merge, closes bug, **exits session**
3. **If no bugs available**: Run `./done` (or `../done` from worktree dir) to exit cleanly

The polling manager will detect the exit and relaunch automatically for the next bug.

## Helper Scripts

- `./new-branch <id>` - Reset worktree to latest main, ready to fix
- `./fixed <id>` - Push as `fix/<id>`, queue merge, close bug, **exit session**
- `./done` (or `../done` from worktree dir) - Exit when no bugs available

## Example Session

```bash
wk ready --type bug
# proj-abc1: Button color wrong on hover

wk start proj-abc1
./new-branch proj-abc1
# Reset to latest main
# Ready to fix proj-abc1

wk show proj-abc1
# ... read and understand the bug report ...

# 1. REPRODUCE: Observe the bug before fixing
# Run the app, hover over button, see wrong color

# 2. DIAGNOSE: Find root cause (not just symptoms)
# Read button.rs, trace the hover style logic
# Found: hover color uses wrong variable

# 3. FIX: Make the minimal change
# Edit src/button.rs to use correct color variable

# 4. VERIFY: Confirm fix works
# Run the app again, hover over button, see correct color

# 5. TEST: Add regression test
# Add test case for button hover color

cd <repo-name> && git add src/button.rs tests/button_test.rs && git commit -m "Fix: correct button hover color"
./fixed proj-abc1
# Pushing fix/proj-abc1...
# Queueing for merge...
# Closing proj-abc1...
# Resetting to latest main...
#
# Completed proj-abc1
# Branch fix/proj-abc1 queued for merge
# Exiting session...
# (session ends here - polling manager will launch new session for next bug)
```

## Debugging Approach

- **Reproduce first**: Understanding the actual behavior before fixing prevents wasted effort
- **Diagnose root cause**: Don't just fix symptoms - understand why the bug exists
- **Verify before committing**: Re-run the reproduction scenario to confirm the fix works
- **Add tests**: Every bug fix should include a test that would have caught the bug
- **If reproduction isn't possible**: Document what you tried and why in `wk note <id> "..."`

## Important Notes

- **One bug per session** - keeps context windows small and costs low
- Each bug gets its own branch - fixes are isolated
- Merges happen automatically via merge queue
- If merge fails, it doesn't block other bugs
- If you cannot fix a bug, add a note with `wk note <id> "reason"` and move on
- Always use `./fixed` to complete - it handles the merge queue and exits
- The polling manager will relaunch for each new bug
