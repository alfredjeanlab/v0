# Plan: Allow v0 merge without existing worktree

## Overview

Enable `v0 merge` to work with feature branches that don't have an associated worktree directory. Currently, if the worktree was manually removed or never created, merge fails with "Worktree not found". This change adds support for merging branches directly, creating a temporary worktree only when conflict resolution is required.

## Project Structure

Files to modify:
```
bin/
  v0-merge                    # Update to handle branch-only input

packages/merge/lib/
  resolve.sh                  # Add mg_resolve_branch_to_ref() for branch input
  execution.sh                # Add mg_do_merge_without_worktree() for direct merges
  conflict.sh                 # Update mg_launch_resolve_session() to create temp worktree

packages/state/lib/
  merge-ready.sh              # Update sm_is_merge_ready() to allow missing worktree

tests/
  v0-merge.bats               # Add tests for worktree-less merge
```

## Dependencies

None - pure shell script changes using existing git functionality.

## Implementation Phases

### Phase 1: Add Branch Resolution Function

Add a new function to `packages/merge/lib/resolve.sh` that resolves a branch name directly (without requiring a worktree):

```bash
# mg_resolve_branch_to_ref <branch-name>
# Resolve branch name to git ref, verify it exists
# Sets: MG_BRANCH, MG_HAS_WORKTREE=false
# Returns 0 if branch exists, 1 if not
mg_resolve_branch_to_ref() {
    local branch="$1"

    # Check if branch exists locally or remotely
    if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        return 0
    fi

    # Check remote
    if git show-ref --verify --quiet "refs/remotes/${V0_GIT_REMOTE}/${branch}" 2>/dev/null; then
        # Create local tracking branch
        git branch "${branch}" "${V0_GIT_REMOTE}/${branch}"
        MG_BRANCH="${branch}"
        MG_HAS_WORKTREE=false
        return 0
    fi

    echo "Error: Branch '${branch}' not found locally or on remote" >&2
    return 1
}
```

Update `mg_resolve_operation_to_worktree()` to set `MG_HAS_WORKTREE=true` when worktree exists, and return success with `MG_HAS_WORKTREE=false` when worktree is missing but branch exists:

```bash
mg_resolve_operation_to_worktree() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    # ... existing state file check ...

    local worktree
    worktree=$(sm_read_state "${op_name}" "worktree")

    # Get branch from state (even if worktree missing)
    local branch
    branch=$(sm_read_state "${op_name}" "branch")

    if [[ -z "${worktree}" ]] || [[ "${worktree}" = "null" ]] || [[ ! -d "${worktree}" ]]; then
        # Worktree missing - try branch-only merge if branch exists
        if [[ -n "${branch}" ]] && [[ "${branch}" != "null" ]]; then
            if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
                MG_BRANCH="${branch}"
                MG_HAS_WORKTREE=false
                MG_OP_NAME="${op_name}"
                return 0
            fi
        fi

        echo "Error: Worktree not found and branch doesn't exist for '${op_name}'" >&2
        return 1
    fi

    # ... existing worktree validation ...
    MG_HAS_WORKTREE=true
}
```

**Verification:** Unit tests in `packages/merge/tests/resolve.bats`

### Phase 2: Add Direct Merge Function

Add a worktree-less merge function to `packages/merge/lib/execution.sh`:

```bash
# mg_do_merge_without_worktree <branch>
# Execute merge for branch without a worktree (fast-forward only)
# Returns 0 on success, 1 if conflicts (requires worktree for resolution)
mg_do_merge_without_worktree() {
    local branch="$1"

    # Try fast-forward first (no worktree needed)
    if git merge --ff-only "${branch}" 2>/dev/null; then
        echo "Fast-forward merge successful"
        return 0
    fi

    # Can't do non-FF merge without worktree for rebase
    echo "Cannot fast-forward merge. Conflicts require worktree for resolution." >&2
    return 1
}

# mg_cleanup_branch_only <branch>
# Clean up branch when no worktree exists
mg_cleanup_branch_only() {
    local branch="$1"

    git branch -d "${branch}" 2>/dev/null || git branch -D "${branch}"
    echo "Removed branch: ${branch}"
}
```

