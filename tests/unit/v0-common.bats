#!/usr/bin/env bats
# Tests for v0-common.sh - Configuration & Utility functions

load '../helpers/test_helper'

# ============================================================================
# v0_find_project_root() tests
# ============================================================================

@test "v0_find_project_root finds .v0.rc in current directory" {
    touch "${TEST_TEMP_DIR}/project/.v0.rc"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    run v0_find_project_root
    assert_success
    assert_output "${TEST_TEMP_DIR}/project"
}

@test "v0_find_project_root finds .v0.rc in parent directory" {
    touch "${TEST_TEMP_DIR}/project/.v0.rc"
    mkdir -p "${TEST_TEMP_DIR}/project/src/deep/nested"
    cd "${TEST_TEMP_DIR}/project/src/deep/nested" || return 1
    source_lib "v0-common.sh"

    run v0_find_project_root
    assert_success
    assert_output "${TEST_TEMP_DIR}/project"
}

@test "v0_find_project_root finds .v0.rc from arbitrary nested path" {
    touch "${TEST_TEMP_DIR}/project/.v0.rc"
    mkdir -p "${TEST_TEMP_DIR}/project/a/b/c/d/e"
    cd "${TEST_TEMP_DIR}/project/a/b/c/d/e" || return 1
    source_lib "v0-common.sh"

    run v0_find_project_root
    assert_success
    assert_output "${TEST_TEMP_DIR}/project"
}

@test "v0_find_project_root fails without .v0.rc" {
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    run v0_find_project_root
    assert_failure
}

@test "v0_find_project_root accepts start directory argument" {
    touch "${TEST_TEMP_DIR}/project/.v0.rc"
    mkdir -p "${TEST_TEMP_DIR}/project/subdir"
    source_lib "v0-common.sh"

    run v0_find_project_root "${TEST_TEMP_DIR}/project/subdir"
    assert_success
    assert_output "${TEST_TEMP_DIR}/project"
}

# ============================================================================
# v0_find_main_repo() tests
# ============================================================================

@test "v0_find_main_repo returns same directory for main repo" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    run v0_find_main_repo "${TEST_TEMP_DIR}/project"
    assert_success
    assert_output "${TEST_TEMP_DIR}/project"
}

@test "v0_find_main_repo returns main repo from worktree" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Get the default branch name (main or master depending on git version)
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Create a worktree on a new branch
    mkdir -p "${TEST_TEMP_DIR}/worktrees"
    git worktree add -b feature-branch "${TEST_TEMP_DIR}/worktrees/feature"

    source_lib "v0-common.sh"

    # From worktree, should return main repo
    # Note: resolve symlinks in expected path (macOS /var -> /private/var)
    local expected_path
    expected_path=$(cd "${TEST_TEMP_DIR}/project" && pwd -P)

    run v0_find_main_repo "${TEST_TEMP_DIR}/worktrees/feature"
    assert_success
    assert_output "${expected_path}"
}

@test "v0_find_main_repo returns input directory for non-git directory" {
    mkdir -p "${TEST_TEMP_DIR}/not-a-repo"
    source_lib "v0-common.sh"

    run v0_find_main_repo "${TEST_TEMP_DIR}/not-a-repo"
    assert_success
    assert_output "${TEST_TEMP_DIR}/not-a-repo"
}

@test "v0_find_main_repo uses V0_ROOT when no argument given" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    export V0_ROOT="${TEST_TEMP_DIR}/project"

    run v0_find_main_repo
    assert_success
    assert_output "${TEST_TEMP_DIR}/project"
}

# ============================================================================
# v0_load_config() tests
# ============================================================================

@test "v0_load_config loads valid configuration" {
    create_v0rc "testproject" "testp"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${PROJECT}" "testproject"
    assert_equal "${ISSUE_PREFIX}" "testp"
}

@test "v0_load_config sets V0_ROOT correctly" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${V0_ROOT}" "${TEST_TEMP_DIR}/project"
}

