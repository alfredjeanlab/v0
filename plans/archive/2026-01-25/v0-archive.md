# Implementation Plan: v0-archive

## Overview

Implement a `v0 archive` command that moves stale archived plans from `plans/archive/` to a dedicated `v0/plans` worktree (the "icebox"). This keeps the main repository clean while preserving plan history in a separate branch.

The command identifies plans in `plans/archive/<date>/` that are older than a configurable threshold (default: 30 days) and moves them to a `v0/plans` branch managed via git worktree.

## Project Structure

```
bin/
  v0-archive           # Main command - archives stale plans to worktree
packages/
  cli/lib/
    archive.sh         # Archive utilities (icebox logic)
tests/
  v0-archive.bats      # Integration tests
```

## Dependencies

- `git worktree` (already used by v0-tree)
- `jq` (already a v0 dependency)
- No new external dependencies

## Implementation Phases

### Phase 1: Create `bin/v0-archive` Command Structure

**Goal:** Scaffold the command with help, argument parsing, and configuration.

**File:** `bin/v0-archive`

```bash
#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
set -e

V0_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${V0_DIR}/packages/cli/lib/v0-common.sh"
v0_load_config

usage() {
  cat <<EOF
v0 archive - Move stale archived plans to icebox worktree

Usage: v0 archive [options]

Options:
  -n, --dry-run    Show what would be archived without moving
  -d, --days N     Archive plans older than N days (default: 30)
  -a, --all        Archive all plans in archive/ (ignores age)
  -f, --force      Skip confirmation prompts
  -h, --help       Show this help message

The icebox is a separate 'v0/plans' branch managed via git worktree.
Archived plans are moved there and committed, keeping the main repo clean.

Examples:
  v0 archive                # Archive plans older than 30 days
  v0 archive --days 7       # Archive plans older than 7 days
  v0 archive --all          # Archive all plans
  v0 archive --dry-run      # Preview what would be archived
EOF
  exit 1
}

# Default configuration
DAYS=30
DRY_RUN=""
ALL=""
FORCE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -d|--days) DAYS="$2"; shift 2 ;;
    -a|--all) ALL=1; shift ;;
    -f|--force) FORCE=1; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) echo "Unexpected argument: $1" >&2; usage ;;
  esac
done
```

### Phase 2: Implement Icebox Worktree Setup

**Goal:** Create or locate the `v0/plans` worktree using existing `v0-tree` infrastructure.

**Key pattern:** Reuse `v0-tree` to manage worktree, with branch name `v0/plans`.

```bash
# Setup icebox worktree
# Returns: icebox worktree path
setup_icebox_worktree() {
  local tree_output

  # Use v0-tree to create/find the worktree
  # Branch: v0/plans, tree name: v0-plans-icebox
  if ! tree_output=$("${V0_DIR}/bin/v0-tree" "v0-plans-icebox" --branch "v0/plans" 2>&1); then
    echo "Error: Failed to setup icebox worktree" >&2
    echo "${tree_output}" >&2
    return 1
  fi

  # v0-tree outputs two lines: TREE_DIR, then WORKTREE
  local icebox_worktree
  icebox_worktree=$(echo "${tree_output}" | tail -1)

  # Ensure plans directory exists in icebox
  mkdir -p "${icebox_worktree}/plans"

  echo "${icebox_worktree}"
}
```

### Phase 3: Implement Plan Discovery and Age Filtering

**Goal:** Find archived plans and filter by age.

```bash
# Find archived plans older than N days
# Args: $1 = days threshold
# Output: List of plan paths (relative to PLANS_DIR)
find_stale_plans() {
  local days="$1"
  local cutoff_date

  # Calculate cutoff date
  cutoff_date=$(date -v-"${days}"d +%Y-%m-%d 2>/dev/null || \
                date -d "${days} days ago" +%Y-%m-%d 2>/dev/null)

  local archive_dir="${PLANS_DIR}/archive"
  [[ -d "${archive_dir}" ]] || return 0

  # Find date directories older than cutoff
  for date_dir in "${archive_dir}"/*/; do
    [[ -d "${date_dir}" ]] || continue

    local dir_date
    dir_date=$(basename "${date_dir}")

    # Skip if not a valid date directory
    [[ "${dir_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue

    # Compare dates (lexicographic works for YYYY-MM-DD)
    if [[ "${dir_date}" < "${cutoff_date}" ]] || [[ -n "${ALL}" ]]; then
      # List plans in this directory
      for plan in "${date_dir}"*.md; do
        [[ -f "${plan}" ]] || continue
        # Output relative path from PLANS_DIR
        echo "${plan#${PLANS_DIR}/}"
      done
    fi
  done
}

# Find all archived plans (for --all flag)
find_all_archived_plans() {
  local archive_dir="${PLANS_DIR}/archive"
  [[ -d "${archive_dir}" ]] || return 0

  find "${archive_dir}" -name "*.md" -type f | while read -r plan; do
    echo "${plan#${PLANS_DIR}/}"
  done
}
```

