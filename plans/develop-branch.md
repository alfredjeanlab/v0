# Implementation Plan: V0_DEVELOP_BRANCH Configuration

**Root Feature:** `v0-9568`

## Overview

Rename `V0_MAIN_BRANCH` to `V0_DEVELOP_BRANCH` throughout the codebase and replace all hardcoded `main` branch references with the configurable variable. Add the variable as a commented option in the default `.v0.rc` template and create tests to verify the configuration is respected.

## Project Structure

Key files affected:
```
lib/
  v0-common.sh        # Default definition and export (rename + document)
  worker-common.sh    # Replace hardcoded "main"/"master" check
bin/
  v0-shutdown         # Replace V0_MAIN_BRANCH -> V0_DEVELOP_BRANCH (9 uses)
  v0-mergeq           # Replace V0_MAIN_BRANCH -> V0_DEVELOP_BRANCH (6 uses + 3 hardcoded)
  v0-fix              # Replace hardcoded "main" (5 locations)
  v0-chore            # Replace hardcoded "main" (5 locations)
  v0-merge            # Replace hardcoded "main" (2 locations)
.v0.rc                # Add commented V0_DEVELOP_BRANCH example
README.md             # Document the configuration option
tests/unit/
  v0-common.bats      # Add tests for V0_DEVELOP_BRANCH defaults and overrides
```

## Dependencies

None - uses existing codebase utilities and shell configuration patterns.

## Implementation Phases

### Phase 1: Rename Variable in Core Configuration

Update the variable definition and exports in `lib/v0-common.sh`.

**File:** `lib/v0-common.sh`

Changes:
1. Line 125: Rename default `V0_MAIN_BRANCH="main"` to `V0_DEVELOP_BRANCH="main"`
2. Line 160: Update export statement
3. Line 179: Update standalone mode initialization

```bash
# Before (line 125)
V0_MAIN_BRANCH="main"

# After
V0_DEVELOP_BRANCH="main"
```

```bash
# Before (line 160)
export V0_BUILD_DIR V0_PLANS_DIR V0_MAIN_BRANCH V0_FEATURE_BRANCH ...

# After
export V0_BUILD_DIR V0_PLANS_DIR V0_DEVELOP_BRANCH V0_FEATURE_BRANCH ...
```

**Verification:** Run `make lint` and confirm no syntax errors.

---

### Phase 2: Update Existing V0_MAIN_BRANCH References

Replace all uses of `V0_MAIN_BRANCH` with `V0_DEVELOP_BRANCH` in scripts.

**File:** `bin/v0-shutdown` (9 occurrences)
- Line 35: Help text
- Lines 247, 249, 253: Local branch verification
- Lines 279, 281, 285: Remote branch verification

**File:** `bin/v0-mergeq` (6 occurrences)
- Lines 608, 609, 610, 613: Branch checkout logic
- Lines 622, 658: Pull/push operations

Simple find-and-replace: `V0_MAIN_BRANCH` -> `V0_DEVELOP_BRANCH`

**Verification:** `grep -r "V0_MAIN_BRANCH" bin/ lib/` should return no results.

---

### Phase 3: Replace Hardcoded 'main' References

Convert hardcoded `main` branch references to use `V0_DEVELOP_BRANCH`.

**File:** `bin/v0-fix` (5 locations)
```bash
# Before (lines 104-105)
git fetch origin main
git reset --hard origin/main

# After
git fetch origin "${V0_DEVELOP_BRANCH}"
git reset --hard "origin/${V0_DEVELOP_BRANCH}"
```

Apply same pattern at:
- Lines 187: `origin/main..HEAD` -> `origin/${V0_DEVELOP_BRANCH}..HEAD`
- Lines 234-235: fetch/reset
- Lines 307-308: fetch/reset

**File:** `bin/v0-chore` (5 locations)
- Lines 120-121: fetch/reset
- Lines 234-235: fetch/reset
- Lines 271-272: fetch/reset

**File:** `bin/v0-merge` (2 locations)
- Lines 327-328: fetch/rebase
- Lines 398-399: fetch/rebase

**File:** `bin/v0-mergeq` (3 log messages)
- Lines 861-862: `origin/main` in error messages
- Lines 935-936: Similar messages

**File:** `lib/worker-common.sh` (1 location)
```bash
# Before (line 68)
if [[ -n "${branch}" ]] && [[ "${branch}" != "main" ]] && [[ "${branch}" != "master" ]]; then

# After - protect both configured develop branch and common defaults
if [[ -n "${branch}" ]] && [[ "${branch}" != "${V0_DEVELOP_BRANCH:-main}" ]] && [[ "${branch}" != "main" ]] && [[ "${branch}" != "master" ]]; then
```