@test "v0_load_config ignores inherited V0_ROOT from environment" {
    # Create two separate projects
    mkdir -p "${TEST_TEMP_DIR}/project-a"
    mkdir -p "${TEST_TEMP_DIR}/project-b"

    # Set up project-a with its own .v0.rc
    cat > "${TEST_TEMP_DIR}/project-a/.v0.rc" <<'EOF'
PROJECT="project-a"
ISSUE_PREFIX="pa"
EOF

    # Set up project-b with its own .v0.rc
    cat > "${TEST_TEMP_DIR}/project-b/.v0.rc" <<'EOF'
PROJECT="project-b"
ISSUE_PREFIX="pb"
EOF

    # Set V0_ROOT to point to project-b (simulating inherited environment)
    export V0_ROOT="${TEST_TEMP_DIR}/project-b"
    export BUILD_DIR="${TEST_TEMP_DIR}/project-b/.v0/build"
    export PROJECT="project-b"

    # cd to project-a and load config
    cd "${TEST_TEMP_DIR}/project-a" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    # Verify that we're using project-a, NOT the inherited project-b values
    assert_equal "${V0_ROOT}" "${TEST_TEMP_DIR}/project-a"
    assert_equal "${PROJECT}" "project-a"
    assert_equal "${ISSUE_PREFIX}" "pa"
    assert_equal "${BUILD_DIR}" "${TEST_TEMP_DIR}/project-a/.v0/build"
}

@test "v0_load_config sets derived values" {
    create_v0rc "myproj" "mp"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${REPO_NAME}" "project"
    assert_equal "${BUILD_DIR}" "${TEST_TEMP_DIR}/project/.v0/build"
    assert_equal "${PLANS_DIR}" "${TEST_TEMP_DIR}/project/plans"
}

@test "v0_load_config fails without PROJECT" {
    # Create isolated temp directory structure that doesn't traverse to real .v0.rc
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project"
    echo 'ISSUE_PREFIX="test"' > "${isolated_dir}/project/.v0.rc"

    # v0_load_config calls exit 1 on error, so we need to run it in a subshell
    # Unset PROJECT and ISSUE_PREFIX to test validation (they may be inherited from parent env)
    run env -u PROJECT -u ISSUE_PREFIX bash -c 'cd "'"${isolated_dir}/project"'" && source "'"${PROJECT_ROOT}"'/lib/v0-common.sh" && v0_load_config'
    assert_failure
    assert_output --partial "PROJECT"
}

@test "v0_load_config fails without ISSUE_PREFIX" {
    # Create isolated temp directory structure that doesn't traverse to real .v0.rc
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project"
    echo 'PROJECT="testproject"' > "${isolated_dir}/project/.v0.rc"

    # v0_load_config calls exit 1 on error, so we need to run it in a subshell
    # Unset PROJECT and ISSUE_PREFIX to test validation (they may be inherited from parent env)
    run env -u PROJECT -u ISSUE_PREFIX bash -c 'cd "'"${isolated_dir}/project"'" && source "'"${PROJECT_ROOT}"'/lib/v0-common.sh" && v0_load_config'
    assert_failure
    assert_output --partial "ISSUE_PREFIX"
}

@test "v0_load_config sets default values" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${V0_BUILD_DIR}" ".v0/build"
    assert_equal "${V0_PLANS_DIR}" "plans"
    assert_equal "${V0_FEATURE_BRANCH}" "feature/{name}"
}

@test "v0_load_config allows custom overrides" {
    cat > "${TEST_TEMP_DIR}/project/.v0.rc" <<'EOF'
PROJECT="customproj"
ISSUE_PREFIX="cust"
V0_BUILD_DIR=".build"
V0_PLANS_DIR="docs/plans"
EOF
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${V0_BUILD_DIR}" ".build"
    assert_equal "${V0_PLANS_DIR}" "docs/plans"
    assert_equal "${BUILD_DIR}" "${TEST_TEMP_DIR}/project/.build"
    assert_equal "${PLANS_DIR}" "${TEST_TEMP_DIR}/project/docs/plans"
}

