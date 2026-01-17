#!/usr/bin/env bats
# v0-cancel.bats - Tests for v0-cancel script

load '../helpers/test_helper'

# Path to the script under test
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

@test "v0-cancel: --help shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" --help
    '
    assert_success
    assert_output --partial "Usage: v0 cancel"
    assert_output --partial "Cancel one or more running operations"
}

@test "v0-cancel: -h shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" -h
    '
    assert_success
    assert_output --partial "Usage: v0 cancel"
}

@test "v0-cancel: unknown option shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option: --unknown"
}

# ============================================================================
# Argument Parsing Tests
# ============================================================================

@test "v0-cancel: requires operation name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'"
    '
    assert_failure
    assert_output --partial "Error: Operation name required"
}

@test "v0-cancel: operation not found shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" nonexistent
    '
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
    assert_output --partial "List operations with: v0 status"
}

# ============================================================================
# Operation Cancellation Tests
# ============================================================================

@test "v0-cancel: cancels operation and updates state" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "othermachine"}'

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
    assert_output --partial "Cancelled operation 'testop'"

    # Verify state was updated
    run jq -r '.phase' "${project_dir}/.v0/build/operations/testop/state.json"
    assert_output "cancelled"
}

@test "v0-cancel: already cancelled operation is no-op" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "cancelled", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop
    '
    assert_success
    assert_output --partial "already cancelled"
}

@test "v0-cancel: merged operation cannot be cancelled" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop
    '
    assert_failure
    assert_output --partial "already merged"
    assert_output --partial "v0 prune"
}

@test "v0-cancel: never prompts for confirmation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    # Even with TTY, cancel should not prompt for confirmation
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop
    '
    assert_success
    assert_output --partial "Cancelled operation 'testop'"
    # Should not contain any prompt text
    refute_output --partial "[y/N]"
}

@test "v0-cancel: logs cancellation event" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop
    '
    assert_success

    # Verify event was logged
    run cat "${project_dir}/.v0/build/operations/testop/logs/events.log"
    assert_output --partial "cancelled"
}

@test "v0-cancel: shows cleanup instructions after cancellation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop
    '
    assert_success
    assert_output --partial "v0 prune"
}

# ============================================================================
# v0 Command Integration Tests
# ============================================================================

@test "v0 cancel command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" cancel --help
    '
    assert_success
    assert_output --partial "Usage: v0 cancel"
}

@test "v0 --help shows cancel command" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" --help
    '
    assert_success
    assert_output --partial "cancel"
}

# ============================================================================
# Multiple Operations Tests
# ============================================================================

@test "v0-cancel: cancels multiple operations in bulk" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop1" '{"name": "testop1", "phase": "executing", "machine": "othermachine"}'
    create_isolated_operation "${project_dir}" "testop2" '{"name": "testop2", "phase": "planning", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" testop1 testop2
    '
    assert_success
    assert_output --partial "Cancelled operation 'testop1'"
    assert_output --partial "Cancelled operation 'testop2'"

    # Verify both states were updated
    run jq -r '.phase' "${project_dir}/.v0/build/operations/testop1/state.json"
    assert_output "cancelled"
    run jq -r '.phase' "${project_dir}/.v0/build/operations/testop2/state.json"
    assert_output "cancelled"
}

@test "v0-cancel: continues after nonexistent operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop2" '{"name": "testop2", "phase": "executing", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" nonexistent testop2
    '
    # Should fail because one operation failed
    assert_failure
    assert_output --partial "No operation found for 'nonexistent'"
    assert_output --partial "Cancelled operation 'testop2'"

    # Verify testop2 was still cancelled
    run jq -r '.phase' "${project_dir}/.v0/build/operations/testop2/state.json"
    assert_output "cancelled"
}

@test "v0-cancel: continues after merged operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "merged-op" '{"name": "merged-op", "phase": "merged", "machine": "othermachine"}'
    create_isolated_operation "${project_dir}" "active-op" '{"name": "active-op", "phase": "executing", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" merged-op active-op
    '
    # Should fail because merged operation failed
    assert_failure
    assert_output --partial "already merged"
    assert_output --partial "Cancelled operation 'active-op'"

    # Verify active-op was still cancelled
    run jq -r '.phase' "${project_dir}/.v0/build/operations/active-op/state.json"
    assert_output "cancelled"
}

@test "v0-cancel: skips already cancelled operations" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "cancelled-op" '{"name": "cancelled-op", "phase": "cancelled", "machine": "othermachine"}'
    create_isolated_operation "${project_dir}" "active-op" '{"name": "active-op", "phase": "executing", "machine": "othermachine"}'

    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "${mock_dir}"

    cat > "${mock_dir}/hostname" <<'EOF'
#!/bin/bash
echo "localmachine"
EOF
    chmod +x "${mock_dir}/hostname"

    cat > "${mock_dir}/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${mock_dir}/tmux"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR PATH="${mock_dir}:${PATH}" bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_CANCEL}"'" cancelled-op active-op
    '
    # Should succeed - already cancelled is not a failure
    assert_success
    assert_output --partial "already cancelled"
    assert_output --partial "Cancelled operation 'active-op'"
}
