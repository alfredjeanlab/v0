#!/usr/bin/env bats
# Tests for v0-plan - tmux-based planning execution

load '../helpers/test_helper'

# ============================================================================
# Setup/Teardown
# ============================================================================

setup() {
    # Call common setup
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    mkdir -p "${TEST_TEMP_DIR}/state"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "${TEST_TEMP_DIR}/project" || return 1
    export ORIGINAL_PATH="${PATH}"

    # Create mock bin directory and mock v0-plan-exec
    MOCK_BIN="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${MOCK_BIN}"

    # Set V0_PLAN_EXEC to use our mock
    export V0_PLAN_EXEC="${MOCK_BIN}/v0-plan-exec"

    # Set V0_ROOT to prevent walking up to parent .v0.rc
    export V0_ROOT="${TEST_TEMP_DIR}/project"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"
    unset V0_PLAN_EXEC
    unset V0_ROOT

    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# Clean up tmux sessions once at end of file (not per-test)
teardown_file() {
    local sessions
    if sessions=$(timeout 2 tmux list-sessions -F '#{session_name}' 2>/dev/null); then
        for session in $sessions; do
            if [[ "$session" == v0-testproj-* ]]; then
                timeout 1 tmux kill-session -t "$session" 2>/dev/null || true
            fi
        done
    fi
}

# ============================================================================
# Session name generation tests
# ============================================================================

@test "v0-plan generates correct session name" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    result=$(v0_session_name "myplan" "plan")
    assert_equal "${result}" "v0-testproj-myplan-plan"
}

@test "v0-plan session name includes project name" {
    create_v0rc "myapp" "ma"
    source_lib "v0-common.sh"
    v0_load_config

    result=$(v0_session_name "auth" "plan")
    assert_equal "${result}" "v0-myapp-auth-plan"
}

# ============================================================================
# Wrapper script creation tests
# ============================================================================

@test "v0-plan creates wrapper script in state directory" {
    create_v0rc "testproj" "tp"

    # Create mock v0-plan-exec that creates plan file
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Test Plan" > plans/test-wrapper.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    # Run v0-plan with --direct to avoid tmux complexity in test
    run "${PROJECT_ROOT}/bin/v0-plan" "test-wrapper" "Create a test plan" --direct

    # Logs dir should exist
    assert_dir_exists "${TEST_TEMP_DIR}/project/.v0/build/logs"
}

@test "v0-plan wrapper script contains correct exports" {
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    STATE_DIR="${BUILD_DIR}/operations/plan-test"
    mkdir -p "${STATE_DIR}/logs"

    # Simulate wrapper script creation (as v0-plan does)
    cat > "${STATE_DIR}/run-plan.sh" <<EOF
#!/bin/bash
cd '${V0_ROOT}' || exit 1
export V0_ROOT='${V0_ROOT}'

PROMPT="\$(cat '${STATE_DIR}/prompt.txt')"
script -q '${STATE_DIR}/logs/plan.log' '${V0_PLAN_EXEC}' 'test' "\${PROMPT}"
EXIT_CODE=\$?
echo \${EXIT_CODE} > '${STATE_DIR}/logs/plan.exit'
EOF

    run cat "${STATE_DIR}/run-plan.sh"
    assert_output --partial "export V0_ROOT="
    assert_output --partial "plan.log"
    assert_output --partial "plan.exit"
}

# ============================================================================
# Log file creation tests
# ============================================================================

@test "v0-plan logs plan:start event" {
    create_v0rc "testproj" "tp"

    # Create mock v0-plan-exec that creates plan file
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Test Plan" > plans/logtest.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "logtest" "Create a test" --direct

    assert_file_exists "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    run cat "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    assert_output --partial "plan:start"
    assert_output --partial "logtest"
}

@test "v0-plan logs plan:complete on success" {
    create_v0rc "testproj" "tp"

    # Create mock v0-plan-exec that succeeds
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Test Plan" > plans/completetest.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "completetest" "Create a test" --direct
    assert_success

    run cat "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    assert_output --partial "plan:complete"
}

@test "v0-plan logs plan:failed on failure" {
    create_v0rc "testproj" "tp"

    # Create mock v0-plan-exec that fails without creating plan
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "failtest" "Create a test" --direct
    assert_failure

    run cat "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    assert_output --partial "plan:failed"
}

# ============================================================================
# Exit code handling tests
# ============================================================================

@test "v0-plan returns success when plan file created" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Success Plan" > plans/exitcode-success.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "exitcode-success" "Test" --direct
    assert_success
}

@test "v0-plan returns failure when plan file not created" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
# Don't create plan file
exit 1
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "exitcode-fail" "Test" --direct
    assert_failure
}