@test "v0_load_config with require_config=false returns 1 without .v0.rc" {
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    run v0_load_config false
    assert_failure
    # Should not output error message when require_config is false
    refute_output --partial "Error"
}

@test "v0_load_config sets V0_DEVELOP_BRANCH default to main" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${V0_DEVELOP_BRANCH}" "main"
}

@test "v0_load_config allows V0_DEVELOP_BRANCH override" {
    create_v0rc
    echo 'V0_DEVELOP_BRANCH="develop"' >> "${TEST_TEMP_DIR}/project/.v0.rc"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    assert_equal "${V0_DEVELOP_BRANCH}" "develop"
}

@test "v0_load_config exports V0_DEVELOP_BRANCH" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"

    v0_load_config

    # Verify it's exported by checking in subshell
    run bash -c 'echo "${V0_DEVELOP_BRANCH}"'
    assert_output "main"
}

# ============================================================================
# v0_issue_pattern() tests
# ============================================================================

@test "v0_issue_pattern generates correct regex" {
    source_lib "v0-common.sh"
    export ISSUE_PREFIX="myp"

    run v0_issue_pattern
    assert_success
    assert_output "myp-[a-z0-9]+"
}

@test "v0_issue_pattern uses configured ISSUE_PREFIX" {
    source_lib "v0-common.sh"
    export ISSUE_PREFIX="testprefix"

    run v0_issue_pattern
    assert_success
    assert_output "testprefix-[a-z0-9]+"
}

@test "v0_issue_pattern matches expected patterns" {
    source_lib "v0-common.sh"
    export ISSUE_PREFIX="proj"

    local pattern
    pattern=$(v0_issue_pattern)

    # Test that pattern matches valid issue IDs
    echo "proj-abc123" | grep -qE "${pattern}"
    echo "proj-a1b2c3" | grep -qE "${pattern}"
}

# ============================================================================
# v0_expand_branch() tests
# ============================================================================

@test "v0_expand_branch expands {name} placeholder" {
    source_lib "v0-common.sh"

    run v0_expand_branch "feature/{name}" "auth"
    assert_success
    assert_output "feature/auth"
}

@test "v0_expand_branch expands {id} placeholder" {
    source_lib "v0-common.sh"

    run v0_expand_branch "fix/{id}" "abc123"
    assert_success
    assert_output "fix/abc123"
}

@test "v0_expand_branch works with custom prefixes" {
    source_lib "v0-common.sh"

    run v0_expand_branch "feat/{name}" "login"
    assert_success
    assert_output "feat/login"
}

@test "v0_expand_branch handles both placeholders" {
    source_lib "v0-common.sh"

    # Test that {name} works when using it
    run v0_expand_branch "work/{name}" "task"
    assert_success
    assert_output "work/task"

    # And {id} also expands to same value
    run v0_expand_branch "work/{id}" "task"
    assert_success
    assert_output "work/task"
}

@test "v0_expand_branch preserves templates without placeholders" {
    source_lib "v0-common.sh"

    run v0_expand_branch "static-branch" "ignored"
    assert_success
    assert_output "static-branch"
}

# ============================================================================
# v0_log() tests
# ============================================================================

@test "v0_log creates log directory if needed" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    v0_log "test_event" "test message"

    assert_dir_exists "${BUILD_DIR}/logs"
}

@test "v0_log writes to log file" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    v0_log "test_event" "test message"

    assert_file_exists "${BUILD_DIR}/logs/v0.log"
    run cat "${BUILD_DIR}/logs/v0.log"
    assert_output --partial "test_event"
    assert_output --partial "test message"
}

