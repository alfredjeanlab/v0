#!/usr/bin/env bats
# Tests for v0-coffee - Keep computer awake (caffeinate wrapper)
load '../helpers/test_helper'

# Track PIDs of caffeinate processes we start
_COFFEE_PIDS=()

# Custom teardown to ensure caffeinate processes are cleaned up
teardown() {
    # Kill any caffeinate processes we started
    for pid in "${_COFFEE_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    _COFFEE_PIDS=()

    # Also clean up via the normal coffee stop mechanism
    if [[ -n "${V0_STATE_DIR:-}" ]] && [[ -f "${V0_STATE_DIR}/.coffee.pid" ]]; then
        local pid
        pid=$(cat "${V0_STATE_DIR}/.coffee.pid" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "${V0_STATE_DIR}/.coffee.pid"
    fi

    # Call parent teardown
    export HOME="$REAL_HOME"
    export PATH="$ORIGINAL_PATH"
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testcoffee"
ISSUE_PREFIX="tc"
EOF
    echo "${isolated_dir}/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "coffee shows usage with --help" {
    run "${PROJECT_ROOT}/bin/v0-coffee" --help
    assert_success
    assert_output --partial "Usage: v0 coffee"
    assert_output --partial "Keep the computer awake"
}

@test "coffee shows usage with -h" {
    run "${PROJECT_ROOT}/bin/v0-coffee" -h
    assert_success
    assert_output --partial "Usage: v0 coffee"
}

# ============================================================================
# Subcommand tests
# ============================================================================

@test "coffee start creates PID file" {
    # Skip on non-macOS (caffeinate is macOS-only)
    [[ "$(uname)" == "Darwin" ]] || skip "caffeinate requires macOS"

    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    # Start coffee with very short duration
    run "${PROJECT_ROOT}/bin/v0-coffee" start 0.001
    assert_success
    assert_output --partial "Coffee started"

    # Verify PID file exists
    assert_file_exists "${project_dir}/.v0/.coffee.pid"

    # Clean up
    "${PROJECT_ROOT}/bin/v0-coffee" stop
}

@test "coffee start when already running is idempotent" {
    # Skip on non-macOS (caffeinate is macOS-only)
    [[ "$(uname)" == "Darwin" ]] || skip "caffeinate requires macOS"

    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"

    # Export V0_STATE_DIR for this test
    export V0_STATE_DIR="${project_dir}/.v0"

    # First start - use very short duration
    run "${PROJECT_ROOT}/bin/v0-coffee" start 0.1
    assert_success
    assert_output --partial "Coffee started"

    # Second start - should say already running
    run "${PROJECT_ROOT}/bin/v0-coffee" start 0.1
    assert_success
    assert_output --partial "Coffee already running"

    # Clean up
    "${PROJECT_ROOT}/bin/v0-coffee" stop
}

@test "coffee stop terminates process and removes PID file" {
    # Skip on non-macOS (caffeinate is macOS-only)
    [[ "$(uname)" == "Darwin" ]] || skip "caffeinate requires macOS"

    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    # Start coffee first
    run "${PROJECT_ROOT}/bin/v0-coffee" start 0.1
    assert_success

    # Stop coffee
    run "${PROJECT_ROOT}/bin/v0-coffee" stop
    assert_success
    assert_output --partial "Coffee stopped"

    # Verify PID file removed
    assert_file_not_exists "${project_dir}/.v0/.coffee.pid"
}

@test "coffee stop when not running is safe" {
    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    run "${PROJECT_ROOT}/bin/v0-coffee" stop
    assert_success
    assert_output --partial "Coffee is not running"
}

@test "coffee status returns correct status when running" {
    # Skip on non-macOS (caffeinate is macOS-only)
    [[ "$(uname)" == "Darwin" ]] || skip "caffeinate requires macOS"

    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    # Start coffee
    run "${PROJECT_ROOT}/bin/v0-coffee" start 0.1
    assert_success

    # Check status
    run "${PROJECT_ROOT}/bin/v0-coffee" status
    assert_success
    assert_output --partial "Coffee is running"

    # Clean up
    "${PROJECT_ROOT}/bin/v0-coffee" stop
}

@test "coffee status returns failure when not running" {
    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    run "${PROJECT_ROOT}/bin/v0-coffee" status
    assert_failure
    assert_output --partial "Coffee is not running"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 coffee command is routed correctly" {
    run "${PROJECT_ROOT}/bin/v0" coffee --help
    assert_success
    assert_output --partial "Usage: v0 coffee"
}

@test "v0 --help shows coffee command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "coffee"
    assert_output --partial "Keep computer awake"
}

# ============================================================================
# coffee-common.sh library tests
# ============================================================================

@test "coffee_is_running returns false when no PID file" {
    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    source "${PROJECT_ROOT}/lib/coffee-common.sh"
    if coffee_is_running; then
        run echo "running"
    else
        run echo "not running"
    fi
    assert_output "not running"
}

@test "coffee_status outputs correct format" {
    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    source "${PROJECT_ROOT}/lib/coffee-common.sh"
    run coffee_status
    assert_output "stopped"
}

@test "coffee_start and coffee_pid work together" {
    # Skip on non-macOS (caffeinate is macOS-only)
    [[ "$(uname)" == "Darwin" ]] || skip "caffeinate requires macOS"

    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    source "${PROJECT_ROOT}/lib/coffee-common.sh"
    coffee_start 0.01
    local pid
    pid=$(coffee_pid)
    if [[ -n "${pid}" ]] && [[ "${pid}" =~ ^[0-9]+$ ]]; then
        run echo "valid pid"
    else
        run echo "invalid pid: ${pid}"
    fi
    coffee_stop
    assert_output "valid pid"
}

# ============================================================================
# Environment variable tests
# ============================================================================

@test "coffee start respects V0_COFFEE_HOURS" {
    # Skip on non-macOS (caffeinate is macOS-only)
    [[ "$(uname)" == "Darwin" ]] || skip "caffeinate requires macOS"

    local project_dir
    project_dir=$(setup_isolated_project)
    mkdir -p "${project_dir}/.v0"
    export V0_STATE_DIR="${project_dir}/.v0"

    # Use very short duration to avoid hanging test
    export V0_COFFEE_HOURS=0.001
    run "${PROJECT_ROOT}/bin/v0-coffee" start
    assert_success
    assert_output --partial "duration: 0.001h"

    # Clean up
    "${PROJECT_ROOT}/bin/v0-coffee" stop
}
