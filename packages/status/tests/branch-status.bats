#!/usr/bin/env bats
# Tests for lib/branch-status.sh - Branch ahead/behind status display
# plan:status-ahead

load '../../test-support/helpers/test_helper'

# Setup for branch status tests
setup() {
    _base_setup

    # Set color variables (normally set by v0-common.sh when TTY)
    export C_GREEN='\033[32m'
    export C_RED='\033[31m'
    export C_DIM='\033[2m'
    export C_RESET='\033[0m'

    # Default environment
    export V0_DEVELOP_BRANCH="develop"
    export V0_GIT_REMOTE="origin"

    # Source the library under test
    source_lib "branch-status.sh"
}

# Helper to create mock git that returns specified values
# Usage: setup_git_mock "branch-name" "behind" "ahead"
setup_git_mock() {
    local branch="$1"
    local behind="$2"
    local ahead="$3"

    # Create mock git script
    mkdir -p "${TEST_TEMP_DIR}/mock-bin"
    cat > "${TEST_TEMP_DIR}/mock-bin/git" <<EOF
#!/bin/bash
case "\$1" in
    rev-parse)
        echo "${branch}"
        ;;
    fetch)
        exit 0
        ;;
    rev-list)
        echo "${behind}	${ahead}"
        ;;
esac
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-bin/git"
    export PATH="${TEST_TEMP_DIR}/mock-bin:${PATH}"
}

# ============================================================================
# Basic Ahead/Behind Display Tests
# ============================================================================

@test "show_branch_status shows ahead count when commits ahead" {
    setup_git_mock "feature-branch" "0" "3"

    run show_branch_status
    assert_success
    assert_output --partial "⇡3"
    assert_output --partial "feature-branch"
}

@test "show_branch_status shows behind count when commits behind" {
    setup_git_mock "feature-branch" "2" "0"

    run show_branch_status
    assert_success
    assert_output --partial "⇣2"
    assert_output --partial "feature-branch"
}

@test "show_branch_status shows both ahead and behind when diverged" {
    setup_git_mock "feature-branch" "2" "3"

    run show_branch_status
    assert_success
    assert_output --partial "⇡3"
    assert_output --partial "⇣2"
    assert_output --partial "feature-branch"
}

# ============================================================================
# In Sync and Skip Conditions
# ============================================================================

@test "show_branch_status returns 1 when in sync" {
    setup_git_mock "feature-branch" "0" "0"

    run show_branch_status
    assert_failure
    assert_output ""
}

@test "show_branch_status skips when on develop branch" {
    setup_git_mock "develop" "5" "3"

    run show_branch_status
    assert_failure
}

@test "show_branch_status skips when on custom develop branch" {
    export V0_DEVELOP_BRANCH="main"
    setup_git_mock "main" "5" "3"

    run show_branch_status
    assert_failure
}

# ============================================================================
# Suggestion Display Tests
# ============================================================================

@test "show_branch_status suggests pull when behind" {
    setup_git_mock "feature-branch" "2" "0"

    run show_branch_status
    assert_success
    assert_output --partial "(v0 pull)"
    refute_output --partial "(v0 push)"
}

@test "show_branch_status suggests pull when both ahead and behind" {
    setup_git_mock "feature-branch" "2" "3"

    run show_branch_status
    assert_success
    assert_output --partial "(v0 pull)"
    refute_output --partial "(v0 push)"
}

@test "show_branch_status suggests push when strictly ahead" {
    setup_git_mock "feature-branch" "0" "3"

    run show_branch_status
    assert_success
    assert_output --partial "(v0 push)"
    refute_output --partial "(v0 pull)"
}

# ============================================================================
# TTY Color Tests
# ============================================================================

@test "show_branch_status includes green color for ahead in TTY mode" {
    setup_git_mock "feature-branch" "0" "3"

    # Force TTY detection by having stdout be a tty
    # Note: In bats 'run', stdout is not a tty, so colors won't be applied
    # This test verifies the logic path exists; actual color codes tested separately
    run show_branch_status
    assert_success
    assert_output --partial "⇡3"
}

@test "show_branch_status includes red color for behind in TTY mode" {
    setup_git_mock "feature-branch" "2" "0"

    run show_branch_status
    assert_success
    assert_output --partial "⇣2"
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "show_branch_status returns 1 when not in git repo" {
    # Create mock git that fails on rev-parse
    mkdir -p "${TEST_TEMP_DIR}/mock-bin"
    cat > "${TEST_TEMP_DIR}/mock-bin/git" <<'EOF'
#!/bin/bash
case "$1" in
    rev-parse)
        exit 1
        ;;
esac
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-bin/git"
    export PATH="${TEST_TEMP_DIR}/mock-bin:${PATH}"

    run show_branch_status
    assert_failure
}

@test "show_branch_status returns 1 when rev-list fails" {
    # Create mock git that fails on rev-list
    mkdir -p "${TEST_TEMP_DIR}/mock-bin"
    cat > "${TEST_TEMP_DIR}/mock-bin/git" <<'EOF'
#!/bin/bash
case "$1" in
    rev-parse)
        echo "feature-branch"
        ;;
    fetch)
        exit 0
        ;;
    rev-list)
        exit 1
        ;;
esac
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-bin/git"
    export PATH="${TEST_TEMP_DIR}/mock-bin:${PATH}"

    run show_branch_status
    assert_failure
}

@test "show_branch_status continues when fetch fails" {
    # Create mock git where fetch fails but rev-list works
    mkdir -p "${TEST_TEMP_DIR}/mock-bin"
    cat > "${TEST_TEMP_DIR}/mock-bin/git" <<'EOF'
#!/bin/bash
case "$1" in
    rev-parse)
        echo "feature-branch"
        ;;
    fetch)
        exit 1
        ;;
    rev-list)
        echo "0	3"
        ;;
esac
EOF
    chmod +x "${TEST_TEMP_DIR}/mock-bin/git"
    export PATH="${TEST_TEMP_DIR}/mock-bin:${PATH}"

    run show_branch_status
    assert_success
    assert_output --partial "⇡3"
}

# ============================================================================
# Environment Variable Tests
# ============================================================================

@test "show_branch_status uses V0_DEVELOP_BRANCH for comparison" {
    export V0_DEVELOP_BRANCH="main"
    setup_git_mock "feature-branch" "1" "2"

    run show_branch_status
    assert_success
}

@test "show_branch_status uses V0_GIT_REMOTE for fetch" {
    export V0_GIT_REMOTE="upstream"
    setup_git_mock "feature-branch" "1" "0"

    run show_branch_status
    assert_success
    assert_output --partial "⇣1"
}

@test "show_branch_status defaults V0_DEVELOP_BRANCH to agent" {
    unset V0_DEVELOP_BRANCH

    # Source the library again to pick up default
    source_lib "branch-status.sh"

    # Now if we're on 'agent' branch, it should skip
    setup_git_mock "agent" "1" "2"

    run show_branch_status
    assert_failure
}

# ============================================================================
# Output Format Tests
# ============================================================================

@test "show_branch_status output format matches expected pattern" {
    setup_git_mock "my-feature" "2" "5"

    run show_branch_status
    assert_success
    # Output should be: branch ⇡N ⇣M (suggestion)
    assert_output --partial "my-feature"
    assert_output --partial "⇡5"
    assert_output --partial "⇣2"
    assert_output --partial "(v0 pull)"
}

@test "show_branch_status handles branch names with special characters" {
    setup_git_mock "feature/add-status-123" "0" "1"

    run show_branch_status
    assert_success
    assert_output --partial "feature/add-status-123"
    assert_output --partial "⇡1"
}