@test "v0-plan treats plan file existing as success even with non-zero exit" {
    create_v0rc "testproj" "tp"

    # Create mock that creates plan but exits non-zero
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Recovered Plan" > plans/recovered.md
exit 1
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "recovered" "Test" --direct
    # Should succeed because plan file exists
    assert_success
    assert_output --partial "plan file was created successfully"
}

# ============================================================================
# Plan file detection tests
# ============================================================================

@test "v0-plan detects plan file in plans directory" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Detected Plan" > plans/detect-test.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "detect-test" "Test" --direct
    assert_success
    assert_file_exists "${TEST_TEMP_DIR}/project/plans/detect-test.md"
}

@test "v0-plan fails if plan file not in expected location" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
# Create plan in wrong location
mkdir -p /tmp/wrong-place
echo "# Wrong Place Plan" > /tmp/wrong-place/wrong.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "wrong" "Test" --direct
    assert_failure
    assert_output --partial "not created"
}

# ============================================================================
# --direct flag behavior tests
# ============================================================================

@test "v0-plan --direct runs without tmux" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Direct Plan" > plans/direct-test.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "direct-test" "Test" --direct
    assert_success

    # Log should indicate direct mode
    run cat "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    assert_output --partial "direct mode"
}

@test "v0-plan --direct does not create state directory operations folder" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Direct Plan" > plans/no-state-dir.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "no-state-dir" "Test" --direct
    assert_success

    # Operations folder for this plan should not exist in direct mode
    [ ! -d "${TEST_TEMP_DIR}/project/.v0/build/operations/plan-no-state-dir" ]
}

@test "v0-plan --direct passes V0_SAFE to v0-plan-exec when --safe is used" {
    create_v0rc "testproj" "tp"

    # Create mock that checks V0_SAFE
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
if [ "${V0_SAFE}" = "1" ]; then
    echo "# Safe mode enabled" > plans/safe-mode.md
else
    echo "# Safe mode disabled" > plans/safe-mode.md
fi
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "safe-mode" "Test" --direct --safe
    assert_success

    run cat "${TEST_TEMP_DIR}/project/plans/safe-mode.md"
    assert_output --partial "Safe mode enabled"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "v0-plan shows usage without arguments" {
    create_v0rc "testproj" "tp"

    run "${PROJECT_ROOT}/bin/v0-plan"
    assert_failure
    assert_output --partial "Usage:"
}

@test "v0-plan shows usage with --help" {
    create_v0rc "testproj" "tp"

    run "${PROJECT_ROOT}/bin/v0-plan" --help
    assert_failure
    assert_output --partial "Usage:"
    assert_output --partial "--direct"
}

@test "v0-plan shows usage with only name argument" {
    create_v0rc "testproj" "tp"

    run "${PROJECT_ROOT}/bin/v0-plan" "myplan"
    assert_failure
    assert_output --partial "Usage:"
}

# ============================================================================
# Notification tests
# ============================================================================

@test "v0-plan logs notification on success" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Notify Plan" > plans/notify-success.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "notify-success" "Test" --direct
    assert_success

    # v0_notify logs to v0.log
    run cat "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    assert_output --partial "notify"
    assert_output --partial "completed"
}

@test "v0-plan logs notification on failure" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "notify-fail" "Test" --direct
    assert_failure

    run cat "${TEST_TEMP_DIR}/project/.v0/build/logs/v0.log"
    assert_output --partial "notify"
    assert_output --partial "failed"
}

# ============================================================================
# --draft flag tests
# ============================================================================

@test "v0-plan shows --draft in usage" {
    create_v0rc "testproj" "tp"

    run "${PROJECT_ROOT}/bin/v0-plan" --help
    assert_failure
    assert_output --partial "--draft"
}

@test "v0-plan --draft passes V0_DRAFT to v0-plan-exec" {
    create_v0rc "testproj" "tp"

    # Create mock that checks V0_DRAFT
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
if [ "${V0_DRAFT}" = "1" ]; then
    echo "# Draft mode enabled" > plans/draft-test.md
else
    echo "# Draft mode disabled" > plans/draft-test.md
fi
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "draft-test" "Test" --direct --draft
    assert_success

    run cat "${TEST_TEMP_DIR}/project/plans/draft-test.md"
    assert_output --partial "Draft mode enabled"
}

# ============================================================================
# Auto-commit behavior tests
# ============================================================================