@test "v0_log includes timestamp" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    v0_log "event" "msg"

    run cat "${BUILD_DIR}/logs/v0.log"
    # Timestamp format: [YYYY-MM-DDTHH:MM:SSZ]
    assert_output --regexp '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]'
}

@test "v0_log appends to existing log" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    v0_log "event1" "message1"
    v0_log "event2" "message2"

    run cat "${BUILD_DIR}/logs/v0.log"
    assert_output --partial "event1"
    assert_output --partial "event2"
}

# ============================================================================
# v0_check_deps() tests
# ============================================================================

@test "v0_check_deps succeeds when all dependencies present" {
    source_lib "v0-common.sh"

    # These commands should exist on any system
    run v0_check_deps "echo" "cat" "ls"
    assert_success
}

@test "v0_check_deps fails with missing dependency" {
    source_lib "v0-common.sh"

    run v0_check_deps "nonexistent_command_xyz123"
    assert_failure
    assert_output --partial "Missing required commands"
    assert_output --partial "nonexistent_command_xyz123"
}

@test "v0_check_deps reports all missing dependencies" {
    source_lib "v0-common.sh"

    run v0_check_deps "echo" "missing_cmd1" "cat" "missing_cmd2"
    assert_failure
    assert_output --partial "missing_cmd1"
    assert_output --partial "missing_cmd2"
}

@test "v0_check_deps succeeds with single valid dependency" {
    source_lib "v0-common.sh"

    run v0_check_deps "echo"
    assert_success
}

# ============================================================================
# v0_ensure_state_dir() tests
# ============================================================================

@test "v0_ensure_state_dir creates state directory" {
    create_v0rc "testproj" "tp"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    v0_ensure_state_dir

    assert_dir_exists "${V0_STATE_DIR}"
}

# ============================================================================
# v0_ensure_build_dir() tests
# ============================================================================

@test "v0_ensure_build_dir creates build directory" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    v0_ensure_build_dir

    assert_dir_exists "${BUILD_DIR}"
}

# ============================================================================
# V0_INSTALL_DIR tests
# ============================================================================

@test "V0_INSTALL_DIR is set correctly" {
    source_lib "v0-common.sh"

    assert [ -n "${V0_INSTALL_DIR}" ]
    assert [ -d "${V0_INSTALL_DIR}" ]
    assert [ -d "${V0_INSTALL_DIR}/lib" ]
}

# ============================================================================
# v0_session_name() tests
# ============================================================================

@test "v0_session_name generates namespaced names" {
    create_v0rc "myapp" "ma"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    local result
    result=$(v0_session_name "worker" "fix")
    assert_equal "${result}" "v0-myapp-worker-fix"
}

@test "v0_session_name fails without PROJECT" {
    source_lib "v0-common.sh"
    unset PROJECT

    run v0_session_name "worker" "fix"
    assert_failure
    assert_output --partial "PROJECT not set"
}

@test "v0_session_name with different suffixes and types" {
    create_v0rc "testproj" "tp"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    # Test various session types
    run v0_session_name "worker" "chore"
    assert_success
    assert_output "v0-testproj-worker-chore"

    run v0_session_name "polling" "fix"
    assert_success
    assert_output "v0-testproj-polling-fix"

    run v0_session_name "auth" "plan"
    assert_success
    assert_output "v0-testproj-auth-plan"

    run v0_session_name "api" "feature"
    assert_success
    assert_output "v0-testproj-api-feature"
}

@test "v0_session_name handles hyphenated suffixes" {
    create_v0rc "proj" "p"
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    run v0_session_name "feature-auth" "merge-resolve"
    assert_success
    assert_output "v0-proj-feature-auth-merge-resolve"
}

# ============================================================================
# v0_init_config() tests
# ============================================================================

@test "v0_init_config creates .v0.rc file" {
    local test_dir="${TEST_TEMP_DIR}/new-project"
    mkdir -p "${test_dir}"
    source_lib_with_mocks "v0-common.sh"

    run v0_init_config "${test_dir}"
    assert_success
    assert_file_exists "${test_dir}/.v0.rc"
}

