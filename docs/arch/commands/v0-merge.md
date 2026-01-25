# v0-merge

**Purpose:** Merge a worktree branch to main.

## Usage

```bash
v0 merge <operation>                 # Merge by operation name
v0 merge <operation> --resolve       # Auto-resolve conflicts
v0 merge /path/to/worktree           # Merge by worktree path
v0 merge fix/PROJ-abc123             # Merge by branch name
```

## Control Flow Overview

```mermaid
flowchart TD
    start([v0 merge]) --> parse[Parse arguments]
    parse --> resolve_input{Input type?}

    resolve_input -->|path| resolve_path[Resolve path to worktree]
    resolve_input -->|name| resolve_op[Resolve operation/branch]

    resolve_path --> has_wt{Has worktree?}
    resolve_op --> has_wt

    has_wt -->|yes| validate_wt[Validate worktree]
    has_wt -->|no| branch_only[Branch-only mode]

    validate_wt --> check_rebase[Abort incomplete rebase]
    check_rebase --> check_uncommitted{Uncommitted changes?}

    check_uncommitted -->|yes| resolve_flag1{--resolve?}
    resolve_flag1 -->|yes| launch_uncommitted[Launch Claude for uncommitted]
    resolve_flag1 -->|no| error_uncommitted[Error: uncommitted changes]
    launch_uncommitted --> recheck_uncommitted{Still uncommitted?}
    recheck_uncommitted -->|yes| error_uncommitted
    recheck_uncommitted -->|no| acquire_lock

    check_uncommitted -->|no| acquire_lock[Acquire merge lock]
    branch_only --> acquire_lock

    acquire_lock --> ensure_develop[Checkout & pull develop branch]
    ensure_develop --> check_conflicts{Conflicts detected?}

    check_conflicts -->|yes| conflict_flow
    check_conflicts -->|no| merge_flow

    subgraph conflict_flow[Conflict Resolution Flow]
        cf_resolve{--resolve?}
        cf_resolve -->|no| cf_error[Error: conflicts exist]
        cf_resolve -->|yes| cf_temp_wt{Has worktree?}
        cf_temp_wt -->|no| cf_create_temp[Create temp worktree]
        cf_temp_wt -->|yes| cf_launch
        cf_create_temp --> cf_launch[Launch Claude resolve session]
        cf_launch --> cf_wait[Wait for session]
        cf_wait --> cf_check{Conflicts resolved?}
        cf_check -->|no| cf_fail[Error: resolution failed]
        cf_check -->|yes| cf_merge[Do merge]
    end

    subgraph merge_flow[Direct Merge Flow]
        mf_has_wt{Has worktree?}
        mf_has_wt -->|yes| mf_do_merge[mg_do_merge]
        mf_has_wt -->|no| mf_ff[Fast-forward only]
        mf_ff -->|success| mf_cleanup_branch
        mf_ff -->|fail| mf_need_wt{--resolve?}
        mf_need_wt -->|no| mf_error[Error: cannot fast-forward]
        mf_need_wt -->|yes| mf_temp[Create temp worktree]
        mf_temp --> mf_do_merge
        mf_do_merge --> mf_cleanup
    end

    cf_merge --> post_merge
    mf_cleanup --> post_merge
    mf_cleanup_branch --> post_merge

    subgraph post_merge[Post-Merge Steps]
        pm_push[Push to remote]
        pm_push --> pm_verify[Verify push]
        pm_verify --> pm_record[Record merge commit]
        pm_record --> pm_state[Update operation state]
        pm_state --> pm_queue[Update queue entry]
        pm_queue --> pm_trigger[Trigger dependents]
        pm_trigger --> pm_notify[Notify merge]
        pm_notify --> pm_delete[Delete remote branch]
    end

    post_merge --> done([Done])
```

## Input Resolution

The merge command accepts three types of input:

```mermaid
flowchart TD
    input[Input] --> check{Input type?}

    check -->|"starts with / or ."| path_mode[Path Mode]
    check -->|"other"| name_mode[Name Mode]

    path_mode --> is_git{Is git repo?}
    is_git -->|yes| use_as_wt[Use as worktree]
    is_git -->|no| append_repo[Append REPO_NAME]
    append_repo --> use_as_wt

    name_mode --> has_state{Has state.json?}
    has_state -->|yes| read_wt[Read worktree from state]
    has_state -->|no| fallback1[Check merge queue]

    read_wt --> wt_exists{Worktree exists?}
    wt_exists -->|yes| use_wt[Use worktree + branch]
    wt_exists -->|no| check_branch[Check branch exists]

    fallback1 -->|found| check_branch
    fallback1 -->|not found| fallback2[Check local/remote branch]
    fallback2 -->|found| check_branch
    fallback2 -->|not found| error[Error: not found]

    check_branch -->|exists| branch_only[Branch-only merge]
    check_branch -->|not exists| check_phase{Check operation phase}

    check_phase -->|merged| error_merged[Error: already merged]
    check_phase -->|cancelled| error_cancelled[Error: cancelled]
    check_phase -->|failed| attempt_recovery[Attempt recovery from remote]
```

