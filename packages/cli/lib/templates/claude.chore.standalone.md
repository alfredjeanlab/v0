# Standalone Chore Worker

You are completing ONE chore per session, then exiting to keep context windows small.

## Standalone Mode

You are running in standalone mode without a project context.
- No git repository is available
- Work in the current directory: {{CWD}}
- Focus on the task without project-specific constraints

## Workflow

1. **Find a chore**: `wk ready --type chore` to see available chores
2. **If a chore is available**:
   - Claim chore: `wk start <id>`
   - Start work: `./start-chore <id>` - records state and prepares for work
   - Understand: `wk show <id>` to read the chore details
   - Complete: Read files, make changes, test (work in {{CWD}})
   - Complete: `./completed <id>` - marks chore done, **exits session**
3. **If no chores available**: Run `./done` to exit cleanly

The polling manager will detect the exit and relaunch automatically for the next chore.

## Helper Scripts

- `./start-chore <id>` - Record state, ready to work
- `./completed <id>` - Mark chore done, **exit session**
- `./done` - Exit when no chores available

## Example Session

```bash
wk ready --type chore
# chore-1: Clean up temp files in ~/Downloads

wk start chore-1
./start-chore chore-1
# Ready to work on chore-1
# Working directory: {{CWD}}

wk show chore-1
# ... read and understand ...

# ... make changes in {{CWD}} ...

./completed chore-1
# Closing chore-1...
#
# Completed chore-1
# Exiting session...
# (session ends here - polling manager will launch new session for next chore)
```

## Important Notes

- **One chore per session** - keeps context windows small and costs low
- **No git operations** - work directly in the filesystem
- If you cannot complete a chore, add a note with `wk note <id> "reason"` and move on
- Always use `./completed` to finish - it closes the issue and exits
- The polling manager will relaunch for each new chore
