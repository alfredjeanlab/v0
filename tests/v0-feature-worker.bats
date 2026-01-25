#!/usr/bin/env bats
# Tests for v0-feature-worker - Background Worker for Feature Operations

load '../packages/test-support/helpers/test_helper'

# Setup for feature worker tests
setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/project/.v0/build/operations"
    mkdir -p "$TEST_TEMP_DIR/state"

    export REAL_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.local/state/v0/testproject/tree"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "$TEST_TEMP_DIR/project"
    export ORIGINAL_PATH="$PATH"

    # Create valid v0 config
    create_v0rc "testproject" "testp"

    # Export paths matching what v0-feature-worker uses
    export V0_ROOT="$TEST_TEMP_DIR/project"
    export PROJECT="testproject"
    export ISSUE_PREFIX="testp"
    export V0_STATE_DIR="$HOME/.local/state/v0/testproject"
    export BUILD_DIR="$TEST_TEMP_DIR/project/.v0/build"
    export PLANS_DIR="$TEST_TEMP_DIR/project/plans"
    export REPO_NAME="project"
    export V0_DIR="$PROJECT_ROOT"
    export V0_FEATURE_BRANCH="feature/{name}"
}

teardown() {
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"

    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# run-feature.sh Script Generation Tests
# ============================================================================

# Helper to generate the run-feature.sh script like v0-feature-worker does
generate_decompose_script() {
    local NAME="$1"
    local STATE_DIR="$BUILD_DIR/operations/$NAME"
    local FEATURE_BRANCH="feature/$NAME"
    local TREE_DIR="$V0_STATE_DIR/tree/$FEATURE_BRANCH"
    local WORKTREE="$TREE_DIR/$REPO_NAME"
    local PLAN_FILE="$PLANS_DIR/$NAME.md"
    local V0_SAFE_EXPORT=""

    mkdir -p "$STATE_DIR"
    mkdir -p "$TREE_DIR"

    cat > "$STATE_DIR/run-feature.sh" <<EOF
#!/bin/bash
cd '${V0_ROOT}'
export V0_ROOT='${V0_ROOT}'
${V0_SAFE_EXPORT}
script -q '${STATE_DIR}/logs/feature.log' '${V0_DIR}/bin/v0-decompose' '${PLAN_FILE}'
EXIT_CODE=\$?
[[ ! -f '${STATE_DIR}/logs/feature.exit' ]] && echo \${EXIT_CODE} > '${STATE_DIR}/logs/feature.exit'
EOF
    chmod +x "$STATE_DIR/run-feature.sh"
}

@test "run-feature.sh changes to V0_ROOT not WORKTREE" {
    # This test verifies the fix for the bug where decompose ran from
    # the worktree context instead of the main repo, causing the
    # "plan file is not committed" error even when it was committed on main
    generate_decompose_script "test-feature"

    run cat "$BUILD_DIR/operations/test-feature/run-feature.sh"
    assert_success

    # Verify script cd's to V0_ROOT (main repo), not WORKTREE
    assert_output --partial "cd '$V0_ROOT'"

    # Verify it does NOT cd to the worktree path
    local worktree_path="$V0_STATE_DIR/tree/feature/test-feature/$REPO_NAME"
    refute_output --partial "cd '$worktree_path'"
}

@test "run-feature.sh exports V0_ROOT" {
    generate_decompose_script "test-feature"

    run cat "$BUILD_DIR/operations/test-feature/run-feature.sh"
    assert_success

    # Verify V0_ROOT is exported for child processes
    assert_output --partial "export V0_ROOT='$V0_ROOT'"
}

@test "run-feature.sh is executable" {
    generate_decompose_script "test-feature"

    assert [ -x "$BUILD_DIR/operations/test-feature/run-feature.sh" ]
}

@test "run-feature.sh is valid bash" {
    generate_decompose_script "test-feature"

    run bash -n "$BUILD_DIR/operations/test-feature/run-feature.sh"
    assert_success
}

@test "run-feature.sh passes correct plan file path" {
    generate_decompose_script "my-epic"

    run cat "$BUILD_DIR/operations/my-epic/run-feature.sh"
    assert_success

    # Verify the plan file path uses the main repo's plans directory
    assert_output --partial "$PLANS_DIR/my-epic.md"
}

# ============================================================================
# run-plan.sh Script Generation Tests (Phase 1: Planning)
# ============================================================================

# Helper to generate the run-plan.sh script like v0-feature-worker does
generate_plan_script() {
    local NAME="$1"
    local STATE_DIR="$BUILD_DIR/operations/$NAME"
    local FEATURE_BRANCH="feature/$NAME"
    local TREE_DIR="$V0_STATE_DIR/tree/$FEATURE_BRANCH"
    local WORKTREE="$TREE_DIR/$REPO_NAME"
    local V0_SAFE_EXPORT=""

    mkdir -p "$STATE_DIR"
    mkdir -p "$TREE_DIR"

    # Planning phase correctly runs from the worktree
    cat > "$STATE_DIR/run-plan.sh" <<EOF
#!/bin/bash
cd '${WORKTREE}'
export V0_ROOT='${V0_ROOT}'
${V0_SAFE_EXPORT}
PROMPT="\$(cat '${STATE_DIR}/prompt.txt')"
script -q '${STATE_DIR}/logs/plan.log' '${V0_DIR}/bin/v0-plan' '${NAME}' "\${PROMPT}" --direct
EXIT_CODE=\$?
[[ ! -f '${STATE_DIR}/logs/plan.exit' ]] && echo \${EXIT_CODE} > '${STATE_DIR}/logs/plan.exit'
EOF
    chmod +x "$STATE_DIR/run-plan.sh"
}

@test "run-plan.sh changes to WORKTREE for planning phase" {
    # Planning phase correctly runs from the worktree because
    # the plan is created in the worktree's plans directory
    generate_plan_script "test-feature"

    local worktree_path="$V0_STATE_DIR/tree/feature/test-feature/$REPO_NAME"

    run cat "$BUILD_DIR/operations/test-feature/run-plan.sh"
    assert_success

    # Verify script cd's to WORKTREE for planning
    assert_output --partial "cd '$worktree_path'"
}

@test "run-plan.sh still exports V0_ROOT to main repo" {
    generate_plan_script "test-feature"

    run cat "$BUILD_DIR/operations/test-feature/run-plan.sh"
    assert_success

    # Even though we run from worktree, V0_ROOT should point to main repo
    assert_output --partial "export V0_ROOT='$V0_ROOT'"
}
