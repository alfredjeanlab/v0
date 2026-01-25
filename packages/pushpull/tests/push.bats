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

@test "pp_agent_has_diverged returns 1 when remote ref does not exist" {
    # Initialize a git repo without any remote refs
    init_mock_git_repo

    # Set remote and branch variables (no actual remote needed)
    export V0_GIT_REMOTE="origin"
    export V0_DEVELOP_BRANCH="agent"

    # Run the function - should return 1 (not diverged) since origin/agent doesn't exist
    run pp_agent_has_diverged
    assert_failure  # exit code 1 means "not diverged"
}

@test "pp_show_divergence displays commits since last push" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}

@test "pp_do_push pushes and records marker" {
    # bats test_tags=todo:implement
    skip "Requires more complex git setup with remote"
}

@test "pp_do_push updates local agent branch if it exists" {
    # Set up git repo
    init_mock_git_repo

    # Create a bare remote to push to
    git clone --bare "${TEST_TEMP_DIR}/project" "${TEST_TEMP_DIR}/remote.git" --quiet
    cd "${TEST_TEMP_DIR}/project"
    git remote set-url origin "${TEST_TEMP_DIR}/remote.git"

    # Create agent branch at current commit
    git branch "v0/develop"

    # Make a new commit on main
    echo "new content" > newfile.txt
    git add newfile.txt
    git commit -m "New commit on main" --quiet

    # At this point:
    # - main is at the new commit
    # - v0/develop is at the old commit
    local main_commit
    main_commit=$(git rev-parse main)
    local agent_commit_before
    agent_commit_before=$(git rev-parse "v0/develop")

    # Verify they're different
    [[ "$main_commit" != "$agent_commit_before" ]]

    # Set up environment
    export V0_GIT_REMOTE="origin"
    export V0_DEVELOP_BRANCH="v0/develop"

    # Run push
    run pp_do_push "main"
    assert_success

    # Verify local agent branch was updated
    local agent_commit_after
    agent_commit_after=$(git rev-parse "v0/develop")
    [[ "$agent_commit_after" == "$main_commit" ]]
}

@test "pp_do_push skips local update when branch is in worktree" {
    # Set up git repo
    init_mock_git_repo

    # Create a bare remote to push to
    git clone --bare "${TEST_TEMP_DIR}/project" "${TEST_TEMP_DIR}/remote.git" --quiet
    cd "${TEST_TEMP_DIR}/project"
    git remote set-url origin "${TEST_TEMP_DIR}/remote.git"

    # Create agent branch at current commit
    git branch "v0/develop"
    local initial_commit
    initial_commit=$(git rev-parse "v0/develop")

    # Create a worktree using the agent branch
    git worktree add "${TEST_TEMP_DIR}/agent-worktree" "v0/develop" --quiet

    # Make a new commit on main
    echo "new content" > newfile.txt
    git add newfile.txt
    git commit -m "New commit on main" --quiet

    local main_commit
    main_commit=$(git rev-parse main)

    # Set up environment
    export V0_GIT_REMOTE="origin"
    export V0_DEVELOP_BRANCH="v0/develop"

    # Run push - should succeed even though v0/develop is in a worktree
    run pp_do_push "main"
    assert_success

    # Verify remote was updated (check the bare repo)
    cd "${TEST_TEMP_DIR}/remote.git"
    local remote_commit
    remote_commit=$(git rev-parse "v0/develop")
    [[ "$remote_commit" == "$main_commit" ]]

    # Local branch should still be at old commit (can't update due to worktree)
    cd "${TEST_TEMP_DIR}/project"
    local local_agent_commit
    local_agent_commit=$(git rev-parse "v0/develop")
    [[ "$local_agent_commit" == "$initial_commit" ]]

    # Clean up worktree
    git worktree remove "${TEST_TEMP_DIR}/agent-worktree" --force
}