## Merge Strategy

```mermaid
flowchart TD
    start[mg_do_merge] --> try_ff[Try fast-forward]

    try_ff -->|success| done_ff[Done: FF merge]
    try_ff -->|fail| try_rebase[Rebase onto develop]

    try_rebase -->|success| retry_ff[Retry fast-forward]
    try_rebase -->|fail| abort_rebase[Abort rebase]

    retry_ff -->|success| done_rebase[Done: FF after rebase]
    retry_ff -->|fail| abort_rebase

    abort_rebase --> try_merge[Try regular merge]

    try_merge -->|success| done_merge[Done: merge commit]
    try_merge -->|fail| abort_merge[Abort merge]

    abort_merge --> error[Error: conflicts]
```

## Conflict Detection

Conflicts are detected **before** attempting the actual merge using `git merge-tree`:

```bash
git merge-tree --write-tree HEAD <branch>
```

This allows the command to:
1. Fail fast with a helpful message when `--resolve` is not provided
2. Set up the resolution environment before triggering conflicts

## Uncommitted Changes Handling

When a worktree has uncommitted changes:

```mermaid
flowchart TD
    detect[Detect uncommitted changes] --> resolve{--resolve flag?}

    resolve -->|no| error[Error with instructions]
    resolve -->|yes| launch[Launch Claude session]

    launch --> gather[Gather context]
    gather --> |wk issues| context1[Related issues]
    gather --> |v0 state| context2[Operation state]

    context1 --> prompt[Build prompt]
    context2 --> prompt

    prompt --> tmux[Create tmux session]
    tmux --> wait[Wait for completion]
    wait --> recheck{Still uncommitted?}

    recheck -->|yes| fail[Error: not resolved]
    recheck -->|no| continue[Continue to merge]
```

## Conflict Resolution Flow

```mermaid
flowchart TD
    start[Conflict detected] --> has_wt{Has worktree?}

    has_wt -->|no| create_temp[Create temp worktree]
    has_wt -->|yes| start_rebase
    create_temp --> start_rebase

    start_rebase[Start rebase to trigger conflicts] --> gather[Gather context]

    gather --> main_commits[Commits on main since divergence]
    gather --> branch_commits[Commits on branch]

    main_commits --> build_prompt
    branch_commits --> build_prompt

    build_prompt[Build resolution prompt] --> setup_hooks[Setup Stop hook]
    setup_hooks --> create_done[Create ./done script]
    create_done --> launch_tmux[Launch tmux session]

    launch_tmux --> wait[Wait for session to end]
    wait --> check_conflicts{Conflicts resolved?}

    check_conflicts -->|no| check_rebase{Rebase complete?}
    check_rebase -->|no| fail[Error: rebase incomplete]
    check_rebase -->|yes| fail

    check_conflicts -->|yes| do_merge[Execute merge]
    do_merge --> cleanup[Cleanup temp worktree if used]
```

## Post-Merge Operations

After a successful merge, these steps execute in order:

| Step | Function | Description |
|------|----------|-------------|
| 1 | `mg_push_and_verify` | Push to remote, verify commit landed |
| 2 | `mg_record_merge_commit` | Store merge commit hash in operation state |
| 3 | `mg_update_operation_state` | Set `phase=merged`, `merged_at` |
| 4 | `mg_update_queue_entry` | Mark queue entry as `completed` |
| 5 | `mg_trigger_dependents` | Resume operations blocked by this one |
| 6 | `mg_notify_merge` | Send desktop notification |
| 7 | `mg_delete_remote_branch` | Clean up remote branch |

## Error Handling

| Error | Condition | Resolution |
|-------|-----------|------------|
| Lock held | Another merge in progress | Wait or remove stale lock |
| Uncommitted changes | Worktree is dirty | Use `--resolve` or commit manually |
| Conflicts | Merge would conflict | Use `--resolve` for auto-resolution |
| Push failed | Remote rejected push | Check permissions, fetch and retry |
| Verify failed | Commit not on main | Investigation required |
| Already merged | Operation phase is `merged` | No action needed |
| Branch missing | No local or remote branch | Fetch or recreate |

## Locking

The merge command uses a file-based lock at `${BUILD_DIR}/.merge.lock` to prevent concurrent merges:

- Lock contains: `<branch> (pid <pid>)`
- Released automatically via EXIT trap
- Stale locks can be manually removed

## Integration with Merge Queue

When called by `v0 mergeq`:
- Environment variable `V0_MERGEQ_CALLER` is set
- Queue entry updates are skipped (mergeq handles them)
- Same merge logic applies
