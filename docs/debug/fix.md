# Fix Workflow Debug Guide

## State Diagram

```
wk new bug "desc"              v0 fix --start
       │                              │
       ▼                              ▼
┌──────────────┐              ┌─────────────────┐
│  Bug Created │              │ Polling Daemon  │
│  status=todo │              │ Started         │
└──────┬───────┘              └────────┬────────┘
       │                               │
       └──────────┬────────────────────┘
                  │
                  │ Polls every 5s: wk ls --type bug --status todo
                  ▼
           ┌──────────────┐
           │  Bug Found   │
           └──────┬───────┘
                  │
                  │ new-branch {id}
                  │ Worktree reset to main
                  ▼
           ┌──────────────┐
           │ in_progress  │  State: BUILD_DIR/fix/{id}/state.json
           └──────┬───────┘  tmux: {project}-worker-fix
                  │
                  │ [FAIL: Claude crashes → polling detects]
                  │ [FAIL: Fix incomplete → stop hook blocks]
                  ▼
           ┌──────────────┐
           │ fixed called │  Claude calls: fixed {id}
           └──────┬───────┘
                  │
     ┌────────────┼────────────┬─────────────────┐
     │            │            │                 │
     │            │            │                 │ Note but no commits?
     ▼            ▼            ▼                 ▼
git push -u   v0-mergeq    wk done {id}   ┌──────────────┐
origin HEAD   --enqueue                   │ Human Handoff│
              fix/{id}                    │ worker:human │
                  │                       └──────┬───────┘
                  │                              │
                  │ [FAIL: Push fails]           │ Human reviews note
                  │ [FAIL: wk done fails]        │ and either:
                  ▼                              │ - Fixes manually
           ┌──────────────┐                      │ - Closes with reason
           │pending_merge │                      │ - Reassigns to worker
           └──────┬───────┘                      ▼
                  │                       ┌──────────────┐
                  ▼                       │ done/closed  │
           ┌──────────────┐               └──────────────┘
           │   merged     │  Branch deleted from remote
           └──────────────┘

CRASH RECOVERY:
┌────────────────────────────────────────────────────┐
│ Polling detects crash via .done-exit flag absence  │
│ Backoff: 5s → 10s → 20s → 40s → ... → 5min cap    │
│ Alerts on first crash, stops on second            │
└────────────────────────────────────────────────────┘

NOTE-WITHOUT-FIX HANDOFF:
┌────────────────────────────────────────────────────┐
│ When agent adds note (wk note) but makes no commits│
│ → Bug reassigned to worker:human                   │
│ → Stop hook blocks with helpful message            │
│ → Human reviews: wk show {id} to see note          │
│ → Human resolves: fix, close, or reassign          │
└────────────────────────────────────────────────────┘
```

## Quick Diagnosis

### Check daemon status
```bash
tmux ls | grep worker-fix
pgrep -f "v0-fix"
```

### Check current bug state
```bash
cat BUILD_DIR/fix/{id}/state.json | jq .
```

### List pending bugs
```bash
wk ls --type bug --status todo
```

### Check for crash markers
```bash
ls BUILD_DIR/fix/{id}/.done-exit 2>/dev/null && echo "Clean exit" || echo "Crashed/running"
```

### Check merge queue
```bash
v0 mergeq --list | grep "fix/"
```

## Failure Recovery

### Daemon not running
```bash
# Check if running
tmux ls | grep worker-fix

# Restart daemon
v0 fix --start
```

### Bug stuck in_progress (agent crashed)
```bash
# Attach to see state
tmux attach -t {project}-worker-fix

# Polling will auto-resume with backoff
# Or restart daemon to pick up immediately
v0 fix --start
```

### Branch pushed but not merged
```bash
# Check remote
git ls-remote origin fix/{id}

# Check queue
v0 mergeq --list

# Re-enqueue
v0 mergeq --enqueue fix/{id}
```

### Issue still open after merge
```bash
# Close manually
wk done {id}
```

### Bug assigned to worker:human (note without fix)
```bash
# View the bug and its notes
wk show {id}

# Options:
# 1. Fix it manually and close
wk done {id}

# 2. Close with explanation if bug is invalid/won't fix
wk close {id} --reason="Cannot reproduce - need more info"

# 3. Reassign back to worker if issue was transient
wk edit {id} assignee worker:fix
wk reopen {id}
```

## Source Files

- `bin/v0-fix:164-339` — new-branch, fixed scripts
- `lib/worker-common.sh:227-394` — Polling loop