@test "v0_init_config adds .v0/ to gitignore" {
    local test_dir="${TEST_TEMP_DIR}/new-project"
    mkdir -p "${test_dir}"
    source_lib_with_mocks "v0-common.sh"

    v0_init_config "${test_dir}"

    assert_file_exists "${test_dir}/.gitignore"
    run grep "^\.v0/" "${test_dir}/.gitignore"
    assert_success
}

@test "v0_init_config adds .v0/ to existing gitignore" {
    local test_dir="${TEST_TEMP_DIR}/new-project"
    mkdir -p "${test_dir}"
    echo "node_modules/" > "${test_dir}/.gitignore"
    source_lib_with_mocks "v0-common.sh"

    v0_init_config "${test_dir}"

    run grep "node_modules/" "${test_dir}/.gitignore"
    assert_success
    run grep "^\.v0/" "${test_dir}/.gitignore"
    assert_success
}

@test "v0_init_config does not duplicate .v0/ in gitignore" {
    local test_dir="${TEST_TEMP_DIR}/new-project"
    mkdir -p "${test_dir}"
    echo ".v0/" > "${test_dir}/.gitignore"
    source_lib_with_mocks "v0-common.sh"

    v0_init_config "${test_dir}"

    # Count occurrences of .v0/ - should be exactly 1
    local count
    count=$(grep -c "^\.v0/" "${test_dir}/.gitignore")
    assert_equal "${count}" "1"
}

# ============================================================================
# v0_git_worktree_clean() tests
# ============================================================================

@test "v0_git_worktree_clean returns 0 for clean repo" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"

    cd "${TEST_TEMP_DIR}/project" || return 1
    run v0_git_worktree_clean .
    assert_success
}

@test "v0_git_worktree_clean returns 1 for repo with staged changes" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"

    cd "${TEST_TEMP_DIR}/project" || return 1
    echo "new content" > newfile.txt
    git add newfile.txt

    run v0_git_worktree_clean .
    assert_failure
}

@test "v0_git_worktree_clean returns 1 for repo with unstaged changes" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"

    cd "${TEST_TEMP_DIR}/project" || return 1
    echo "modified" >> README.md

    run v0_git_worktree_clean .
    assert_failure
}

@test "v0_git_worktree_clean accepts directory argument" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"

    run v0_git_worktree_clean "${TEST_TEMP_DIR}/project"
    assert_success
}

@test "v0_git_worktree_clean returns 1 for non-git directory" {
    source_lib "v0-common.sh"
    mkdir -p "${TEST_TEMP_DIR}/not-a-repo"

    # Should return 1 (dirty/cannot verify) for non-git directories
    run v0_git_worktree_clean "${TEST_TEMP_DIR}/not-a-repo"
    assert_failure
}

# ============================================================================
# v0_verify_push() tests
# ============================================================================

@test "v0_verify_push returns 0 for commit on main" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    local commit
    commit=$(git rev-parse HEAD)

    run v0_verify_push "${commit}"
    assert_success
}

@test "v0_verify_push returns 1 for commit not on main" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create commit on separate branch
    git checkout -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Feature commit"
    local feature_commit
    feature_commit=$(git rev-parse HEAD)

    git checkout main

    run v0_verify_push "${feature_commit}"
    assert_failure
    assert_output --partial "is not on main branch"
}

@test "v0_verify_push returns 1 for nonexistent commit" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    local fake_commit="1234567890abcdef1234567890abcdef12345678"

    run v0_verify_push "${fake_commit}"
    assert_failure
    assert_output --partial "does not exist locally"
}

# ============================================================================
# v0_verify_push_with_retry() tests (DEPRECATED - now wraps v0_verify_push)
# ============================================================================

