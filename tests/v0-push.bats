#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# v0-push.bats - Integration tests for v0-push script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_PUSH="${PROJECT_ROOT}/bin/v0-push"

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
V0_DEVELOP_BRANCH="agent"
V0_GIT_REMOTE="origin"
EOF
    echo "${isolated_dir}/project"
}

setup() {
    _base_setup
    export PATH="${TESTS_DIR}/helpers/mock-bin:${PATH}"
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-push: --help shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_PUSH}"'" --help
    '
    assert_success
    assert_output --partial "Usage: v0 push"
    assert_output --partial "Reset the agent branch"
}

@test "v0-push: -h shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_PUSH}"'" -h
    '
    assert_success
    assert_output --partial "Usage: v0 push"
}

@test "v0-push: unknown option shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_PUSH}"'" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option: --unknown"
}

# ============================================================================
# Push and divergence tests require more complex setup
# ============================================================================

@test "v0-push: requires git repository" {
    # bats test_tags=todo:implement
    skip "Mock git interferes with this test"
}

@test "v0-push: resets agent branch" {
    # bats test_tags=todo:implement
    skip "Requires complex git setup with remote"
}

@test "v0-push: fails when agent has diverged" {
    # bats test_tags=todo:implement
    skip "Requires complex git setup with diverged agent branch"
}

@test "v0-push: --force overwrites diverged agent" {
    # bats test_tags=todo:implement
    skip "Requires complex git setup with diverged agent branch"
}
