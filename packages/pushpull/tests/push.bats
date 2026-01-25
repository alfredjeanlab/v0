#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Unit tests for packages/pushpull/lib/push.sh

load '../../test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env "testproject" "test"

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

@test "pp_get_last_push_commit returns empty when no marker" {
    run pp_get_last_push_commit
    assert_success
    assert_output ""
}

@test "pp_set_last_push_commit creates marker file" {
    pp_set_last_push_commit "abc123def456"
    run pp_get_last_push_commit
    assert_success
    assert_output "abc123def456"
}

@test "pp_set_last_push_commit overwrites existing marker" {
    pp_set_last_push_commit "first123"
    pp_set_last_push_commit "second456"
    run pp_get_last_push_commit
    assert_success
    assert_output "second456"
}

@test "pp_set_last_push_commit creates .v0 directory if missing" {
    rm -rf "${V0_ROOT}/.v0"
    pp_set_last_push_commit "abc123"
    assert_file_exists "${V0_ROOT}/.v0/last-push"
}

@test "pp_agent_has_diverged returns 1 when agent is ancestor of HEAD" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}

@test "pp_show_divergence displays commits since last push" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}

@test "pp_do_push pushes and records marker" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}