@test "v0_verify_push_with_retry returns 0 for commit on branch" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get the current commit
    local commit
    commit=$(git rev-parse HEAD)

    # Get current branch name (may be main or master depending on git version)
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Push to origin (so origin/main exists)
    git push -u origin "${branch}"

    # Verify commit is on origin branch
    run v0_verify_push_with_retry "${commit}" "origin/${branch}" 1 0
    assert_success
}

@test "v0_verify_push_with_retry returns 1 for commit not on branch" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "${branch}"

    # Create a new commit on a separate branch (not pushed)
    git checkout -b feature-branch
    echo "new content" > newfile.txt
    git add newfile.txt
    git commit -m "New commit on feature branch"
    local feature_commit
    feature_commit=$(git rev-parse HEAD)

    # Switch back to main
    git checkout "${branch}"

    # Verify feature commit is NOT on origin/main (should fail after retries)
    run v0_verify_push_with_retry "${feature_commit}" "origin/${branch}" 1 0
    assert_failure
}

@test "v0_verify_push_with_retry succeeds when remote moved forward" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Get commit A and push it
    local commit_a
    commit_a=$(git rev-parse HEAD)
    git push -u origin "${branch}"

    # Create commit B on top
    echo "more content" > more.txt
    git add more.txt
    git commit -m "Commit B"
    git push origin "${branch}"

    # Verify commit A is still on origin/main (because A is ancestor of B)
    run v0_verify_push_with_retry "${commit_a}" "origin/${branch}" 1 0
    assert_success
}

@test "v0_verify_push_with_retry uses prefix matching for commit hashes" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "${branch}"

    # Get full commit hash
    local full_commit
    full_commit=$(git rev-parse HEAD)

    # Use short hash (first 7 chars)
    local short_commit="${full_commit:0:7}"

    # Verify using short hash
    run v0_verify_push_with_retry "${short_commit}" "origin/${branch}" 1 0
    assert_success
}

# ============================================================================
# v0_diagnose_push_verification() tests
# ============================================================================

@test "v0_diagnose_push_verification outputs diagnostic info" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "${branch}"

    local commit
    commit=$(git rev-parse HEAD)

    # Capture diagnostic output
    run v0_diagnose_push_verification "${commit}" "origin/${branch}"

    # Check that key diagnostic sections are present
    assert_output --partial "Push Verification Diagnostic"
    assert_output --partial "Commit to verify:"
    assert_output --partial "Local refs:"
    assert_output --partial "Remote state"
    assert_output --partial "Ancestry check:"
}

@test "v0_diagnose_push_verification shows commit existence" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "${branch}"

    local commit
    commit=$(git rev-parse HEAD)

    run v0_diagnose_push_verification "${commit}" "origin/${branch}"
    assert_output --partial "exists locally"
}

@test "v0_diagnose_push_verification handles missing commit" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "${branch}"

    # Use a fake commit hash that doesn't exist
    local fake_commit="1234567890abcdef1234567890abcdef12345678"

    run v0_diagnose_push_verification "${fake_commit}" "origin/${branch}"
    assert_output --partial "NOT FOUND locally"
}

@test "v0_verify_push_with_retry still works for commits on local main" {
    source_lib "v0-common.sh"
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    cd "${TEST_TEMP_DIR}/project" || return 1

    # Create a bare "remote" repo and set up origin
    git clone --bare . "${TEST_TEMP_DIR}/origin.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "${TEST_TEMP_DIR}/origin.git"

    # Get current branch name
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Push initial commit
    git push -u origin "${branch}"

    # Get the commit we pushed
    local commit
    commit=$(git rev-parse HEAD)

    # Create a second commit and push it
    echo "second" > second.txt
    git add second.txt
    git commit -m "Second commit"
    git push origin "${branch}"

    local second_commit
    second_commit=$(git rev-parse HEAD)

    # Verification should succeed because commit is on local main
    # (DEPRECATED: this used to test ls-remote fallback, now just tests local main check)
    run v0_verify_push_with_retry "${second_commit}" "origin/${branch}" 1 0
    assert_success
}
