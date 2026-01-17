#!/usr/bin/env bats
# Tests for v0-attach - Attach to running v0 tmux sessions
load '../helpers/test_helper'

# Helper to create an isolated project directory
# This prevents test from finding real .v0.rc files in parent directories
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="myproject"
ISSUE_PREFIX="mp"
EOF
    echo "${isolated_dir}/project"
}

# ============================================================================
# Session name generation tests (using env isolation like v0-common tests)
# ============================================================================

@test "attach generates correct fix session name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        v0_session_name "worker" "fix"
    '
    assert_success
    assert_output "v0-myproject-worker-fix"
}

@test "attach generates correct chore session name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        v0_session_name "worker" "chore"
    '
    assert_success
    assert_output "v0-myproject-worker-chore"
}

@test "attach generates correct feature session names" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        v0_session_name "auth" "plan"
    '
    assert_success
    assert_output "v0-myproject-auth-plan"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "attach shows usage with no arguments" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach"
    '
    assert_failure
    assert_output --partial "Usage: v0 attach"
}

@test "attach shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" --help
    '
    assert_failure  # usage exits with 1
    assert_output --partial "Usage: v0 attach"
}

@test "attach feature requires name argument" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature
    '
    assert_failure
    assert_output --partial "feature name required"
}

# ============================================================================
# Error handling tests
# ============================================================================

@test "attach fix shows error when no session running" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" fix
    '
    assert_failure
    assert_output --partial "No active fix session"
    assert_output --partial "v0 fix --start"
}

@test "attach chore shows error when no session running" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" chore
    '
    assert_failure
    assert_output --partial "No active chore session"
}

@test "attach mergeq shows error when no resolution session active" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" mergeq
    '
    assert_failure
    assert_output --partial "No active merge resolution session found"
}

@test "attach feature shows error for unknown feature" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature nonexistent
    '
    assert_failure
    assert_output --partial "No state found for feature"
}

@test "attach unknown type shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" invalid
    '
    assert_failure
    assert_output --partial "Unknown type"
}

# ============================================================================
# List sessions tests
# ============================================================================

@test "attach --list shows message when no sessions for project" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" --list
    '
    assert_success
    # Either shows "No active v0 sessions" or lists sessions (if any v0-myproject-* exist)
    assert_output --regexp "(No active v0 sessions|Active v0 sessions)"
}

@test "attach -l is alias for --list" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" -l
    '
    assert_success
    assert_output --regexp "(No active v0 sessions|Active v0 sessions)"
}

# ============================================================================
# Feature phase detection tests
# ============================================================================

@test "attach feature detects executing phase from state" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file with executing phase
    mkdir -p "${project_dir}/.v0/build/operations/auth"
    cat > "${project_dir}/.v0/build/operations/auth/state.json" <<'EOF'
{
  "name": "auth",
  "phase": "executing",
  "tmux_session": "v0-myproject-auth-feature"
}
EOF

    # Will fail because session doesn't exist, but should try correct session
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature auth
    '
    assert_failure
    assert_output --partial "v0-myproject-auth-feature"
}

@test "attach feature detects planned phase from state" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file with planned phase (no tmux_session field)
    mkdir -p "${project_dir}/.v0/build/operations/auth"
    cat > "${project_dir}/.v0/build/operations/auth/state.json" <<'EOF'
{
  "name": "auth",
  "phase": "planned"
}
EOF

    # Will fail because session doesn't exist, but should derive correct session
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature auth
    '
    assert_failure
    assert_output --partial "v0-myproject-auth-plan"
}

@test "attach feature detects queued phase from state" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file with queued phase
    mkdir -p "${project_dir}/.v0/build/operations/api"
    cat > "${project_dir}/.v0/build/operations/api/state.json" <<'EOF'
{
  "name": "api",
  "phase": "queued"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature api
    '
    assert_failure
    assert_output --partial "v0-myproject-api-decompose"
}

@test "attach feature shows status for merged phase" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file with merged phase
    mkdir -p "${project_dir}/.v0/build/operations/done"
    cat > "${project_dir}/.v0/build/operations/done/state.json" <<'EOF'
{
  "name": "done",
  "phase": "merged"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature done
    '
    assert_success
    assert_output --partial "merged"
    assert_output --partial "no active session"
}

@test "attach feature uses stored tmux_session when available" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file with explicit tmux_session
    mkdir -p "${project_dir}/.v0/build/operations/custom"
    cat > "${project_dir}/.v0/build/operations/custom/state.json" <<'EOF'
{
  "name": "custom",
  "phase": "executing",
  "tmux_session": "v0-myproject-custom-feature"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" feature custom
    '
    assert_failure
    assert_output --partial "v0-myproject-custom-feature"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 attach command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" attach --help
    '
    assert_failure  # usage exits with 1
    assert_output --partial "Usage: v0 attach"
}

@test "v0 --help shows attach command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "attach"
    assert_output --partial "Attach to a running tmux session"
}

# ============================================================================
# Feature name shorthand tests
# ============================================================================

@test "attach <feature_name> shorthand works for existing feature" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file for the feature
    mkdir -p "${project_dir}/.v0/build/operations/auth"
    cat > "${project_dir}/.v0/build/operations/auth/state.json" <<'EOF'
{
  "name": "auth",
  "phase": "executing"
}
EOF

    # Will fail because session doesn't exist, but should try the correct session
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" auth
    '
    assert_failure
    assert_output --partial "v0-myproject-auth-feature"
}

@test "attach <feature_name> shorthand detects planned phase" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create state file with planned phase
    mkdir -p "${project_dir}/.v0/build/operations/api"
    cat > "${project_dir}/.v0/build/operations/api/state.json" <<'EOF'
{
  "name": "api",
  "phase": "planned"
}
EOF

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" api
    '
    assert_failure
    assert_output --partial "v0-myproject-api-plan"
}

@test "attach shows usage for shorthand with unknown feature" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # No state file exists for this feature name
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-attach" notafeature
    '
    assert_failure
    assert_output --partial "Unknown type"
}
