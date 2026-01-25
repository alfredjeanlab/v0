# Implementation Plan: Status Ahead/Behind Display

## Overview

Add a one-liner at the top of `v0 status` output showing how many commits the current branch is ahead/behind `V0_DEVELOP_BRANCH`, with colored indicators and suggestions for `v0 pull` or `v0 push`.

**Note**: The core implementation already exists in `packages/status/lib/branch-status.sh`. This plan focuses on verification and testing.

## Project Structure

```
packages/status/
  lib/
    branch-status.sh      # [EXISTS] Core implementation
  tests/
    branch-status.bats    # [NEW] Unit tests

bin/
  v0-status               # [EXISTS] Already calls show_branch_status()
```

## Dependencies

- Git (for `rev-list --left-right --count`)
- Core package (for colors: `C_GREEN`, `C_RED`, `C_DIM`, `C_RESET`)
- TTY detection (`[[ -t 1 ]]`)

## Implementation Phases

### Phase 1: Verify Existing Implementation

**Status**: Complete

The `show_branch_status()` function in `packages/status/lib/branch-status.sh` already implements:

1. Gets current branch via `git rev-parse --abbrev-ref HEAD`
2. Fetches remote develop branch (quiet, non-blocking on error)
3. Calculates ahead/behind via `git rev-list --left-right --count`
4. Displays:
   - `⇡N` in green for commits ahead
   - `⇣N` in red for commits behind
   - `(v0 pull)` suggestion if any behind
   - `(v0 push)` suggestion if strictly ahead
5. Returns 1 if in sync (nothing to display) or on develop branch itself

**Integration point** (`bin/v0-status` lines 227-229):
```bash
# Show branch ahead/behind status at the top
show_branch_status || true
echo ""
```

### Phase 2: Add Unit Tests

**Status**: Not started

Create `packages/status/tests/branch-status.bats` with tests for:

1. **Basic ahead display** - Shows `⇡N` when current branch has commits not on remote
2. **Basic behind display** - Shows `⇣N` when remote has commits not on current branch
3. **Combined ahead/behind** - Shows both `⇡N ⇣M` when diverged
4. **In sync** - Returns 1, no output when branches match
5. **On develop branch** - Returns 1, skips display
6. **Pull suggestion** - Shows `(v0 pull)` when behind
7. **Push suggestion** - Shows `(v0 push)` when strictly ahead
8. **Non-TTY output** - No ANSI color codes when not a terminal

### Phase 3: Integration Verification

**Status**: Not started

Verify end-to-end behavior:
1. Run `v0 status` on a branch with divergence
2. Confirm one-liner appears at top before "Operations:" header
3. Verify colors display correctly in terminal
4. Verify clean output without colors when piped

## Key Implementation Details

### Git Command for Divergence

```bash
git rev-list --left-right --count "origin/develop...HEAD"
# Output: behind<tab>ahead
# Left side = commits in remote/develop not in HEAD (behind)
# Right side = commits in HEAD not in remote/develop (ahead)
```

### Color Handling

```bash
# TTY detection
[[ -t 1 ]] && is_tty=1

# Color application
if [[ -n "${is_tty}" ]]; then
    display="${C_GREEN}⇡${ahead}${C_RESET}"
else
    display="⇡${ahead}"
fi
```

### Output Format

```
# TTY (with colors):
main ⇡5 ⇣2 (v0 pull)

# Non-TTY (no colors):
main ⇡5 ⇣2 (v0 pull)

# Strictly ahead:
feature/foo ⇡3 (v0 push)

# Only behind:
feature/bar ⇣1 (v0 pull)
```

## Verification Plan

### Unit Tests (`packages/status/tests/branch-status.bats`)

```bash
#!/usr/bin/env bats

load '../../test-support/helpers/test_helper'

setup() {
    setup_test_environment
    source_lib "branch-status.sh"

    # Create mock git repo
    export TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
    git commit --allow-empty -m "initial"
}

teardown() {
    rm -rf "$TEST_REPO"
}

@test "show_branch_status shows ahead count with green arrow" {
    # Mock git to return ahead=3, behind=0
    git() {
        case "$1" in
            rev-parse) echo "feature-branch" ;;
            fetch) return 0 ;;
            rev-list) echo "0	3" ;;  # behind<tab>ahead
        esac
    }
    export -f git
    export V0_DEVELOP_BRANCH="develop"

    run show_branch_status

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"⇡3"* ]]
    [[ "$output" == *"(v0 push)"* ]]
}

@test "show_branch_status shows behind count with red arrow" {
    git() {
        case "$1" in
            rev-parse) echo "feature-branch" ;;
            fetch) return 0 ;;
            rev-list) echo "2	0" ;;  # behind<tab>ahead
        esac
    }
    export -f git
    export V0_DEVELOP_BRANCH="develop"

    run show_branch_status

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"⇣2"* ]]
    [[ "$output" == *"(v0 pull)"* ]]
}

@test "show_branch_status returns 1 when in sync" {
    git() {
        case "$1" in
            rev-parse) echo "feature-branch" ;;
            fetch) return 0 ;;
            rev-list) echo "0	0" ;;
        esac
    }
    export -f git
    export V0_DEVELOP_BRANCH="develop"

    run show_branch_status

    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
}

@test "show_branch_status skips when on develop branch" {
    git() {
        case "$1" in
            rev-parse) echo "develop" ;;
        esac
    }
    export -f git
    export V0_DEVELOP_BRANCH="develop"

    run show_branch_status

    [[ "$status" -eq 1 ]]
}
```

### Manual Verification

```bash
# 1. Create divergent state
git checkout -b test-branch
git commit --allow-empty -m "local commit"
# (assume origin/develop has other commits)

# 2. Run status
v0 status

# 3. Expected output (first line):
# test-branch ⇡1 ⇣2 (v0 pull)
#
# Operations:
# ...

# 4. Verify non-TTY output
v0 status | cat  # Should have no ANSI codes
```

### Test Commands

```bash
# Run unit tests
scripts/test status

# Run all checks
make check
```
