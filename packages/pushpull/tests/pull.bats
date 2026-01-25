#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Unit tests for packages/pushpull/lib/pull.sh

load '../../test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env "testproject" "test"
    init_mock_git_repo

    # Source pushpull after v0-common to get V0_DIR set
    source_lib "v0-common.sh"
    export V0_DIR="${PROJECT_ROOT}"
    source "${PROJECT_ROOT}/packages/pushpull/lib/pushpull.sh"
}

teardown() {
    # Restore HOME (only if REAL_HOME was set)
    [[ -n "${REAL_HOME:-}" ]] && export HOME="$REAL_HOME"

    # Clean up temp directory
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        /bin/rm -rf "$TEST_TEMP_DIR"
    fi
}

@test "pp_get_agent_branch returns V0_DEVELOP_BRANCH when set" {
    V0_DEVELOP_BRANCH="agent"
    run pp_get_agent_branch
    assert_success
    assert_output "agent"
}

@test "pp_get_agent_branch returns default when not set" {
    unset V0_DEVELOP_BRANCH
    run pp_get_agent_branch
    assert_success
    assert_output "agent"
}

@test "pp_get_agent_branch uses custom branch name" {
    V0_DEVELOP_BRANCH="develop"
    run pp_get_agent_branch
    assert_success
    assert_output "develop"
}

@test "pp_resolve_target_branch uses current branch when none specified" {
    cd "$TEST_TEMP_DIR/project"
    run pp_resolve_target_branch ""
    assert_success
    # Should return current branch name (main or master depending on git version)
    [[ "$output" =~ ^(main|master)$ ]]
}

@test "pp_resolve_target_branch uses specified branch" {
    run pp_resolve_target_branch "feature-x"
    assert_success
    assert_output "feature-x"
}

@test "pp_resolve_target_branch preserves branch name exactly" {
    run pp_resolve_target_branch "feature/my-feature"
    assert_success
    assert_output "feature/my-feature"
}

@test "pp_has_conflicts returns 1 when no conflicts" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}

@test "pp_do_pull returns 1 when merge would conflict" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}