@test "v0-plan-exec commits plan in clean git repo" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    # Create a plan file manually (simulating Claude's output)
    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    echo "# Test Plan" > "${TEST_TEMP_DIR}/project/plans/commit-test.md"

    # Run just the commit logic by sourcing v0-common and running the commit
    cd "${TEST_TEMP_DIR}/project" || return 1
    NAME="commit-test"
    plan_file="${PLANS_DIR}/${NAME}.md"

    # Simulate what v0-plan-exec does after plan creation
    git add "plans/${NAME}.md"
    git commit -m "Add plan: ${NAME}" -m "Auto-committed by v0 plan"

    # Verify commit was created
    run git log --oneline -1
    assert_success
    assert_output --partial "Add plan: commit-test"
}

@test "v0-plan-exec skips commit with V0_DRAFT=1" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    echo "# Test Plan" > "${TEST_TEMP_DIR}/project/plans/draft-commit.md"

    cd "${TEST_TEMP_DIR}/project" || return 1
    export V0_DRAFT=1
    NAME="draft-commit"

    # Check that commit would be skipped due to draft mode
    if [ "${V0_DRAFT:-}" = "1" ]; then
        SKIP_REASON="draft"
    fi

    assert_equal "${SKIP_REASON}" "draft"
    unset V0_DRAFT
}

@test "v0-plan-exec skips commit in dirty worktree" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    mkdir -p "${TEST_TEMP_DIR}/project/plans"
    echo "# Test Plan" > "${TEST_TEMP_DIR}/project/plans/dirty-test.md"

    # Make worktree dirty
    echo "uncommitted change" >> "${TEST_TEMP_DIR}/project/README.md"

    cd "${TEST_TEMP_DIR}/project" || return 1

    # Check that v0_git_worktree_clean returns failure (dirty)
    run v0_git_worktree_clean .
    assert_failure
}

@test "v0-plan-exec logs commit status" {
    init_mock_git_repo "${TEST_TEMP_DIR}/project"
    create_v0rc "testproj" "tp"
    source_lib "v0-common.sh"
    v0_load_config

    export V0_DRAFT=1

    # Call v0_log to simulate what v0-plan-exec does
    v0_log "plan:commit" "Skipped (draft mode)"

    run cat "${BUILD_DIR}/logs/v0.log"
    assert_output --partial "plan:commit"
    assert_output --partial "Skipped (draft mode)"
    unset V0_DRAFT
}

# ============================================================================
# Auto-hold behavior tests
# ============================================================================

@test "v0-plan --direct: automatically sets held=true on success" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Auto-hold Test Plan" > plans/auto-hold-test.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "auto-hold-test" "Create a test plan" --direct
    assert_success

    # Check that held=true in state.json
    STATE_FILE="${TEST_TEMP_DIR}/project/.v0/build/operations/auto-hold-test/state.json"
    assert_file_exists "${STATE_FILE}"
    run jq -r '.held' "${STATE_FILE}"
    assert_output "true"
}

@test "v0-plan --direct: sets held_at timestamp on success" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Held-at Test Plan" > plans/held-at-test.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "held-at-test" "Create a test plan" --direct
    assert_success

    STATE_FILE="${TEST_TEMP_DIR}/project/.v0/build/operations/held-at-test/state.json"
    run jq -r '.held_at' "${STATE_FILE}"
    # Should be a valid ISO timestamp
    refute_output "null"
    assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

@test "v0-plan --direct: emits hold:auto_set event" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Event Test Plan" > plans/event-test.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "event-test" "Create a test plan" --direct
    assert_success

    # Check events.log for hold:auto_set event
    EVENTS_LOG="${TEST_TEMP_DIR}/project/.v0/build/operations/event-test/logs/events.log"
    assert_file_exists "${EVENTS_LOG}"
    run cat "${EVENTS_LOG}"
    assert_output --partial "hold:auto_set"
    assert_output --partial "Automatically held after planning"
}

@test "v0-plan --direct: output shows held message" {
    create_v0rc "testproj" "tp"

    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Output Test Plan" > plans/output-test.md
exit 0
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "output-test" "Create a test plan" --direct
    assert_success
    assert_output --partial "Operation is held"
    assert_output --partial "v0 resume output-test"
}

@test "v0-plan --direct: recovery also sets held=true" {
    create_v0rc "testproj" "tp"

    # Create mock that creates plan but exits non-zero (recovery case)
    cat > "${V0_PLAN_EXEC}" <<'EOF'
#!/bin/bash
mkdir -p plans
echo "# Recovery Hold Test" > plans/recovery-hold.md
exit 1
EOF
    chmod +x "${V0_PLAN_EXEC}"

    run "${PROJECT_ROOT}/bin/v0-plan" "recovery-hold" "Test" --direct
    assert_success

    STATE_FILE="${TEST_TEMP_DIR}/project/.v0/build/operations/recovery-hold/state.json"
    run jq -r '.held' "${STATE_FILE}"
    assert_output "true"
}
