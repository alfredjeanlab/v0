#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# v0-pull.bats - Integration tests for v0-pull script

load '../packages/test-support/helpers/test_helper'

# Path to the script under test
V0_PULL="${PROJECT_ROOT}/bin/v0-pull"

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

@test "v0-pull: --help shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_PULL}"'" --help
    '
    assert_success
    assert_output --partial "Usage: v0 pull"
    assert_output --partial "Pull changes from the agent branch"
}

@test "v0-pull: -h shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_PULL}"'" -h
    '
    assert_success
    assert_output --partial "Usage: v0 pull"
}

@test "v0-pull: unknown option shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_PULL}"'" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option: --unknown"
}

# ============================================================================
# Fast-forward and merge tests require more complex setup
# ============================================================================

@test "v0-pull: requires git repository" {
    # bats test_tags=todo:implement
    skip "Mock git interferes with this test"
}

@test "v0-pull: fast-forwards when possible" {
    # bats test_tags=todo:implement
    skip "Requires complex git setup with remote agent branch"
}

@test "v0-pull: creates merge commit when needed" {
    # bats test_tags=todo:implement
    skip "Requires complex git setup with diverged branches"
}

@test "v0-pull: fails on conflicts without --resolve" {
    # bats test_tags=todo:implement
    skip "Requires complex git setup with conflicting changes"
}

@test "v0-pull: --resolve handles conflicts" {
    # bats test_tags=todo:implement
    skip "Requires claude mock and complex git setup"
}