### Phase 4: Implement Plan Migration to Icebox

**Goal:** Move plans from archive to icebox worktree and commit.

```bash
# Move plans to icebox worktree
# Args: $1 = icebox worktree path, $@ = list of plan relative paths
archive_to_icebox() {
  local icebox="$1"
  shift
  local plans=("$@")

  if [[ ${#plans[@]} -eq 0 ]]; then
    echo "No plans to archive"
    return 0
  fi

  local archived=0

  for plan_rel in "${plans[@]}"; do
    local src="${PLANS_DIR}/${plan_rel}"
    local dest="${icebox}/plans/${plan_rel}"

    # Create destination directory structure
    mkdir -p "$(dirname "${dest}")"

    if [[ -n "${DRY_RUN}" ]]; then
      echo "Would archive: ${plan_rel}"
    else
      mv "${src}" "${dest}"
      echo "Archived: ${plan_rel}"
      archived=$((archived + 1))
    fi
  done

  if [[ -z "${DRY_RUN}" ]] && [[ ${archived} -gt 0 ]]; then
    # Commit in icebox worktree
    (
      cd "${icebox}"
      git add -A plans/
      git commit -m "Archive ${archived} plan(s) to icebox" \
        -m "Moved from main repo archive/ by v0 archive"
    ) || echo "Warning: Failed to commit in icebox worktree"

    # Clean up empty directories in main repo
    cleanup_empty_archive_dirs

    # Commit removal in main repo
    (
      cd "${V0_ROOT}"
      git add -A "${V0_PLANS_DIR}/archive/"
      git commit -m "Move ${archived} archived plan(s) to icebox" \
        -m "Plans moved to v0/plans branch by v0 archive"
    ) || echo "Warning: Failed to commit archive cleanup"
  fi

  if [[ -z "${DRY_RUN}" ]]; then
    echo ""
    echo "Archived ${archived} plan(s) to icebox"
    echo "Icebox branch: v0/plans"
    echo "Icebox worktree: ${icebox}"
  fi
}

# Remove empty date directories from archive
cleanup_empty_archive_dirs() {
  local archive_dir="${PLANS_DIR}/archive"
  [[ -d "${archive_dir}" ]] || return 0

  find "${archive_dir}" -type d -empty -delete 2>/dev/null || true
}
```

### Phase 5: Wire Up Main Logic and Add Tests

**Goal:** Complete main dispatch and add integration tests.

**Main dispatch:**
```bash
# Main
main() {
  local plans=()

  # Find plans to archive
  if [[ -n "${ALL}" ]]; then
    mapfile -t plans < <(find_all_archived_plans)
  else
    mapfile -t plans < <(find_stale_plans "${DAYS}")
  fi

  if [[ ${#plans[@]} -eq 0 ]]; then
    echo "No archived plans found${ALL:+ in archive/}${ALL:-\ older than ${DAYS} days}"
    exit 0
  fi

  # Confirm unless --force or --dry-run
  if [[ -z "${FORCE}" ]] && [[ -z "${DRY_RUN}" ]]; then
    echo "Found ${#plans[@]} plan(s) to archive:"
    printf '  %s\n' "${plans[@]}"
    echo ""
    printf "Move to icebox? [y/N] "
    read -r confirm
    if [[ "${confirm}" != "y" ]] && [[ "${confirm}" != "Y" ]]; then
      echo "Aborted"
      exit 1
    fi
  fi

  # Setup icebox worktree
  local icebox
  if ! icebox=$(setup_icebox_worktree); then
    exit 1
  fi

  # Archive plans
  archive_to_icebox "${icebox}" "${plans[@]}"
}

main
```

