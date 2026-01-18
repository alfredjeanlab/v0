# Feature Workflow Debug Guide

## State Diagram

```
v0 feature {name}
       │
       ▼
┌──────────────┐
│    init      │  State: BUILD_DIR/operations/{name}/state.json
└──────┬───────┘  Worktree: BUILD_DIR/worktrees/feature/{name}
       │
       │ [FAIL: Plan never created → stuck here]
       ▼
┌──────────────┐
│   planned    │  Plan: .v0/plans/{name}.md
└──────┬───────┘
       │
       │ [FAIL: Issue creation fails → no tracking]
       ▼
┌──────────────┐
│   queued     │  Issues labeled "plan:{name}"
└──────┬───────┘
       │
       │ (--enqueue stops here)
       │
       │ [FAIL: Agent crashes → manual resume]
       │ [FAIL: Agent never exits → stuck]
       ▼
┌──────────────┐
│  executing   │  tmux: {project}-feature-{name}
└──────┬───────┘
       │
       │ [FAIL: on-complete.sh fails → never queued]
       ▼
┌──────────────┐
│  completed   │  All issues closed, agent exited
└──────┬───────┘
       │
       │ [FAIL: Merge daemon not running]
       ▼
┌──────────────┐
│pending_merge │  Entry in mergeq/queue.json
└──────┬───────┘
       │
       │ [FAIL: Worktree deleted]
       │ [FAIL: Conflicts unresolved]
       ▼
┌──────────────┐
│   merged     │  Branch merged, worktree archived
└──────────────┘

BLOCKED (--after):
┌──────────────┐
│   blocked    │  Waiting for dependency
└──────────────┘
```

## Quick Diagnosis

### Check current state
```bash
cat BUILD_DIR/operations/{name}/state.json | jq '{phase, merged, merge_queued}'
```

### Check tmux session
```bash
tmux ls | grep "feature-{name}"
tmux attach -t {project}-feature-{name}
```

### Check plan file
```bash
ls .v0/plans/{name}.md
```

### Check associated issues
```bash
wk ls --label "plan:{name}"
```

### Check merge queue status
```bash
v0 mergeq --list | grep {name}
```

## Failure Recovery

### Stuck in `init` (plan never created)
```bash
# Resume planning
v0 feature {name} --resume
```

### Stuck in `executing` (agent crashed)
```bash
# Check if session exists
tmux ls | grep "feature-{name}"

# Resume agent
v0 feature {name} --resume
```

### Stuck in `completed` (never merged)
```bash
# Check if in queue
v0 mergeq --list

# Re-enqueue if missing
v0 mergeq --enqueue {name}

# Or manual merge
v0 merge BUILD_DIR/worktrees/feature/{name}
```

### Open issues blocking merge
```bash
# List open issues
wk ls --label "plan:{name}" --status open

# Close manually or resume feature
v0 feature {name} --resume
```

## Source Files

- `bin/v0-feature:646-1095` — Phase execution
- `lib/hooks/stop-feature.sh` — Completion validation
