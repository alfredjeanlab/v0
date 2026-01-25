# Plan: Allow v0 merge with branch names from queue

## Overview

Enhance `v0 merge <branch>` to fall back to the merge queue and git branch lookup when no operation state file exists. Currently, if a branch is in the merge queue (shown in `v0 status`) but has no associated operation state, `v0 merge <branch>` fails with "No operation found". This change adds a fallback chain that checks the merge queue and remote branches, allowing direct merges of queued branches.

## Project Structure

Files to modify:
```
packages/merge/lib/
  resolve.sh                  # Add mg_resolve_queue_entry() fallback

packages/mergeq/lib/
  io.sh                       # Add mq_get_entry_branch() helper (if needed)

bin/
  v0-merge                    # Update error handling to suggest alternatives

tests/
  v0-merge.bats               # Add tests for queue-based branch merges
```

## Dependencies

None - pure shell script changes using existing merge queue and git functionality.

## Implementation Phases

### Phase 1: Add Queue Entry Resolution Function

Add a new function to `packages/merge/lib/resolve.sh` that attempts to resolve a branch name via the merge queue:

```bash
# mg_resolve_queue_entry_to_branch <name>
# Resolve an operation/branch name via the merge queue
# Sets: MG_BRANCH, MG_HAS_WORKTREE=false, MG_OP_NAME
# Returns 0 if found in queue and branch exists, 1 if not
mg_resolve_queue_entry_to_branch() {
    local name="$1"

    # Check if entry exists in merge queue
    if ! mq_entry_exists "${name}"; then
        return 1
    fi

    # Get worktree/branch info from queue entry
    local worktree
    worktree=$(mq_read_entry_field "${name}" "worktree")

    # Queue entries may store branch in worktree field (path-based)
    # or we can derive branch from the operation name pattern
    local branch="${name}"

    # Check if branch exists locally
    if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        MG_OP_NAME="${name}"
        MG_WORKTREE=""
        MG_TREE_DIR=""
        return 0
    fi

    # Check remote
    if git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
        # Create local tracking branch
        git branch "${branch}" "${V0_GIT_REMOTE}/${branch}" 2>/dev/null || true
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        MG_OP_NAME="${name}"
        MG_WORKTREE=""
        MG_TREE_DIR=""
        return 0
    fi

    return 1
}
```

**Verification:** Unit test in `packages/merge/tests/resolve.bats`

### Phase 2: Update Operation Resolution with Fallback Chain

Modify `mg_resolve_operation_to_worktree()` in `packages/merge/lib/resolve.sh` to add a fallback chain when no state file exists:

```bash
mg_resolve_operation_to_worktree() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    if [[ ! -f "${state_file}" ]]; then
        # Fallback 1: Check merge queue for this entry
        if mg_resolve_queue_entry_to_branch "${op_name}"; then
            return 0
        fi

        # Fallback 2: Try direct branch resolution (local or remote)
        if mg_resolve_branch_to_ref "${op_name}"; then
            MG_OP_NAME=""  # No operation, just a branch
            return 0
        fi

        # All fallbacks failed
        echo "Error: No operation found for '${op_name}'" >&2
        echo "" >&2
        echo "List operations with: v0 status" >&2

        # Check if it's a pending merge and provide helpful hint
        if mq_entry_exists "${op_name}"; then
            echo "" >&2
            echo "Note: '${op_name}' is in the merge queue but the branch doesn't exist." >&2
            echo "The branch may need to be fetched: git fetch ${V0_GIT_REMOTE}" >&2
        fi

        return 1
    fi

    # ... rest of existing function (worktree resolution from state) ...
}
```

**Verification:** Test `v0 merge <queue-entry>` when no state file exists

### Phase 3: Update v0-merge Error Messages

Enhance error messages in `bin/v0-merge` to provide better guidance when resolution fails:

```bash
# After resolution attempt, provide more context
if ! mg_resolve_operation_to_worktree "${INPUT}"; then
    # Check what exists to give better error
    if mq_entry_exists "${INPUT}"; then
        echo "Hint: Entry is in merge queue. Try fetching: git fetch ${V0_GIT_REMOTE}"
    elif git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${INPUT}" 2>/dev/null; then
        echo "Hint: Branch exists on remote. Try: git fetch && v0 merge ${INPUT}"
    fi
    exit 1
fi
```

**Verification:** Manual test with various error scenarios

### Phase 4: Add Queue Cleanup on Successful Merge

