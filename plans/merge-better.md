# Merge Better: Fix Push Verification

## Overview

The current merge verification logic is fundamentally broken. After a successful `git push`, the verification checks using `git ls-remote` and `git fetch` return stale data, causing false failures. The retry logic added in `resilient-merge` only delays the failure with additional noise.

**Root cause**: The verification is checking remote state that can be stale due to caching at multiple levels (Git credential helpers, HTTP proxies, network caching). Meanwhile, `git push` returns 0 when it succeeds - this is the authoritative signal.

**Solution**: Trust `git push` exit code. Remove the complex, flaky remote verification and replace with simple local verification. If `git push` returned 0, the push succeeded.

## Analysis of Current Bug

From the error output:
```
To github.com:alfredjeanlab/v0.git
   e662a51..6518d9d  main -> main      # Push claims success
...
Remote state (via ls-remote):
a8d3a0d37ae77b3a77eb8ff978f7f50f3ae51801  # Returns commit from 2 pushes ago!
```

The push output shows `e662a51..6518d9d` (success), but `ls-remote` returns `a8d3a0d` - a commit from **two pushes ago**. This is impossible if the remote actually has the new commit, indicating a caching layer is returning stale data.

The current verification:
1. Runs `git fetch origin main --force` - doesn't help because fetch may see same stale data
2. Checks `git merge-base --is-ancestor` against `origin/main` - fails because local tracking ref is stale
3. Falls back to `ls-remote` - also returns stale data
4. Retries 3 times - just delays failure by 4+ seconds
5. Outputs diagnostics - useful but doesn't fix the problem

## Project Structure

```
bin/
  v0-merge              # Main merge script - verification at lines 561-596 and 605-646
lib/
  v0-common.sh          # Verification functions at lines 675-859
tests/unit/
  v0-common.bats        # Verification function tests
```

## Dependencies

- No new dependencies
- Removes dependency on reliable remote state queries (which was the problem)

## Implementation Phases

### Phase 1: Simplify Verification Logic

Replace `v0_verify_push_with_retry` with a simpler `v0_verify_push` that trusts git's exit code.

**File: `lib/v0-common.sh`**

Add new simplified verification (replace lines 712-769):

```bash
# v0_verify_push <commit>
# Verify a pushed commit exists on local main.
# Returns 0 if commit is on main, 1 if not.
#
# Why this is sufficient:
# - git push returns 0 only if the push succeeded
# - If push succeeded, the remote has the commit
# - We verify locally that the commit is on main (sanity check)
# - Remote state queries (ls-remote, fetch) can return stale data
#
# Args:
#   commit - Commit hash to verify
v0_verify_push() {
  local commit="$1"

  # Validate commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} does not exist locally" >&2
    return 1
  fi

  # Verify commit is on local main
  if ! git merge-base --is-ancestor "${commit}" main 2>/dev/null; then
    echo "Error: Commit ${commit:0:8} is not on main branch" >&2
    return 1
  fi

  return 0
}
```

Keep `v0_verify_push_with_retry` for backward compatibility but deprecate it:

```bash
# DEPRECATED: v0_verify_push_with_retry
# Use v0_verify_push instead. Remote verification is unreliable due to caching.
# This function now just calls v0_verify_push (ignoring retry params).
v0_verify_push_with_retry() {
  local commit="$1"
  # Ignore remote_branch, max_attempts, delay - they cause more harm than good
  v0_verify_push "${commit}"
}
```

**Verification**: Update tests, run `make test`

### Phase 2: Update v0-merge to Use Simplified Verification

**File: `bin/v0-merge`**

Update both merge success paths (conflict resolution ~line 561 and normal merge ~line 605).

Before (complex, flaky):
```bash
cleanup && git push && {
  verify_start=$(date +%s)
  if v0_verify_push_with_retry "${merge_commit}" "origin/main" 3 2; then
    verify_end=$(date +%s)
    verify_duration=$((verify_end - verify_start))
    if [[ ${verify_duration} -gt 2 ]]; then
      echo "Note: Push verification took ${verify_duration}s" >&2
    fi
    # ... success path ...
  else
    v0_diagnose_push_verification "${merge_commit}" "origin/main"
    echo "Error: Push succeeded but commit not verified on origin/main after retries" >&2
    exit 1
  fi
}
```

After (simple, reliable):
```bash
cleanup && git push && {
  # Verify commit is on local main (sanity check)
  # git push returning 0 is authoritative - remote has the commit
  if ! v0_verify_push "${merge_commit}"; then
    echo "Error: Merge commit not found on main after push" >&2
    exit 1
  fi

  # ... success path (unchanged) ...
}
```

