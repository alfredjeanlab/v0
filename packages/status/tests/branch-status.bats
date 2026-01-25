#!/usr/bin/env bats
# Tests for lib/branch-status.sh - Branch ahead/behind status display
# plan:status-ahead

load '../../test-support/helpers/test_helper'

# Setup for branch status tests
setup() {
    _base_setup

    # Define color variables (show_branch_status checks TTY itself)
    export C_GREEN='\033[32m'
    export C_RED='\033[31m'
    export C_DIM='\033[2m'
    export C_RESET='\033[0m'

    # Default environment
    export V0_DEVELOP_BRANCH="develop"
    export V0_GIT_REMOTE="origin"

    # Source the library directly
    source "$PROJECT_ROOT/packages/status/lib/branch-status.sh"
}

# Helper to create a git mock that returns specific values
# Usage: mock_git "branch-name" "behind" "ahead"
mock_git() {
    local branch="$1"
    local behind="$2"
    local ahead="$3"

    # Create mock in test temp dir
    mkdir -p "$TEST_TEMP_DIR/mock-bin"
    cat > "$TEST_TEMP_DIR/mock-bin/git" <<EOF
#!/bin/bash
case "\$1" in
    rev-parse)
        if [[ "\$2" == "--abbrev-ref" ]]; then
            echo "$branch"
        fi
        ;;
    fetch)
        exit 0
        ;;
    rev-list)
        # Output: behind<tab>ahead
        printf '%s\t%s\n' "$behind" "$ahead"
        ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/mock-bin/git"
    export PATH="$TEST_TEMP_DIR/mock-bin:$PATH"
}

# ============================================================================
# Basic Display Tests
# ============================================================================

@test "show_branch_status shows ahead count when ahead of remote" {
    mock_git "feature-branch" "0" "3"

    run show_branch_status

    assert_success
    assert_output --partial "⇡3"
    assert_output --partial "feature-branch"
}

@test "show_branch_status shows behind count when behind remote" {
    mock_git "feature-branch" "2" "0"

    run show_branch_status

    assert_success
    assert_output --partial "⇣2"
    assert_output --partial "feature-branch"
}

@test "show_branch_status shows both when diverged" {
    mock_git "feature-branch" "2" "3"

    run show_branch_status

    assert_success
    assert_output --partial "⇡3"
    assert_output --partial "⇣2"
    assert_output --partial "feature-branch"
}

# ============================================================================
# Return Code Tests
# ============================================================================

@test "show_branch_status returns 1 when in sync" {
    mock_git "feature-branch" "0" "0"

    run show_branch_status

    assert_failure
    assert_output ""
}

@test "show_branch_status returns 1 when on develop branch" {
    mock_git "develop" "5" "3"

    run show_branch_status

    assert_failure
}

# ============================================================================
# Suggestion Tests
# ============================================================================

@test "show_branch_status suggests pull when behind" {
    mock_git "feature-branch" "1" "0"

    run show_branch_status

    assert_success
    assert_output --partial "(v0 pull)"
    refute_output --partial "(v0 push)"
}

@test "show_branch_status suggests push when strictly ahead" {
    mock_git "feature-branch" "0" "5"

    run show_branch_status

    assert_success
    assert_output --partial "(v0 push)"
    refute_output --partial "(v0 pull)"
}

@test "show_branch_status suggests pull when both ahead and behind" {
    mock_git "feature-branch" "2" "3"

    run show_branch_status

    assert_success
    assert_output --partial "(v0 pull)"
    refute_output --partial "(v0 push)"
}

# ============================================================================
# Environment Variable Tests
# ============================================================================

@test "show_branch_status respects V0_DEVELOP_BRANCH" {
    export V0_DEVELOP_BRANCH="main"

    # Mock that returns develop branch name matching V0_DEVELOP_BRANCH
    mock_git "main" "0" "5"

    run show_branch_status

    # Should skip when on the develop branch (main in this case)
    assert_failure
}

@test "show_branch_status uses default develop branch when V0_DEVELOP_BRANCH unset" {
    unset V0_DEVELOP_BRANCH

    # Create mock - the function defaults to "agent" branch
    mock_git "feature-branch" "0" "2"

    run show_branch_status

    assert_success
    assert_output --partial "⇡2"
}

# ============================================================================
# Git Error Handling Tests
# ============================================================================

@test "show_branch_status returns 1 when git rev-parse fails" {
    mkdir -p "$TEST_TEMP_DIR/mock-bin"
    cat > "$TEST_TEMP_DIR/mock-bin/git" <<'EOF'
#!/bin/bash
case "$1" in
    rev-parse)
        exit 1
        ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/mock-bin/git"
    export PATH="$TEST_TEMP_DIR/mock-bin:$PATH"

    run show_branch_status

    assert_failure
}

@test "show_branch_status continues when git fetch fails" {
    mkdir -p "$TEST_TEMP_DIR/mock-bin"
    cat > "$TEST_TEMP_DIR/mock-bin/git" <<'EOF'
#!/bin/bash
case "$1" in
    rev-parse)
        echo "feature-branch"
        ;;
    fetch)
        exit 1
        ;;
    rev-list)
        printf '0\t3\n'
        ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/mock-bin/git"
    export PATH="$TEST_TEMP_DIR/mock-bin:$PATH"

    run show_branch_status

    assert_success
    assert_output --partial "⇡3"
}

@test "show_branch_status returns 1 when git rev-list fails" {
    mkdir -p "$TEST_TEMP_DIR/mock-bin"
    cat > "$TEST_TEMP_DIR/mock-bin/git" <<'EOF'
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
    chmod +x "$TEST_TEMP_DIR/mock-bin/git"
    export PATH="$TEST_TEMP_DIR/mock-bin:$PATH"

    run show_branch_status

    assert_failure
}