**Verification:** Unit tests in `packages/merge/tests/execution.bats`

### Phase 3: Update v0-merge Command

Modify `bin/v0-merge` to support branches without worktrees:

```bash
# After resolving input, check if worktree exists
if mg_is_input_path "${INPUT}"; then
    mg_resolve_path_to_worktree "${INPUT}"
    HAS_WORKTREE=true
else
    MG_OP_NAME="${INPUT}"
    mg_resolve_operation_to_worktree "${INPUT}"
    HAS_WORKTREE="${MG_HAS_WORKTREE}"
fi

if [[ "${HAS_WORKTREE}" = true ]]; then
    WORKTREE="${MG_WORKTREE}"
    TREE_DIR="${MG_TREE_DIR}"
    OP_NAME="${MG_OP_NAME:-}"

    mg_validate_worktree "${WORKTREE}"
    BRANCH="$(mg_get_branch "${WORKTREE}")"
else
    # No worktree - use branch directly
    BRANCH="${MG_BRANCH}"
    WORKTREE=""
    TREE_DIR=""
    OP_NAME="${MG_OP_NAME:-}"

    echo "Note: No worktree found. Attempting direct branch merge."
fi

# All git operations must run from main repo
cd "${MAIN_REPO}"

if [[ "${HAS_WORKTREE}" = true ]]; then
    # ... existing worktree-based flow (rebase, uncommitted check, etc.) ...
else
    # No worktree - simplified flow
    mg_acquire_lock "${BRANCH}"

    if mg_has_conflicts "${BRANCH}"; then
        if [[ "${RESOLVE}" = true ]]; then
            echo "Conflicts detected. Creating temporary worktree for resolution..."
            mg_create_temp_worktree_for_resolution "${BRANCH}"
            # ... resolution flow using temp worktree ...
        else
            echo
            echo -e "${C_RED}${C_BOLD}Error:${C_RESET} Merge would have conflicts."
            echo "Use --resolve to create a temporary worktree and resolve:"
            echo -e "  ${C_BOLD}v0 merge ${INPUT} --resolve${C_RESET}"
            exit 1
        fi
    else
        # No conflicts - direct merge
        if mg_do_merge_without_worktree "${BRANCH}"; then
            merge_commit=$(mg_get_merge_commit)
            mg_cleanup_branch_only "${BRANCH}"

            if mg_push_and_verify "${merge_commit}"; then
                # ... existing post-merge flow ...
            fi
        fi
    fi
fi
```

**Verification:** Manual test `v0 merge <branch>` without worktree

### Phase 4: Add Temporary Worktree Creation

Add function to create a temporary worktree for conflict resolution in `packages/merge/lib/conflict.sh`:

```bash
# mg_create_temp_worktree_for_resolution <branch>
# Creates a temporary worktree for conflict resolution
# Sets: MG_TEMP_WORKTREE, MG_TEMP_TREE_DIR
mg_create_temp_worktree_for_resolution() {
    local branch="$1"

    local temp_tree_dir="${BUILD_DIR}/temp-merge-$(date +%s)"
    local temp_worktree="${temp_tree_dir}/${REPO_NAME}"

    mkdir -p "${temp_tree_dir}"

    if ! git worktree add "${temp_worktree}" "${branch}" 2>/dev/null; then
        echo "Error: Failed to create temporary worktree for ${branch}" >&2
        rm -rf "${temp_tree_dir}"
        return 1
    fi

    MG_TEMP_WORKTREE="${temp_worktree}"
    MG_TEMP_TREE_DIR="${temp_tree_dir}"

    echo "Created temporary worktree: ${temp_worktree}"
}

# mg_cleanup_temp_worktree
# Clean up temporary worktree after resolution
mg_cleanup_temp_worktree() {
    if [[ -n "${MG_TEMP_WORKTREE:-}" ]] && [[ -d "${MG_TEMP_WORKTREE}" ]]; then
        git worktree remove "${MG_TEMP_WORKTREE}" --force 2>/dev/null || true
        rm -rf "${MG_TEMP_TREE_DIR:-}"
    fi
}
```

**Verification:** Test creating and cleaning up temp worktrees

### Phase 5: Update Merge Queue Processing

