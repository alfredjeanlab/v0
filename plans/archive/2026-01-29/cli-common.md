# Plan: Split packages/cli/tests/common.bats

## Overview

Split the 1053-line `common.bats` test file into focused test files organized by function category. Extract shared helpers to a dedicated helper file. This maintains all test coverage while improving maintainability and keeping each file under 500 lines.

## Project Structure

```
packages/cli/tests/
├── common.bats           # Utility functions (~320 lines)
├── common-project.bats   # Project discovery (~110 lines) [NEW]
├── common-config.bats    # Configuration loading (~485 lines) [NEW]
├── common-git.bats       # Git operations (~130 lines) [NEW]
└── helpers.bash          # Shared test helpers (~30 lines) [NEW]
```

### Test File Organization

| File | Functions Tested | Tests | Lines |
|------|-----------------|-------|-------|
| `common.bats` | v0_issue_pattern, v0_expand_branch, v0_log, v0_check_deps, v0_ensure_state_dir, v0_ensure_build_dir, V0_INSTALL_DIR, v0_session_name, v0_clean_log_file, v0_resolve_to_wok_id | 30 | ~320 |
| `common-project.bats` | v0_find_project_root, v0_find_main_repo | 9 | ~110 |
| `common-config.bats` | v0_load_config, v0_init_config | 28 | ~485 |
| `common-git.bats` | v0_git_worktree_clean, v0_verify_push, v0_diagnose_push_verification | 11 | ~130 |

## Dependencies

- No new external dependencies
- Uses existing bats-support/bats-assert libraries
- Uses existing test-support helpers

## Implementation Phases

### Phase 1: Create shared helpers file

Create `packages/cli/tests/helpers.bash` containing the three helper functions currently at the top of `common.bats`:

```bash
#!/usr/bin/env bash
# Shared helpers for cli/tests/*.bats

# Helper: Initialize a git repo with a remote origin
init_git_repo_with_remote() {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1
    git clone --bare . "${TEST_TEMP_DIR}/origin.git" 2>/dev/null
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"
    git push -u origin "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null
}

# Helper: Set up project with v0.rc, cd, source lib, and load config
setup_v0_project() {
    create_v0rc "${1:-project}" "${2:-prj}"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config
}

# Helper: Set up git repo, cd, and source lib
setup_git_repo() {
    init_mock_git_repo "${1:-${TEST_TEMP_DIR}/project}"
    cd "${1:-${TEST_TEMP_DIR}/project}" || return 1
    source_lib "v0-common.sh"
}
```

**Verification:** Run `scripts/test cli` - existing tests should still pass.

### Phase 2: Create common-project.bats

Create `packages/cli/tests/common-project.bats` with tests for:
- `v0_find_project_root()` (5 tests, lines 35-83)
- `v0_find_main_repo()` (4 tests, lines 89-135)

File structure:
```bash
#!/usr/bin/env bats
# Tests for project discovery functions

load '../../test-support/helpers/test_helper'
load 'helpers'

# ... tests for v0_find_project_root (5 tests) ...
# ... tests for v0_find_main_repo (4 tests) ...
```

**Verification:** Run `scripts/test common-project` - all 9 tests pass.

### Phase 3: Create common-config.bats

Create `packages/cli/tests/common-config.bats` with tests for:
- `v0_load_config()` (14 tests, lines 141-341)
- `v0_init_config()` (14 tests, lines 572-840)

File structure:
```bash
#!/usr/bin/env bats
# Tests for v0 configuration loading and initialization

load '../../test-support/helpers/test_helper'
load 'helpers'

# ... tests for v0_load_config (14 tests) ...
# ... tests for v0_init_config (14 tests) ...
```

**Verification:** Run `scripts/test common-config` - all 28 tests pass.

### Phase 4: Create common-git.bats

Create `packages/cli/tests/common-git.bats` with tests for:
- `v0_git_worktree_clean()` (5 tests, lines 846-881)
- `v0_verify_push()` (4 tests, lines 887-930)
- `v0_diagnose_push_verification()` (2 tests, lines 936-963)

File structure:
```bash
#!/usr/bin/env bats
# Tests for git-related utility functions

load '../../test-support/helpers/test_helper'
load 'helpers'

# ... tests for v0_git_worktree_clean (5 tests) ...
# ... tests for v0_verify_push (4 tests) ...
# ... tests for v0_diagnose_push_verification (2 tests) ...
```

**Verification:** Run `scripts/test common-git` - all 11 tests pass.

### Phase 5: Update common.bats

Remove extracted tests and helpers from `common.bats`, keeping only:
- `v0_issue_pattern()` (3 tests)
- `v0_expand_branch()` (4 tests)
- `v0_log()` (4 tests)
- `v0_check_deps()` (3 tests)
- `v0_ensure_state_dir()` (1 test)
- `v0_ensure_build_dir()` (1 test)
- `V0_INSTALL_DIR` (1 test)
- `v0_session_name()` (4 tests)
- `v0_clean_log_file()` (3 tests)
- `v0_resolve_to_wok_id()` (6 tests)

Update header to load shared helpers:
```bash
#!/usr/bin/env bats
# Tests for v0-common.sh - Utility functions

load '../../test-support/helpers/test_helper'
load 'helpers'
```

**Verification:**
- Run `wc -l packages/cli/tests/common.bats` - should be under 1000 lines (~320)
- Run `scripts/test common` - all 30 remaining tests pass

### Phase 6: Final verification

Run complete test suite to ensure no regressions:
```bash
scripts/test cli                    # All cli package tests
make check                          # Full lint + test suite
```

## Key Implementation Details

### Helper loading pattern

BATS loads helpers relative to the test file. Use:
```bash
load '../../test-support/helpers/test_helper'  # Shared test infrastructure
load 'helpers'                                   # CLI-specific helpers (no extension)
```

### Test isolation

Each split file is self-contained:
- Loads both helper files
- Each test sets up its own state
- No dependencies between test files

### Maintaining test coverage

All 78 tests are preserved:
- 9 tests → `common-project.bats`
- 28 tests → `common-config.bats`
- 11 tests → `common-git.bats`
- 30 tests → `common.bats`

## Verification Plan

1. **Phase verification**: After each phase, run `scripts/test <target>` for the specific file
2. **Integration**: Run `scripts/test cli` to verify all CLI tests pass together
3. **Line count**: Run `wc -l packages/cli/tests/common.bats` - must be under 1000
4. **Full suite**: Run `make check` to verify lint + all tests pass
5. **Test count**: Verify total test count matches original (78 tests)
   ```bash
   grep -c "^@test" packages/cli/tests/common*.bats | awk -F: '{sum+=$2} END {print sum}'
   # Should output: 78
   ```
