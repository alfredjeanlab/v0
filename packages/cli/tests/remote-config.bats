#!/usr/bin/env bats
# Tests for V0_GIT_REMOTE configuration

load '../../test-support/helpers/test_helper'

# ============================================================================
# V0_GIT_REMOTE Configuration Tests
# ============================================================================

@test "V0_GIT_REMOTE defaults to agent" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    assert_equal "${V0_GIT_REMOTE}" "agent"
}

@test "V0_GIT_REMOTE can be customized in .v0.rc" {
    cat > "${TEST_TEMP_DIR}/project/.v0.rc" <<'EOF'
PROJECT="testproj"
ISSUE_PREFIX="tp"
V0_GIT_REMOTE="upstream"
EOF
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    assert_equal "${V0_GIT_REMOTE}" "upstream"
}

@test "V0_GIT_REMOTE is exported for subprocesses" {
    create_v0rc
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    # Check that it's in the exported environment
    run bash -c 'echo $V0_GIT_REMOTE'
    assert_success
    assert_output "agent"
}

@test "V0_GIT_REMOTE custom value is exported for subprocesses" {
    cat > "${TEST_TEMP_DIR}/project/.v0.rc" <<'EOF'
PROJECT="testproj"
ISSUE_PREFIX="tp"
V0_GIT_REMOTE="upstream"
EOF
    cd "${TEST_TEMP_DIR}/project" || return 1
    source_lib "v0-common.sh"
    v0_load_config

    # Check that custom value is exported
    run bash -c 'echo $V0_GIT_REMOTE'
    assert_success
    assert_output "upstream"
}

@test "v0_init_config includes V0_GIT_REMOTE in template" {
    cd "${TEST_TEMP_DIR}/project" || return 1
    rm -f .v0.rc  # Remove any existing config

    # Mock wk init to avoid wk dependency
    setup_mock_binaries wk

    source_lib "v0-common.sh"
    v0_init_config

    # Check that the generated .v0.rc contains V0_GIT_REMOTE option
    assert_file_exists "${TEST_TEMP_DIR}/project/.v0.rc"
    run grep "V0_GIT_REMOTE" "${TEST_TEMP_DIR}/project/.v0.rc"
    assert_success
    assert_output --partial 'V0_GIT_REMOTE="agent"'
}

# ============================================================================
# Template Tests
# ============================================================================

@test "claude.build.m4 uses V0_GIT_REMOTE in git push commands" {
    local template_file="${PROJECT_ROOT}/packages/cli/lib/templates/claude.build.m4"

    # Check that template references V0_GIT_REMOTE
    run grep "V0_GIT_REMOTE" "${template_file}"
    assert_success
}

@test "uncommitted.md uses V0_GIT_REMOTE placeholder" {
    local prompt_file="${PROJECT_ROOT}/packages/cli/lib/prompts/uncommitted.md"

    # Check that prompt has the placeholder
    run grep "__V0_GIT_REMOTE__" "${prompt_file}"
    assert_success
}

# ============================================================================
# Integration Tests - V0_GIT_REMOTE with V0_DEVELOP_BRANCH
# ============================================================================

@test "stop-build.sh includes V0_GIT_REMOTE in error message" {
    local hook_file="${PROJECT_ROOT}/packages/hooks/lib/stop-build.sh"

    # Check that the hook uses V0_GIT_REMOTE
    run grep "V0_GIT_REMOTE" "${hook_file}"
    assert_success
}

@test "no hardcoded origin/ remote refs in bin scripts" {
    # Check that bin scripts don't have hardcoded 'origin/' in git commands
    # Exclude comments and documentation
    local scripts=(
        "${PROJECT_ROOT}/bin/v0-mergeq"
        "${PROJECT_ROOT}/bin/v0-merge"
        "${PROJECT_ROOT}/bin/v0-fix"
        "${PROJECT_ROOT}/bin/v0-chore"
        "${PROJECT_ROOT}/bin/v0-shutdown"
    )

    for script in "${scripts[@]}"; do
        # Look for origin/ followed by variable or branch pattern (not in comments)
        run bash -c "grep -n 'origin/' '$script' | grep -v '^[[:space:]]*#' | grep -v 'V0_GIT_REMOTE' || true"
        assert_output ""
    done
}
