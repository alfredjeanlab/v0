# Chore Workflow Debug Guide

## State Diagram

```
wk new chore "desc"            v0 chore --start
       │                              │
       ▼                              ▼
┌──────────────┐              ┌─────────────────┐
│Chore Created │              │ Polling Daemon  │
│  status=todo │              │ Started         │
└──────┬───────┘              └────────┬────────┘
       │                              │
       └──────────┬───────────────────┘
                  │
                  │ Polls every 5s: wk ls --type chore --status todo
                  ▼
           ┌──────────────┐
           │ Chore Found  │
           └──────┬───────┘
                  │
                  │ new-branch {id}
                  │ Worktree reset to main
                  ▼
           ┌──────────────┐
           │ in_progress  │  State: BUILD_DIR/chore/{id}/state.json
           └──────┬───────┘  tmux: {project}-worker-chore
                  │
                  │ [FAIL: Claude crashes → polling detects]
                  │ [FAIL: Chore incomplete → stop hook blocks]
                  ▼
           ┌──────────────┐
           │ fixed called │  Claude calls: fixed {id}
           └──────┬───────┘
                  │
     ┌────────────┼────────────┐
     │            │            │
     ▼            ▼            ▼
git push -u   v0-mergeq    wk done {id}
origin HEAD   --enqueue
              chore/{id}
                  │
                  │ [FAIL: Push fails]
                  │ [FAIL: wk done fails → issue open]
                  ▼
           ┌──────────────┐
           │pending_merge │
           └──────┬───────┘
                  │
                  ▼
           ┌──────────────┐
           │   merged     │  Branch deleted from remote
           └──────────────┘

CRASH RECOVERY:
┌────────────────────────────────────────────────────┐
│ Polling detects crash via .done-exit flag absence  │
│ Backoff: 5s → 10s → 20s → 40s → ... → 5min cap    │
│ Alerts on first crash, stops on second            │
└────────────────────────────────────────────────────┘
```

## Quick Diagnosis

### Check daemon status
```bash
tmux ls | grep worker-chore
pgrep -f "v0-chore"
```

### Check current chore state
```bash
cat BUILD_DIR/chore/{id}/state.json | jq .
```

### List pending chores
```bash
wk ls --type chore --status todo
```

### Check for crash markers
```bash
ls BUILD_DIR/chore/{id}/.done-exit 2>/dev/null && echo "Clean exit" || echo "Crashed/running"
```

### Check merge queue
```bash
v0 mergeq --list | grep "chore/"
```

## Failure Recovery

### Daemon not running
```bash
# Check if running
tmux ls | grep worker-chore

# Restart daemon
v0 chore --start
```

### Chore stuck in_progress (agent crashed)
```bash
# Attach to see state
tmux attach -t {project}-worker-chore

# Polling will auto-resume with backoff
# Or restart daemon to pick up immediately
v0 chore --start
```

### Branch pushed but not merged
```bash
# Check remote
git ls-remote origin chore/{id}

# Check queue
v0 mergeq --list

# Re-enqueue
v0 mergeq --enqueue chore/{id}
```

### Issue still open after merge
```bash
# Close manually
wk done {id}
```

## Source Files

- `bin/v0-chore:164-287` — new-branch, fixed scripts
- `lib/worker-common.sh:227-394` — Polling loop