Ensure that when merging a queue entry directly (without operation state), the queue entry is properly updated:

The existing `mg_update_queue_entry` function in `bin/v0-merge` (lines 181, 214, 237) already handles this, but verify it works when `OP_NAME` comes from queue resolution:

```bash
# In v0-merge, after successful merge:
if [[ -z "${V0_MERGEQ_CALLER:-}" ]]; then
    # Use OP_NAME from resolution (may be from queue, not state)
    if [[ -n "${OP_NAME}" ]]; then
        mg_update_queue_entry "${OP_NAME}" "${BRANCH}"
    fi
fi
```

**Verification:** Test that queue entries are marked completed after merge

### Phase 5: Add Integration Tests

Add tests to `tests/v0-merge.bats`:

```bash
@test "merge succeeds with queue entry when no state file" {
    local project_dir
    project_dir=$(setup_isolated_project)
    cd "$project_dir"

    # Create a branch and push to origin
    git checkout -b feature/queue-test
    echo "test" > testfile.txt
    git add testfile.txt
    git commit -m "test commit"
    git push origin feature/queue-test
    git checkout main

    # Add to merge queue without creating operation state
    mq_add_entry "feature/queue-test" "" 0 "branch"

    # Verify merge works
    run v0 merge feature/queue-test
    assert_success

    # Verify queue entry updated
    local status
    status=$(mq_get_entry_status "feature/queue-test")
    [[ "$status" = "completed" ]]
}

@test "merge from queue entry resolves remote branch" {
    local project_dir
    project_dir=$(setup_isolated_project)
    cd "$project_dir"

    # Create branch only on remote (simulate external CI adding to queue)
    git checkout -b chore/external-branch
    echo "external" > external.txt
    git add external.txt
    git commit -m "external commit"
    git push origin chore/external-branch
    git checkout main
    git branch -D chore/external-branch  # Delete local

    # Add to merge queue
    mq_add_entry "chore/external-branch" "" 0 "branch"

    # Verify merge fetches and works
    run v0 merge chore/external-branch
    assert_success
}

@test "merge error shows helpful hint when queue entry exists but branch missing" {
    local project_dir
    project_dir=$(setup_isolated_project)
    cd "$project_dir"

    # Add phantom entry to queue (branch doesn't exist)
    mq_add_entry "feature/phantom" "" 0 "branch"

    run v0 merge feature/phantom
    assert_failure
    assert_output --partial "No operation found"
    assert_output --partial "in the merge queue"
    assert_output --partial "git fetch"
}
```

**Verification:** Run `scripts/test v0-merge`

## Key Implementation Details

### Resolution Fallback Chain

When `v0 merge <name>` is called with a non-path argument:

```
1. Check for state file: ${BUILD_DIR}/operations/${name}/state.json
   ├─ Found → Use worktree/branch from state (existing behavior)
   └─ Not found → Continue to fallbacks

2. Check merge queue: mq_entry_exists("${name}")
   ├─ Found → Try to resolve branch locally or from remote
   │   ├─ Branch exists → Set MG_BRANCH, MG_HAS_WORKTREE=false
   │   └─ Branch missing → Continue to next fallback
   └─ Not found → Continue to next fallback

3. Direct branch resolution: mg_resolve_branch_to_ref("${name}")
   ├─ Branch exists locally → Use it directly
   ├─ Branch exists on remote → Create local tracking branch
   └─ Branch missing → Error with helpful hints
```

### Queue Entry Status Flow

When merging a queue entry directly:

```
pending → processing (lock acquired) → completed (after push)
                                    → failed (on error)
```

### Compatibility with Existing Flows

This change is additive and doesn't break existing behavior:

- Operations with state files: unchanged (state file lookup succeeds)
- Worktree-based merges: unchanged (path detection handles these)
- Queue processing (`v0-mergeq-process`): unchanged (uses operation lookup)

The new fallback only activates when:
1. Input is not a path
2. No state file exists for the name
3. Entry exists in queue OR branch exists on remote

## Verification Plan

1. **Unit tests pass:** `scripts/test merge`
2. **Integration tests pass:** `scripts/test v0-merge`
3. **Lint passes:** `make lint`
4. **Full suite passes:** `make check`
5. **Manual verification:**
   - Add entry to merge queue manually, merge with `v0 merge <name>`
   - Verify `v0 status` shows entry, then `v0 merge <name>` works
   - Test error case: queue entry with missing branch shows helpful message
   - Test remote-only branch: `v0 merge <remote-branch>` fetches and merges
