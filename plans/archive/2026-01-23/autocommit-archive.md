# Plan: Auto-commit Archived Plans

**Root Feature:** `v0-5ec3`

## Overview

Implement auto-commit for archived plans to match the existing auto-commit behavior for:
1. New plans (committed in `bin/v0-plan-exec`)
2. Plans updated with epic IDs after decompose (committed in `bin/v0-decompose`)

Currently, when a plan is archived via `archive_plan()` in `lib/mergeq/processing.sh`, the file is moved to `plans/archive/{date}/` but not committed to git.

## Project Structure

Files to modify:
```
lib/
  v0-common.sh           # archive_plan() - add auto-commit logic
tests/unit/
  plan-archive.bats      # Add tests for auto-commit behavior
```

No new files needed.

## Dependencies

None - uses existing git functionality and patterns already in the codebase.

## Implementation Phases

### Phase 1: Add commit logic to archive_plan()

Modify `archive_plan()` in `lib/v0-common.sh` (lines 232-269) to commit the archived plan after moving it.

**Pattern to follow** (from `bin/v0-plan-exec:54-63`):
```bash
if ! v0_git_worktree_clean "${V0_ROOT}"; then
  v0_log "plan:commit" "Skipped (worktree has uncommitted changes)"
else
  if git -C "${V0_ROOT}" add "${archive_path}" && \
     git -C "${V0_ROOT}" commit -m "Archive plan: ${plan_name}" -m "Auto-committed by v0"; then
    v0_log "plan:commit" "Committed ${archive_path}"
  fi
fi
```

**Changes to `archive_plan()`:**

After the `mv` command succeeds (line 268), add:
```bash
# Auto-commit the archived plan
if git -C "${V0_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
  local archive_path="${archive_dir}/${plan_name}"
  local relative_path="${V0_PLANS_DIR}/archive/${archive_date}/${plan_name}"

  # Stage both the deletion (from original location) and addition (to archive)
  if git -C "${V0_ROOT}" add -A "${V0_PLANS_DIR}/" && \
     git -C "${V0_ROOT}" commit -m "Archive plan: ${plan_name%.md}" \
       -m "Auto-committed by v0"; then
    v0_log "archive:commit" "Committed archived plan: ${relative_path}"
  else
    v0_log "archive:commit" "Failed to commit archived plan"
  fi
fi
```

**Key considerations:**
- Use `git add -A` on the plans directory to capture both the deletion from source and addition to archive
- Don't check `v0_git_worktree_clean` since archive happens during merge completion when worktree might have other changes staged
- Use existing `v0_log` pattern for consistency

### Phase 2: Add unit tests

Add tests to `tests/unit/plan-archive.bats`:

```bash
@test "archive_plan commits the archived plan" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    # Initialize git repo
    git init
    git config user.email "test@test.com"
    git config user.name "Test"

    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/test-feature.md"
    git add "${PLANS_DIR}/test-feature.md"
    git commit -m "Initial commit"

    archive_plan "plans/test-feature.md"

    # Check commit was made
    run git log --oneline -1
    assert_success
    assert_output --partial "Archive plan: test-feature"
}

@test "archive_plan commits deletion and addition" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    git init
    git config user.email "test@test.com"
    git config user.name "Test"

    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/commit-test.md"
    git add "${PLANS_DIR}/commit-test.md"
    git commit -m "Initial commit"

    archive_plan "plans/commit-test.md"

    # Verify archived file is tracked
    local archive_date
    archive_date=$(date +%Y-%m-%d)
    run git ls-files "${PLANS_DIR}/archive/${archive_date}/commit-test.md"
    assert_success
    assert_output --partial "commit-test.md"

    # Verify original file is no longer tracked
    run git ls-files "${PLANS_DIR}/commit-test.md"
    assert_success
    assert_output ""
}

@test "archive_plan works outside git repo (no commit)" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    # No git init - not a repo
    mkdir -p "${PLANS_DIR}"
    echo "# Test Plan" > "${PLANS_DIR}/no-repo.md"

    run archive_plan "plans/no-repo.md"
    assert_success

    local archive_date
    archive_date=$(date +%Y-%m-%d)
    assert_file_exists "${PLANS_DIR}/archive/${archive_date}/no-repo.md"
}
```

### Phase 3: Verify and test

1. Run linter: `make lint`
2. Run tests: `make test`
3. Manual verification:
   - Create a test plan: `echo "# Test" > plans/test-autocommit.md`
   - Commit it: `git add plans/test-autocommit.md && git commit -m "Add test plan"`
   - Source the library and archive:
     ```bash
     source lib/v0-common.sh
     v0_load_config
     archive_plan "plans/test-autocommit.md"
     ```
   - Verify commit: `git log --oneline -1` should show "Archive plan: test-autocommit"

## Key Implementation Details

### Commit message format

Following existing conventions:
- `Add plan: {name}` - new plan created
- `Update plan: {name}` - plan updated after decompose
- `Archive plan: {name}` - plan archived after merge completion

### Git staging approach

Use `git add -A "${V0_PLANS_DIR}/"` to capture:
- Deletion of `plans/{name}.md`
- Addition of `plans/archive/{date}/{name}.md`

This ensures atomic commit of the move operation.

### Error handling

- Silent failure if not in git repo (maintains current behavior)
- Log failure if commit fails but don't fail the archive operation itself
- Archive file move still succeeds even if commit fails

### Worktree state

Don't check `v0_git_worktree_clean` because:
1. Archive happens during merge queue processing
2. Other changes might be staged/pending
3. The commit only touches plan files, which is safe

## Verification Plan

1. **Unit tests**: All existing tests pass + new commit tests pass
2. **Linter**: `make lint` passes
3. **Integration test** (manual):
   - Run full workflow: plan → decompose → feature → merge
   - Verify `git log` shows "Archive plan:" commit after merge completes
4. **Edge cases**:
   - Plan archived outside git repo (should not fail)
   - Plan archived when plans dir has other uncommitted changes (should still commit)