**Test file:** `tests/v0-archive.bats`
```bash
#!/usr/bin/env bats
load '../packages/test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env
    setup_git_repo
}

@test "archive --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0-archive" --help
    assert_failure  # usage exits 1
    [[ "${output}" == *"v0 archive"* ]]
}

@test "archive reports no plans when archive empty" {
    run "${PROJECT_ROOT}/bin/v0-archive"
    assert_success
    [[ "${output}" == *"No archived plans found"* ]]
}

@test "archive --dry-run shows preview" {
    # Create old archived plan
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git add -A && git commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run
    assert_success
    [[ "${output}" == *"Would archive"* ]]
    [[ "${output}" == *"old-plan.md"* ]]

    # Plan should still exist
    [ -f "${PLANS_DIR}/archive/2020-01-01/old-plan.md" ]
}

@test "archive moves old plans to icebox" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git add -A && git commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --force
    assert_success
    [[ "${output}" == *"Archived"* ]]

    # Plan should be removed from main repo
    [ ! -f "${PLANS_DIR}/archive/2020-01-01/old-plan.md" ]

    # v0/plans branch should exist
    run git branch --list "v0/plans"
    [[ -n "${output}" ]]
}

@test "archive --days filters by age" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    mkdir -p "${PLANS_DIR}/archive/$(date +%Y-%m-%d)"
    echo "# Old" > "${PLANS_DIR}/archive/2020-01-01/old.md"
    echo "# New" > "${PLANS_DIR}/archive/$(date +%Y-%m-%d)/new.md"
    git add -A && git commit -m "Add plans"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run --days 30
    assert_success
    [[ "${output}" == *"old.md"* ]]
    [[ "${output}" != *"new.md"* ]]
}

@test "archive --all ignores age filter" {
    mkdir -p "${PLANS_DIR}/archive/$(date +%Y-%m-%d)"
    echo "# Today" > "${PLANS_DIR}/archive/$(date +%Y-%m-%d)/today.md"
    git add -A && git commit -m "Add plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run --all
    assert_success
    [[ "${output}" == *"today.md"* ]]
}
```

### Phase 6: Documentation and Polish

**Goal:** Add help text to main `v0` command and verify integration.

**Update `bin/v0` dispatcher** (if needed):
```bash
archive)  exec "${V0_DIR}/bin/v0-archive" "${@:2}" ;;
```

**Verify complete workflow:**
```bash
# 1. Create a plan
v0 plan test-feature "Build test feature"

# 2. Complete and merge (plan auto-archived)
v0 feature test-feature
# ... work ... merge ...

# 3. Wait or use --all
v0 archive --all --dry-run  # Preview
v0 archive --all            # Move to icebox

# 4. Verify icebox
git log v0/plans --oneline  # See archived plans
```

## Key Implementation Details

### Worktree Branch Strategy

The `v0/plans` branch:
- Created on first `v0 archive` run
- Based off orphan branch (no history from main)
- Only contains archived plans
- Managed via `v0-tree` for consistency

```bash
# v0-tree creates branch from main if it doesn't exist
# For icebox, we may want an orphan branch:
git switch --orphan v0/plans
git commit --allow-empty -m "Initialize v0 plans icebox"
```

Alternative: Create from main but only track `plans/` directory. The simpler approach uses `v0-tree` as-is.

### Directory Structure in Icebox

Mirror the archive structure:
```
v0/plans branch:
  plans/
    archive/
      2024-01-15/
        feature-auth.md
      2024-02-01/
        refactor-api.md
```

### Date Calculation Cross-Platform

macOS and GNU date have different syntax:
```bash
# Try macOS first, fall back to GNU
cutoff=$(date -v-"${days}"d +%Y-%m-%d 2>/dev/null || \
         date -d "${days} days ago" +%Y-%m-%d)
```

### Handling Empty Archive Directories

After moving plans, clean up empty date directories:
```bash
find "${PLANS_DIR}/archive" -type d -empty -delete
```

## Verification Plan

1. **Unit tests in `tests/v0-archive.bats`:**
   - `--help` shows usage
   - `--dry-run` previews without moving
   - Age filtering works correctly
   - `--all` ignores age
   - Plans move to icebox branch
   - Empty directories cleaned up
   - Commits created in both repos

2. **Manual verification:**
   ```bash
   # Create test archive
   mkdir -p plans/archive/2020-01-01
   echo "# Test" > plans/archive/2020-01-01/test.md
   git add -A && git commit -m "Test plan"

   # Dry run
   v0 archive --dry-run

   # Execute
   v0 archive --force

   # Verify
   ls plans/archive/           # Should be empty or gone
   git log v0/plans --oneline  # Should show archive commit
   ```

3. **Run test suite:**
   ```bash
   scripts/test v0-archive
   make check
   ```

4. **Edge cases:**
   - Empty archive directory
   - No plans matching age threshold
   - Worktree already exists
   - Non-date directory names in archive
   - Plans with special characters in names
