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

# ============================================================================
# Stale Session Handling Tests (Phase 2: Build)
# ============================================================================

@test "run_build_phase kills stale tmux session instead of returning early" {
    # Verify that v0-build-worker handles stale sessions by killing them
    # rather than returning early (which would leave the operation stuck)
    run grep -A 3 'if tmux has-session -t "\${SESSION}"' "$PROJECT_ROOT/bin/v0-build-worker"
    assert_success

    # Should kill the session, not return early
    assert_output --partial "kill-session"

    # Should NOT return 0 (which would leave phase unchanged)
    refute_output --partial "return 0"
}
