#!/usr/bin/env bats
# v0-hold.bats - Tests for v0-hold script

load '../helpers/test_helper'

# Path to the script under test
V0_HOLD="${PROJECT_ROOT}/bin/v0-hold"
V0_CANCEL="${PROJECT_ROOT}/bin/v0-cancel"

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
EOF
    echo "${isolated_dir}/project"
}

# Helper to create operation state in isolated project
create_isolated_operation() {
    local project_dir="$1"
    local op_name="$2"
    local json_content="$3"
    local op_dir="${project_dir}/.v0/build/operations/${op_name}"
    mkdir -p "${op_dir}"
    echo "${json_content}" > "${op_dir}/state.json"
}

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR
    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"
    export V0_TEST_MODE=1
    export V0_NO_NOTIFICATIONS=1
    export ORIGINAL_PATH="${PATH}"
    export PATH="${TESTS_DIR}/helpers/mock-bin:${PATH}"
    mkdir -p "${TEST_TEMP_DIR}/mock-v0-bin"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"
    if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-hold: --help shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" --help
    '
    assert_success
    assert_output --partial "Usage: v0 hold"
    assert_output --partial "Put an operation on hold"
}

@test "v0-hold: -h shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" -h
    '
    assert_success
    assert_output --partial "Usage: v0 hold"
}

@test "v0-hold: unknown option shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option: --unknown"
}

# ============================================================================
# Argument Parsing Tests
# ============================================================================

@test "v0-hold: requires operation name without --status" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'"
    '
    assert_failure
    assert_output --partial "Error: Operation name required"
}

@test "v0-hold: operation not found shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" nonexistent
    '
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
}

# ============================================================================
# Hold Setting Tests
# ============================================================================

@test "v0-hold: sets held flag on operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" testop
    '
    assert_success
    assert_output --partial "on hold"

    # Verify state was updated
    run jq -r '.held' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "true"
}

@test "v0-hold: sets held_at timestamp" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" testop
    '
    assert_success

    # Verify held_at was set
    run jq -r '.held_at' "${project_dir}/.v0/build/operations/testop/state.json"
    refute_output "null"
    # Should be a timestamp in ISO format
    assert_output --regexp "^[0-9]{4}-[0-9]{2}-[0-9]{2}T"
}

@test "v0-hold: already held operation is no-op" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": true, "held_at": "2026-01-15T10:00:00Z"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" testop
    '
    assert_success
    assert_output --partial "already on hold"
}

@test "v0-hold: logs hold event" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" testop
    '
    assert_success

    # Verify event was logged
    run cat "${project_dir}/.v0/build/operations/testop/logs/events.log"
    assert_output --partial "hold:set"
}

# ============================================================================
# Status Display Tests
# ============================================================================

@test "v0-hold --status: shows held operations" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": true, "held_at": "2026-01-15T10:00:00Z"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" --status
    '
    assert_success
    assert_output --partial "testop"
    assert_output --partial "2026-01-15"
}

@test "v0-hold --status: shows 'no operations' when none held" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": false}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" --status
    '
    assert_success
    assert_output --partial "no operations on hold"
}

@test "v0-hold --status <name>: shows held status for specific operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": true, "held_at": "2026-01-15T10:00:00Z"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" --status testop
    '
    assert_success
    assert_output --partial "is on hold"
}

@test "v0-hold --status <name>: shows not held for non-held operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": false}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_HOLD}"'" --status testop
    '
    assert_success
    assert_output --partial "not on hold"
}

# ============================================================================
# v0 Command Integration Tests
# ============================================================================

@test "v0 hold command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" hold --help
    '
    assert_success
    assert_output --partial "Usage: v0 hold"
}

@test "v0 --help shows hold command" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" --help
    '
    assert_success
    assert_output --partial "hold"
}

# ============================================================================
# Hold Clearing Tests (v0 cancel clears hold)
# ============================================================================

@test "v0-cancel: clears hold when cancelling" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "othermachine", "held": true, "held_at": "2026-01-15T10:00:00Z"}'

    # Create mock bin directory with mocks
    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1  # No session exists
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop
    '
    assert_success

    # Verify held was cleared
    run jq -r '.held' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "false"

    run jq -r '.held_at' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "null"
}

# ============================================================================
# Helper Function Tests
# ============================================================================

@test "sm_is_held: returns false for non-held operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": false}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        if sm_is_held testop; then
            echo "held"
        else
            echo "not held"
        fi
    '
    assert_success
    assert_output "not held"
}

