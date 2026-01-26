#!/usr/bin/env bats
# Tests for config.sh - Configuration functions

load '../../test-support/helpers/test_helper'

# ============================================================================
# Setup/Teardown
# ============================================================================

setup() {
    _base_setup
    source_lib "grep.sh"
    source_lib "config.sh"
}

# ============================================================================
# v0_generate_user_branch() tests
# ============================================================================

@test "v0_generate_user_branch returns v0/agent/ prefix" {
    result=$(v0_generate_user_branch)
    [[ "$result" == v0/agent/* ]]
}

@test "v0_generate_user_branch includes username" {
    local username
    username=$(whoami | tr '[:upper:]' '[:lower:]')

    result=$(v0_generate_user_branch)
    [[ "$result" == v0/agent/${username}-* ]]
}

@test "v0_generate_user_branch includes 4-char hex id" {
    result=$(v0_generate_user_branch)

    # Extract the suffix after the last dash
    local suffix
    suffix="${result##*-}"

    # Should be 4 hex characters (2 bytes from xxd -p)
    [[ ${#suffix} -eq 4 ]]
    [[ "$suffix" =~ ^[0-9a-f]{4}$ ]]
}

@test "v0_generate_user_branch generates unique values" {
    local result1 result2
    result1=$(v0_generate_user_branch)
    result2=$(v0_generate_user_branch)

    # The two calls should generate different IDs
    [[ "$result1" != "$result2" ]]
}

# ============================================================================
# v0_infer_workspace_mode() tests
# ============================================================================

@test "v0_infer_workspace_mode returns clone for main" {
    result=$(v0_infer_workspace_mode "main")
    [[ "$result" == "clone" ]]
}

@test "v0_infer_workspace_mode returns clone for develop" {
    result=$(v0_infer_workspace_mode "develop")
    [[ "$result" == "clone" ]]
}

@test "v0_infer_workspace_mode returns clone for master" {
    result=$(v0_infer_workspace_mode "master")
    [[ "$result" == "clone" ]]
}

@test "v0_infer_workspace_mode returns worktree for v0/develop" {
    result=$(v0_infer_workspace_mode "v0/develop")
    [[ "$result" == "worktree" ]]
}

@test "v0_infer_workspace_mode returns worktree for v0/agent/*" {
    result=$(v0_infer_workspace_mode "v0/agent/alice-1234")
    [[ "$result" == "worktree" ]]
}

@test "v0_infer_workspace_mode returns worktree for feature branches" {
    result=$(v0_infer_workspace_mode "feature/my-feature")
    [[ "$result" == "worktree" ]]
}

# ============================================================================
# v0_init_agent_remote() tests
# ============================================================================

@test "v0_init_agent_remote creates bare repository" {
    local project_dir="${TEST_TEMP_DIR}/project"
    local state_dir="${TEST_TEMP_DIR}/state"

    mkdir -p "${project_dir}"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    v0_init_agent_remote "${project_dir}" "${state_dir}"

    # Check that bare repo was created
    assert_dir_exists "${state_dir}/remotes/agent.git"

    # Verify it's a bare repository
    run git -C "${state_dir}/remotes/agent.git" rev-parse --is-bare-repository
    assert_success
    assert_output "true"
}

@test "v0_init_agent_remote adds agent remote to project" {
    local project_dir="${TEST_TEMP_DIR}/project"
    local state_dir="${TEST_TEMP_DIR}/state"

    mkdir -p "${project_dir}"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    v0_init_agent_remote "${project_dir}" "${state_dir}"

    # Check that agent remote exists
    run git -C "${project_dir}" remote get-url agent
    assert_success
    assert_output "${state_dir}/remotes/agent.git"
}

@test "v0_init_agent_remote is idempotent" {
    local project_dir="${TEST_TEMP_DIR}/project"
    local state_dir="${TEST_TEMP_DIR}/state"

    mkdir -p "${project_dir}"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    # Call twice
    v0_init_agent_remote "${project_dir}" "${state_dir}"
    v0_init_agent_remote "${project_dir}" "${state_dir}"

    # Should still work
    run git -C "${project_dir}" remote get-url agent
    assert_success
}

@test "v0_init_agent_remote skips if agent.git exists" {
    local project_dir="${TEST_TEMP_DIR}/project"
    local state_dir="${TEST_TEMP_DIR}/state"

    mkdir -p "${project_dir}"
    mkdir -p "${state_dir}/remotes/agent.git"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    # Should return early without error
    run v0_init_agent_remote "${project_dir}" "${state_dir}"
    assert_success
}

# ============================================================================
# v0_ensure_develop_branch() tests
# ============================================================================

@test "v0_ensure_develop_branch creates v0/agent branch from HEAD" {
    local project_dir="${TEST_TEMP_DIR}/project"

    mkdir -p "${project_dir}"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    cd "${project_dir}" || return 1
    v0_ensure_develop_branch "v0/agent/test-1234" "origin"

    # Check branch was created
    run git -C "${project_dir}" branch --list "v0/agent/test-1234"
    assert_success
    [[ -n "$output" ]]
}

@test "v0_ensure_develop_branch skips remote check for v0/agent/* branches" {
    local project_dir="${TEST_TEMP_DIR}/project"

    mkdir -p "${project_dir}"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    # No remote configured - should still succeed for v0/agent/* branches
    cd "${project_dir}" || return 1
    run v0_ensure_develop_branch "v0/agent/alice-abcd" "origin"
    assert_success
}

@test "v0_ensure_develop_branch is idempotent" {
    local project_dir="${TEST_TEMP_DIR}/project"

    mkdir -p "${project_dir}"
    git -C "${project_dir}" init --initial-branch=main
    git -C "${project_dir}" commit --allow-empty -m "Initial commit"

    cd "${project_dir}" || return 1
    v0_ensure_develop_branch "v0/agent/test-5678" "origin"
    v0_ensure_develop_branch "v0/agent/test-5678" "origin"

    # Should still have one branch
    run git -C "${project_dir}" branch --list "v0/agent/test-5678"
    assert_success
    [[ $(echo "$output" | wc -l | tr -d ' ') -eq 1 ]]
}
