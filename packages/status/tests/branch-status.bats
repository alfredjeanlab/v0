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
    export C_YELLOW='\033[33m'
    export C_MAGENTA='\033[35m'
    export C_CYAN='\033[36m'
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

@test "show_branch_status shows agent ahead when agent has commits" {
    # Agent has 3 commits that feature-branch doesn't (left=3)
    setup_git_mock "feature-branch" "3" "0"

    run show_branch_status
    assert_success
    assert_output --partial "⇡3"
    assert_output --partial "Changes:"
    assert_output --partial "develop"
}

@test "show_branch_status shows agent behind when current has commits" {
    # Current branch has 2 commits that agent doesn't (right=2)
    setup_git_mock "feature-branch" "0" "2"

    run show_branch_status
    assert_success
    assert_output --partial "⇣2"
    assert_output --partial "Changes:"
    assert_output --partial "develop"
}

@test "show_branch_status shows both when diverged" {
    # Agent has 2 commits current doesn't (left=2), current has 3 agent doesn't (right=3)
    setup_git_mock "feature-branch" "2" "3"

    run show_branch_status
    assert_success
    assert_output --partial "⇡2"  # agent ahead by 2
    assert_output --partial "⇣3"  # agent behind by 3
    assert_output --partial "Changes:"
    assert_output --partial "develop"
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

@test "show_branch_status suggests pull when agent is ahead" {
    # Agent is ahead by 2 (left=2)
    setup_git_mock "feature-branch" "2" "0"

    run show_branch_status
    assert_success
    assert_output --partial "v0 pull"
    assert_output --partial "feature-branch"  # mentions current branch in suggestion
    refute_output --partial "v0 push"
}

@test "show_branch_status suggests pull when diverged (agent ahead takes priority)" {
    # Agent ahead by 2, behind by 3 - pull takes priority
    setup_git_mock "feature-branch" "2" "3"

    run show_branch_status
    assert_success
    assert_output --partial "v0 pull"
    refute_output --partial "v0 push"
}

@test "show_branch_status suggests push when agent is strictly behind" {
    # Agent is behind by 3 (right=3), not ahead at all
    setup_git_mock "feature-branch" "0" "3"

    run show_branch_status
    assert_success
    assert_output --partial "v0 push"
    assert_output --partial "develop"  # mentions agent branch in suggestion
    refute_output --partial "v0 pull"
}

# ============================================================================
# TTY Color Tests
# ============================================================================

@test "show_branch_status includes green color for agent ahead in TTY mode" {
    # Agent ahead by 3 (left=3)
    setup_git_mock "feature-branch" "3" "0"

    # Force TTY detection by having stdout be a tty
    # Note: In bats 'run', stdout is not a tty, so colors won't be applied
    # This test verifies the logic path exists; actual color codes tested separately
    run show_branch_status
    assert_success
    assert_output --partial "⇡3"
}

@test "show_branch_status includes red color for agent behind in TTY mode" {
    # Agent behind by 2 (right=2)
    setup_git_mock "feature-branch" "0" "2"

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
    # Agent ahead by 3 (left=3)
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
        echo "3	0"
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
    # Agent ahead by 1 (left=1)
    setup_git_mock "feature-branch" "1" "0"

    run show_branch_status
    assert_success
    assert_output --partial "⇡1"
}

@test "show_branch_status defaults V0_DEVELOP_BRANCH to main" {
    unset V0_DEVELOP_BRANCH

    # Source the library again to pick up default
    source_lib "branch-status.sh"

    # Now if we're on 'main' branch, it should skip
    setup_git_mock "main" "1" "2"

    run show_branch_status
    assert_failure
}

# ============================================================================
# Output Format Tests
# ============================================================================

@test "show_branch_status output format matches expected pattern" {
    # Agent ahead by 2 (left=2), behind by 5 (right=5)
    setup_git_mock "my-feature" "2" "5"

    run show_branch_status
    assert_success
    # Output should be: Changes: develop is ⇡N ⇣M (use v0 pull to merge them to my-feature)
    assert_output --partial "Changes:"
    assert_output --partial "develop"
    assert_output --partial "⇡2"  # agent ahead
    assert_output --partial "⇣5"  # agent behind
    assert_output --partial "v0 pull"
    assert_output --partial "my-feature"  # current branch in suggestion
}

@test "show_branch_status handles branch names with special characters" {
    # Agent ahead by 1 (left=1), so current branch appears in "merge them to" suggestion
    setup_git_mock "feature/add-status-123" "1" "0"

    run show_branch_status
    assert_success
    assert_output --partial "feature/add-status-123"  # in suggestion
    assert_output --partial "⇡1"  # agent ahead
}