@test "sm_is_held: returns true for held operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": true, "held_at": "2026-01-15T10:00:00Z"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        if sm_is_held testop; then
            echo "held"
        else
            echo "not held"
        fi
    '
    assert_success
    assert_output "held"
}

@test "sm_is_held: returns false for non-existent operation" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        if sm_is_held nonexistent; then
            echo "held"
        else
            echo "not held"
        fi
    '
    assert_success
    assert_output "not held"
}

@test "sm_exit_if_held: exits with message for held operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": true, "held_at": "2026-01-15T10:00:00Z"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        sm_exit_if_held testop feature
        echo "should not reach here"
    '
    assert_success
    assert_output --partial "is on hold"
    assert_output --partial "v0 resume"
    refute_output --partial "should not reach here"
}

@test "sm_exit_if_held: continues for non-held operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine", "held": false}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        source "'"${PROJECT_ROOT}"'/lib/v0-common.sh"
        v0_load_config
        sm_exit_if_held testop feature
        echo "continued"
    '
    assert_success
    assert_output "continued"
}

# ============================================================================
# Blocked + Held Resume Tests
# ============================================================================

@test "v0-feature --resume: blocked and held operation only clears hold (blocker merged)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a blocker operation that has merged
    create_isolated_operation "${project_dir}" "blocker" '{"name": "blocker", "phase": "merged", "machine": "testmachine"}'

    # Create a blocked + held operation
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "blocked", "machine": "testmachine", "after": "blocker", "blocked_phase": "init", "held": true, "held_at": "2026-01-15T10:00:00Z", "prompt": "test prompt"}'
    mkdir -p "${project_dir}/.v0/build/operations/testop/logs"

    # Create mock bins
    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1  # No session exists
EOF
    chmod +x "${mock_dir}/tmux"

    # Run resume
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-feature" testop --resume
    '
    assert_success
    assert_output --partial "Clearing hold"
    assert_output --partial "Hold cleared"
    assert_output --partial "ready at phase: init"
    assert_output --partial "v0 feature testop --resume"

    # Verify hold was cleared
    run jq -r '.held' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "false"

    # Verify phase was updated to the blocked_phase
    run jq -r '.phase' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "init"

    # Verify after was cleared (unblocked)
    run jq -r '.after' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "null"
}

@test "v0-feature --resume: blocked and held operation only clears hold (blocker deleted)" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # No blocker operation exists (deleted)

    # Create a blocked + held operation pointing to non-existent blocker
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "blocked", "machine": "testmachine", "after": "deleted-op", "blocked_phase": "queued", "held": true, "held_at": "2026-01-15T10:00:00Z", "prompt": "test prompt"}'
    mkdir -p "${project_dir}/.v0/build/operations/testop/logs"

    # Create mock bins
    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1  # No session exists
EOF
    chmod +x "${mock_dir}/tmux"

    # Run resume
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-feature" testop --resume
    '
    assert_success
    assert_output --partial "Clearing hold"
    assert_output --partial "Hold cleared"
    assert_output --partial "ready at phase: queued"

    # Verify hold was cleared
    run jq -r '.held' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "false"

    # Verify phase was updated
    run jq -r '.phase' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "queued"
}

@test "v0-feature --resume: blocked but not held operation proceeds normally" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create a blocker operation that has merged
    create_isolated_operation "${project_dir}" "blocker" '{"name": "blocker", "phase": "merged", "machine": "testmachine"}'

    # Create a blocked (but not held) operation
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "blocked", "machine": "testmachine", "after": "blocker", "blocked_phase": "init", "held": false, "prompt": "test prompt"}'
    mkdir -p "${project_dir}/.v0/build/operations/testop/logs"

    # Create mock bins
    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1  # No session exists
EOF
    chmod +x "${mock_dir}/tmux"

    # Run resume with --dry-run to avoid actually starting
    # Note: This will fail at plan file check, but we verify it proceeded past the blocked state
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0-feature" testop --resume --dry-run
    '
    # Command will fail because no plan file exists, but that's OK - we're checking it proceeded
    # Should proceed past blocked state (not exit early like held operations)
    assert_output --partial "has merged, proceeding"
    # Should NOT show the "Hold cleared" message (because it wasn't held)
    refute_output --partial "Hold cleared"
    # Should show it attempted to continue with the next phase
    assert_output --partial "plan:starting"
}
