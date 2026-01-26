# Merge Queue State Machine

This document describes the state machine used by the v0 merge queue.

## Overview

The merge queue serializes merges from multiple concurrent operations into the main branch. Each queue entry has a lifecycle managed by a state machine stored in `${BUILD_DIR}/mergeq/queue.json`.

## State Diagram

```mermaid
flowchart TD
    start((enqueue)) --> pending

    pending["pending<br/>(waiting to process)"]
    pending -->|"ready"| processing
    pending -->|"stale"| completed
    pending -->|"open issues"| resumed

    processing["processing<br/>(merge in progress)"]
    processing -->|"success"| completed
    processing -->|"error"| failed
    processing -->|"conflict"| conflict

    completed["completed<br/>(merged)"]
    failed["failed<br/>(unrecoverable)"]

    conflict["conflict<br/>(resolution failed)"]
    conflict -->|"auto-retry"| pending

    resumed["resumed<br/>(kicked back to worker)"]
```

## State Definitions

### Core States

| State | Description |
|-------|-------------|
| `pending` | Waiting to be processed. Entry is in queue but not yet picked up by daemon. |
| `processing` | Currently being merged. Daemon has claimed this entry. |
| `completed` | Successfully merged to main branch, or cleaned as stale. Terminal state. |

### Error States

| State | Description |
|-------|-------------|
| `failed` | Merge failed due to fetch, push, or checkout error. Requires investigation. |
| `conflict` | Merge conflict detected and automatic resolution failed. Will auto-retry once. |
| `resumed` | Entry removed from queue; operation resumed to complete outstanding work. |

## State Transitions

### Enqueue → Pending

Operations are added to the queue via:
- `v0 mergeq --add <operation>` - Manual addition
- Automatic queuing when operation sets `merge_queued=true`

Queue entries include:
- `operation` - Name or branch being merged
- `priority` - Lower numbers processed first (default: 0)
- `merge_type` - Either `operation` (has state.json) or `branch` (bare branch)
- `issue_id` - Optional associated issue to close on success

### Pending → Processing

The daemon polls every 30 seconds and picks the highest-priority ready entry:
1. Checks `mq_is_stale()` - cleans entries for already-merged operations
2. Checks `mq_is_merge_ready()` - verifies operation is complete
3. Marks entry as `processing` via `mq_update_entry_status`
4. Calls `mq_process_merge()`

### Processing → Completed

On successful merge (see [v0-merge](../commands/v0-merge.md) for detailed flow):
1. Merge via fast-forward, rebase+FF, or merge commit
2. Push to remote and verify
3. Update operation state: `phase=merged`, `merged_at=<timestamp>`
4. Mark queue entry `completed`
5. Trigger dependent operations
6. Delete remote and local branches

### Processing → Failed

Merge fails for infrastructure reasons:
- Checkout failed (branch locked)
- Fetch failed (network/permission)
- Push failed (rejected, permission)

Failed entries require manual investigation.

### Processing → Conflict

Merge has conflicts (see [v0-merge conflict resolution](../commands/v0-merge.md#conflict-resolution-flow)):
1. Daemon calls `v0 merge --resolve`
2. Claude launched in tmux to resolve conflicts via rebase
3. If resolution succeeds → `completed`
4. If resolution fails or times out → `conflict`

### Conflict → Pending (Auto-Retry)

On next poll cycle in `mq_process_watch`:
1. Daemon calls `mq_get_all_conflicts()` and checks each entry's `conflict_retried` flag in state.json
2. If not retried: sets `conflict_retried=true` via `sm_update_state`, clears `merge_status`, resets to `pending`
3. If already retried: skips (needs manual intervention via `v0 merge <op> --resolve`)

### Pending → Resumed

When operation has open issues after queuing (detected via `sm_merge_ready_reason` returning `open_issues:<count>:<in_progress>`):
1. Daemon checks if `merge_resumed` flag is already set in state.json
2. If not yet resumed: sets `merge_resumed=true`, clears `merge_queued`, marks entry as `resumed`
3. Restarts worker with `nohup v0-feature <op> --resume queued`
4. Worker completes remaining issues and re-enqueues when done

### Pending → Completed (Stale Cleanup)

Stale entries are auto-cleaned by `mq_is_stale()` when:
- Operation's `merged_at` is set (already merged, verified via `v0_verify_merge_by_op`)
- State's `created_at` is newer than queue entry's `enqueued_at` (operation was restarted)
- For branch patterns: branch no longer exists on remote (verified via `git ls-remote`)
- No state file exists and operation is not a branch pattern

## Queue File Schema

```json
{
  "version": 1,
  "entries": [
    {
      "operation": "auth",
      "worktree": "/path/to/worktree",
      "priority": 0,
      "enqueued_at": "2026-01-19T00:00:00Z",
      "status": "pending",
      "merge_type": "operation",
      "issue_id": "proj-abc123",
      "updated_at": "2026-01-19T00:05:00Z"
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `operation` | Operation name or branch name (e.g., `auth` or `fix/bug-123`) |
| `worktree` | Path to worktree (operations only) |
| `priority` | Processing order (lower = higher priority) |
| `enqueued_at` | ISO 8601 timestamp when added |
| `status` | Current state |
| `merge_type` | `operation` (has state.json) or `branch` (bare branch merge) |
| `issue_id` | Optional issue to mark done on success |
| `updated_at` | ISO 8601 timestamp of last status change |

## Merge Types

### Operation Merges

Operations created by `v0 feature`, `v0 fix`, etc.:
- Have a `state.json` file tracking operation state
- Require `merge_queued=true` and `phase=completed` (or later)
- All associated issues must be done
- Worktree must exist

### Branch Merges

Bare branches pushed directly (e.g., `fix/proj-abc1`, `chore/proj-xyz9`):
- No state file required
- Branch must exist on remote
- Used by fix and chore workers via `./fixed`

## Daemon Behavior

The daemon (`v0 mergeq --watch`) runs `mq_process_watch` continuously:

```
┌─────────────────────────────────────────────────┐
│                 Poll Cycle (30s)                │
├─────────────────────────────────────────────────┤
│ 1. mq_get_all_conflicts() - check for auto-retry│
│ 2. mq_get_all_pending() - get entries by        │
│    priority, then enqueue time                  │
│ 3. For each pending entry:                      │
│    - mq_is_stale() - clean if stale             │
│    - mq_is_merge_ready() - skip if not ready    │
│    - Auto-resume if open_issues detected        │
│    - mq_process_merge() for first ready entry   │
│ 4. Sleep and repeat                             │
└─────────────────────────────────────────────────┘
```

## Concurrency and Locking

The queue uses file-based locking (`${BUILD_DIR}/mergeq/.queue.lock`):
- Lock acquired before any queue modification
- Lock released immediately after update
- Stale lock detection (dead PID)
- Retry with exponential backoff on contention

Only one merge processes at a time to prevent race conditions on the main branch.

## Interaction with Operations

When an operation completes successfully:
1. Operation state updated first (`phase=merged`, `merged_at`)
2. Queue entry marked `completed` last
3. Dependent operations unblocked and resumed

This ordering prevents race conditions where a dependent operation sees `completed` in the queue before the operation state reflects the merge.