**Verification:**
```bash
grep -rn '"main"' bin/ lib/ | grep -v "# " | grep -v "domain"
grep -rn "'main'" bin/ lib/
grep -rn "origin/main" bin/ lib/
```
Should only return comments, unrelated strings, or documentation.

---

### Phase 4: Update Configuration Template

Add `V0_DEVELOP_BRANCH` as a commented option in `.v0.rc`.

**File:** `.v0.rc`

Add after other branch configuration options:
```bash
# Target branch for merges and resets (default: main)
# V0_DEVELOP_BRANCH="develop"
```

**File:** `README.md`

Update the Configuration section to document `V0_DEVELOP_BRANCH`:
```markdown
V0_DEVELOP_BRANCH="main"     # Target branch for merges (default: main)
```

**Verification:** Manual review of `.v0.rc` and `README.md`.

---

### Phase 5: Add Tests

Create tests to validate `V0_DEVELOP_BRANCH` configuration.

**File:** `tests/unit/v0-common.bats`

Add tests after existing `v0_load_config` tests:

```bash
@test "v0_load_config sets V0_DEVELOP_BRANCH default to main" {
  create_v0rc
  cd "$V0_TEST_ROOT"

  v0_load_config

  [[ "${V0_DEVELOP_BRANCH}" == "main" ]]
}

@test "v0_load_config allows V0_DEVELOP_BRANCH override" {
  create_v0rc
  echo 'V0_DEVELOP_BRANCH="develop"' >> "$V0_TEST_ROOT/.v0.rc"
  cd "$V0_TEST_ROOT"

  v0_load_config

  [[ "${V0_DEVELOP_BRANCH}" == "develop" ]]
}

@test "v0_load_config exports V0_DEVELOP_BRANCH" {
  create_v0rc
  cd "$V0_TEST_ROOT"

  v0_load_config

  # Verify it's exported by checking in subshell
  run bash -c 'echo "${V0_DEVELOP_BRANCH}"'
  [[ "${output}" == "main" ]]
}
```

**Verification:** `make test-file FILE=tests/unit/v0-common.bats`

---

### Phase 6: Verify Complete Implementation

Run full test suite and manual verification.

1. **Lint check:**
   ```bash
   make lint
   ```

2. **Run all tests:**
   ```bash
   make test
   ```

3. **Grep verification (no remaining hardcoded references):**
   ```bash
   # Should return empty or only comments
   grep -rn "V0_MAIN_BRANCH" bin/ lib/ tests/

   # Should only return documentation/comments
   grep -rn '"main"' bin/ lib/ | grep -v "\.md:" | grep -v "#"
   ```

4. **Manual test with custom branch:**
   ```bash
   # In a test project with V0_DEVELOP_BRANCH="develop" in .v0.rc
   # Verify that merge operations target "develop" branch
   ```

## Key Implementation Details

### Naming Choice

The variable is renamed from `V0_MAIN_BRANCH` to `V0_DEVELOP_BRANCH` to better reflect its purpose: it's the target development branch for merges, which may not always be called "main" (could be "develop", "trunk", etc.).

### Fallback Pattern

In contexts where the variable might be unset (standalone mode), use the fallback pattern:
```bash
${V0_DEVELOP_BRANCH:-main}
```

### Branch Protection

The worker-common.sh branch protection check should protect:
1. The configured `V0_DEVELOP_BRANCH`
2. Common defaults ("main", "master") as safety fallbacks

### Git Command Pattern

All git commands referencing the develop branch should use:
```bash
git fetch origin "${V0_DEVELOP_BRANCH}"
git reset --hard "origin/${V0_DEVELOP_BRANCH}"
git rebase "origin/${V0_DEVELOP_BRANCH}"
git push origin "${V0_DEVELOP_BRANCH}"
```

## Verification Plan

| Check | Command | Expected |
|-------|---------|----------|
| Lint passes | `make lint` | Exit 0, no errors |
| Tests pass | `make test` | All tests pass |
| No old variable | `grep -r V0_MAIN_BRANCH bin/ lib/` | Empty output |
| No hardcoded main | `grep -rn '"main"' bin/ lib/ \| grep -v "#"` | Only safe contexts |
| Default works | Source config, echo $V0_DEVELOP_BRANCH | "main" |
| Override works | Add to .v0.rc, source, echo | Custom value |
