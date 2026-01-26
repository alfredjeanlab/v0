#!/usr/bin/env bats
# Tests for v0-archive - Move stale archived plans to icebox worktree

load '../packages/test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env

    # Force worktree mode so the v0/plans branch is created in V0_ROOT
    # (clone mode would create it in a workspace clone, invisible from V0_ROOT)
    export V0_WORKSPACE_MODE="worktree"

    # Initialize git repo in-place (don't use cached fixture which removes cwd)
    git init --quiet -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"

    # Set PLANS_DIR (v0_load_config sets this but setup_v0_env doesn't)
    export PLANS_DIR="${V0_ROOT}/plans"
    export V0_PLANS_DIR="plans"
    mkdir -p "${PLANS_DIR}"
}

# ============================================================================
# Help and Usage tests
# ============================================================================

@test "archive --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0-archive" --help
    assert_failure  # usage exits 1
    [[ "${output}" == *"v0 archive"* ]]
    [[ "${output}" == *"icebox"* ]]
}

@test "archive -h shows usage" {
    run "${PROJECT_ROOT}/bin/v0-archive" -h
    assert_failure
    [[ "${output}" == *"v0 archive"* ]]
}

@test "archive unknown option shows usage" {
    run "${PROJECT_ROOT}/bin/v0-archive" --unknown
    assert_failure
    [[ "${output}" == *"Unknown option"* ]]
}

@test "archive unexpected argument shows usage" {
    run "${PROJECT_ROOT}/bin/v0-archive" somearg
    assert_failure
    [[ "${output}" == *"Unexpected argument"* ]]
}

# ============================================================================
# Empty archive tests
# ============================================================================

@test "archive reports no plans when archive empty" {
    run "${PROJECT_ROOT}/bin/v0-archive"
    assert_success
    [[ "${output}" == *"No archived plans"* ]]
}

@test "archive reports no plans when archive directory missing" {
    # PLANS_DIR exists but no archive subdirectory
    run "${PROJECT_ROOT}/bin/v0-archive"
    assert_success
    [[ "${output}" == *"No archived plans"* ]]
}

# ============================================================================
# Dry-run tests
# ============================================================================

@test "archive --dry-run shows preview without moving" {
    # Create old archived plan (use a date far in the past)
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run
    assert_success
    [[ "${output}" == *"Would archive"* ]]
    [[ "${output}" == *"old-plan.md"* ]]

    # Plan should still exist
    [ -f "${PLANS_DIR}/archive/2020-01-01/old-plan.md" ]
}

@test "archive -n is alias for --dry-run" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" -n
    assert_success
    [[ "${output}" == *"Would archive"* ]]

    # Plan should still exist
    [ -f "${PLANS_DIR}/archive/2020-01-01/old-plan.md" ]
}

# ============================================================================
# Age filtering tests
# ============================================================================

@test "archive --days filters by age" {
    # Create old plan (over 30 days ago)
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old" > "${PLANS_DIR}/archive/2020-01-01/old.md"

    # Create recent plan (today)
    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "${PLANS_DIR}/archive/${today}"
    echo "# New" > "${PLANS_DIR}/archive/${today}/new.md"

    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add plans"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run --days 30
    assert_success
    [[ "${output}" == *"old.md"* ]]
    [[ "${output}" != *"new.md"* ]]
}

@test "archive default days is 7" {
    # Create plan from 10 days ago (should be archived)
    local old_date
    old_date=$(date -v-10d +%Y-%m-%d 2>/dev/null || date -d "10 days ago" +%Y-%m-%d)
    mkdir -p "${PLANS_DIR}/archive/${old_date}"
    echo "# Old" > "${PLANS_DIR}/archive/${old_date}/old.md"

    # Create plan from 5 days ago (should be skipped)
    local new_date
    new_date=$(date -v-5d +%Y-%m-%d 2>/dev/null || date -d "5 days ago" +%Y-%m-%d)
    mkdir -p "${PLANS_DIR}/archive/${new_date}"
    echo "# New" > "${PLANS_DIR}/archive/${new_date}/new.md"

    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add plans"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run
    assert_success
    [[ "${output}" == *"old.md"* ]]
    [[ "${output}" != *"new.md"* ]]
}

@test "archive --all ignores age filter" {
    # Create a plan from today
    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "${PLANS_DIR}/archive/${today}"
    echo "# Today" > "${PLANS_DIR}/archive/${today}/today.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --dry-run --all
    assert_success
    [[ "${output}" == *"today.md"* ]]
}

@test "archive -a is alias for --all" {
    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "${PLANS_DIR}/archive/${today}"
    echo "# Today" > "${PLANS_DIR}/archive/${today}/today.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add plan"

    run "${PROJECT_ROOT}/bin/v0-archive" -n -a
    assert_success
    [[ "${output}" == *"today.md"* ]]
}

# ============================================================================
# Archiving tests (with --force to skip confirmation)
# ============================================================================

@test "archive moves old plans to icebox" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --force
    assert_success
    [[ "${output}" == *"Archived"* ]]

    # Plan should be removed from main repo
    [ ! -f "${PLANS_DIR}/archive/2020-01-01/old-plan.md" ]

    # v0/plans branch should exist
    run git -C "${V0_ROOT}" branch --list "v0/plans"
    [[ -n "${output}" ]]
}

@test "archive -f is alias for --force" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" -f
    assert_success
    [[ "${output}" == *"Archived"* ]]
}

@test "archive cleans up empty date directories" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    run "${PROJECT_ROOT}/bin/v0-archive" --force
    assert_success

    # Empty date directory should be removed
    [ ! -d "${PLANS_DIR}/archive/2020-01-01" ]
}

@test "archive preserves non-date directories in archive" {
    # Create a non-date directory that should be ignored
    mkdir -p "${PLANS_DIR}/archive/templates"
    echo "# Template" > "${PLANS_DIR}/archive/templates/template.md"

    # Create an old dated plan
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"

    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add plans"

    run "${PROJECT_ROOT}/bin/v0-archive" --force
    assert_success

    # Template should still exist
    [ -f "${PLANS_DIR}/archive/templates/template.md" ]
}

@test "archive shows count of archived plans" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Plan 1" > "${PLANS_DIR}/archive/2020-01-01/plan1.md"
    echo "# Plan 2" > "${PLANS_DIR}/archive/2020-01-01/plan2.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add plans"

    run "${PROJECT_ROOT}/bin/v0-archive" --force
    assert_success
    [[ "${output}" == *"Archived 2 plan(s)"* ]]
}

# ============================================================================
# Confirmation tests
# ============================================================================

@test "archive prompts for confirmation without --force" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    # Simulate 'n' answer to confirmation
    run bash -c "echo 'n' | ${PROJECT_ROOT}/bin/v0-archive"
    assert_failure
    [[ "${output}" == *"Aborted"* ]]

    # Plan should still exist
    [ -f "${PLANS_DIR}/archive/2020-01-01/old-plan.md" ]
}

@test "archive shows plans before confirmation prompt" {
    mkdir -p "${PLANS_DIR}/archive/2020-01-01"
    echo "# Old Plan" > "${PLANS_DIR}/archive/2020-01-01/old-plan.md"
    git -C "${V0_ROOT}" add -A && git -C "${V0_ROOT}" commit -m "Add old plan"

    run bash -c "echo 'n' | ${PROJECT_ROOT}/bin/v0-archive"
    [[ "${output}" == *"Found"* ]]
    [[ "${output}" == *"old-plan.md"* ]]
    [[ "${output}" == *"Move to icebox"* ]]
}