Update `packages/mergeq/lib/processing.sh` to handle missing worktrees:

```bash
mq_process_merge() {
    local op="$1"

    # Get branch from state (not just worktree)
    local branch worktree
    worktree=$(jq -r '.worktree // ""' "${state_file}")
    branch=$(jq -r '.branch // ""' "${state_file}")

    if [[ -z "${worktree}" ]] || [[ ! -d "${worktree}" ]]; then
        # No worktree - check if branch exists for direct merge
        if [[ -n "${branch}" ]] && git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
            echo "Merging branch directly (no worktree): ${branch}"
            # Call v0-merge with branch name - it handles no-worktree case
            if V0_MERGEQ_CALLER=1 v0-merge "${op}" --resolve; then
                # ... success handling ...
            fi
        else
            echo "Error: No worktree and branch not found: ${branch}" >&2
            mq_update_entry_status "${op}" "${MQ_STATUS_FAILED}"
            # ...
        fi
        return
    fi

    # ... existing worktree-based flow ...
}
```

**Verification:** Test merge queue with operations that have missing worktrees

### Phase 6: Add Integration Tests

Add tests to `tests/v0-merge.bats`:

```bash
@test "merge succeeds without worktree (fast-forward)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a branch directly (no worktree)
    cd "$project_dir"
    git checkout -b feature/test-no-worktree
    echo "test" > testfile.txt
    git add testfile.txt
    git commit -m "test commit"
    git checkout main

    # Merge without worktree
    run v0 merge feature/test-no-worktree
    assert_success
    assert_output --partial "Fast-forward merge successful"
}

@test "merge with conflicts requires --resolve without worktree" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create conflicting branches
    cd "$project_dir"
    echo "main content" > conflict.txt
    git add conflict.txt
    git commit -m "main commit"

    git checkout -b feature/conflict-test HEAD~1
    echo "branch content" > conflict.txt
    git add conflict.txt
    git commit -m "branch commit"
    git checkout main

    # Merge without worktree should fail
    run v0 merge feature/conflict-test
    assert_failure
    assert_output --partial "Merge would have conflicts"
    assert_output --partial "--resolve"
}

@test "merge with --resolve creates temp worktree for conflicts" {
    # ... test that --resolve creates temp worktree and resolves ...
}

@test "merge operation with missing worktree uses branch from state" {
    # ... test that operation with deleted worktree can still merge ...
}
```

**Verification:** Run `scripts/test v0-merge`

## Key Implementation Details

### Worktree Detection Pattern

The key change is tracking whether a worktree exists via `MG_HAS_WORKTREE`:

```bash
if [[ "${MG_HAS_WORKTREE}" = true ]]; then
    # Full flow: uncommitted checks, rebase, conflict resolution in worktree
else
    # Simplified flow: direct merge or temp worktree for conflicts
fi
```

### Fast-Forward vs Conflict Resolution

Without a worktree:
- **Fast-forward possible**: Direct `git merge --ff-only` works
- **Conflicts exist**: Must create temporary worktree for rebase/resolution

### State Preservation

The operation's state file must store the branch name independently:

```json
{
  "worktree": "/path/that/may/not/exist",
  "branch": "feature/my-feature"
}
```

This allows merge to proceed using just the branch even if worktree is gone.

### Cleanup Differences

With worktree:
```bash
mg_cleanup_worktree "${WORKTREE}" "${TREE_DIR}" "${BRANCH}"
```

Without worktree:
```bash
mg_cleanup_branch_only "${BRANCH}"
```

With temp worktree (after conflict resolution):
```bash
mg_cleanup_temp_worktree
mg_cleanup_branch_only "${BRANCH}"
```

## Verification Plan

1. **Unit tests pass:** `scripts/test merge`
2. **Integration tests pass:** `scripts/test v0-merge`
3. **Lint passes:** `make lint`
4. **Full suite passes:** `make check`
5. **Manual verification:**
   - Create branch without worktree, merge with `v0 merge <branch>`
   - Delete existing worktree, merge operation with `v0 merge <op-name>`
   - Test conflict case: merge fails without `--resolve`
   - Test conflict resolution: `v0 merge <branch> --resolve` creates temp worktree