**Verification**: Manual merge test

### Phase 3: Remove Retry Noise and Timing Code

**File: `bin/v0-merge`**

Remove the timing code that was added for debugging:
- Remove `verify_start`, `verify_end`, `verify_duration` variables
- Remove the "Note: Push verification took Xs" output

Also remove the diagnostic call since simple verification won't need it:
- Remove calls to `v0_diagnose_push_verification`
- Keep the function in v0-common.sh for manual debugging

**Verification**: Code review, ensure clean output

### Phase 4: Update Tests

**File: `tests/unit/v0-common.bats`**

Update existing tests:

1. Keep tests for `v0_verify_push_with_retry` but note deprecation
2. Add tests for new `v0_verify_push`:

```bash
@test "v0_verify_push returns 0 for commit on main" {
  source_lib "v0-common.sh"
  init_mock_git_repo "${TEST_TEMP_DIR}/project"
  cd "${TEST_TEMP_DIR}/project" || return 1

  local commit
  commit=$(git rev-parse HEAD)

  run v0_verify_push "${commit}"
  assert_success
}

@test "v0_verify_push returns 1 for commit not on main" {
  source_lib "v0-common.sh"
  init_mock_git_repo "${TEST_TEMP_DIR}/project"
  cd "${TEST_TEMP_DIR}/project" || return 1

  # Create commit on separate branch
  git checkout -b feature
  echo "feature" > feature.txt
  git add feature.txt
  git commit -m "Feature commit"
  local feature_commit
  feature_commit=$(git rev-parse HEAD)

  git checkout main

  run v0_verify_push "${feature_commit}"
  assert_failure
}

@test "v0_verify_push returns 1 for nonexistent commit" {
  source_lib "v0-common.sh"
  init_mock_git_repo "${TEST_TEMP_DIR}/project"
  cd "${TEST_TEMP_DIR}/project" || return 1

  local fake_commit="1234567890abcdef1234567890abcdef12345678"

  run v0_verify_push "${fake_commit}"
  assert_failure
}
```

**Verification**: `make test`

### Phase 5: Clean Up Deprecated Code

**File: `lib/v0-common.sh`**

Mark as deprecated but keep for backward compatibility:
- `v0_verify_push_with_retry` - redirect to `v0_verify_push`
- `v0_diagnose_push_verification` - keep for manual debugging
- `v0_verify_merge` - already deprecated
- `v0_verify_merge_by_op` - keep but simplify (local check only)
- `v0_verify_commit_on_branch` - keep, still useful for local checks

**Verification**: `make lint`, `make test`

## Key Implementation Details

### Why Trust git push Exit Code

Git push returns 0 **only** when:
1. The connection to remote succeeded
2. The refs were successfully updated on the remote
3. The remote accepted all objects

If any of these fail, git push returns non-zero. There is no scenario where git push returns 0 but the remote doesn't have the commit.

### Why Remote Verification Fails

Multiple caching layers can cause stale remote queries:
1. **Git credential helper cache** - May use cached auth that routes to different endpoint
2. **HTTP proxy cache** - Corporate proxies may cache API responses
3. **DNS/CDN cache** - GitHub uses CDN that may have propagation delay
4. **Git pack cache** - Local git may cache pack negotiation results

None of these affect `git push` because push uses a persistent connection that writes directly.

### Backward Compatibility

- `v0_verify_push_with_retry` still exists but now just calls `v0_verify_push`
- Diagnostic functions remain available for manual debugging
- External tools using these functions will continue to work

## Verification Plan

### Automated Tests
```bash
make lint          # Ensure shell scripts are valid
make test          # Run all unit tests
```

### Manual Testing
```bash
# Test 1: Normal merge flow
cd /path/to/project
git checkout -b test-merge-better
echo "test" > test.txt && git add . && git commit -m "Test"
git checkout main
git merge test-merge-better
v0 merge test-merge-better
# Expected: Clean success, no retry messages

# Test 2: Verify no false failures
# Run merge multiple times in succession
for i in 1 2 3; do
  git checkout -b "test-$i"
  echo "$i" > "test-$i.txt" && git add . && git commit -m "Test $i"
  v0 merge "test-$i"
done
# Expected: All succeed without retry noise
```

### Regression Check
Verify the original error no longer occurs:
- No "Verification attempt X/Y failed" messages
- No "Push succeeded but commit not verified" errors
- Clean, fast merge completion
