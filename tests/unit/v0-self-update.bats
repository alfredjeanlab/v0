#!/usr/bin/env bats
# Tests for v0-self-update - Update v0 to different versions/channels
load '../helpers/test_helper'

# ============================================================================
# Help and usage tests
# ============================================================================

@test "v0 self update --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0-self-update" --help
    assert_success
    assert_output --partial "Update v0 installation"
    assert_output --partial "stable"
    assert_output --partial "nightly"
}

@test "v0 self update -h shows usage" {
    run "${PROJECT_ROOT}/bin/v0-self-update" -h
    assert_success
    assert_output --partial "Update v0 installation"
}

@test "v0 self update routed from main command" {
    run "${PROJECT_ROOT}/bin/v0" self update --help
    assert_success
    assert_output --partial "Update v0 installation"
}

# ============================================================================
# update-common.sh library tests
# ============================================================================

@test "get_install_method returns known value" {
    # Source the common library with V0_DIR set
    export V0_DIR="${PROJECT_ROOT}"
    source "${PROJECT_ROOT}/lib/update-common.sh"

    run get_install_method
    assert_success
    # Should be one of: homebrew, direct, unknown
    [[ "${output}" == "homebrew" ]] || \
    [[ "${output}" == "direct" ]] || \
    [[ "${output}" == "unknown" ]]
}

@test "get_current_version reads VERSION file" {
    export V0_DIR="${PROJECT_ROOT}"
    source "${PROJECT_ROOT}/lib/update-common.sh"

    run get_current_version
    assert_success
    # Should return a version string (not empty, not "unknown" if VERSION exists)
    [[ -n "${output}" ]]
}

@test "get_current_channel returns stable by default" {
    export V0_DIR="${TEST_TEMP_DIR}"
    mkdir -p "${TEST_TEMP_DIR}"
    source "${PROJECT_ROOT}/lib/update-common.sh"

    run get_current_channel
    assert_success
    assert_output "stable"
}

@test "get_current_channel reads .channel file when present" {
    export V0_DIR="${TEST_TEMP_DIR}"
    mkdir -p "${TEST_TEMP_DIR}"
    echo "nightly" > "${TEST_TEMP_DIR}/.channel"
    source "${PROJECT_ROOT}/lib/update-common.sh"

    run get_current_channel
    assert_success
    assert_output "nightly"
}

@test "set_current_channel writes .channel file" {
    export V0_DIR="${TEST_TEMP_DIR}"
    mkdir -p "${TEST_TEMP_DIR}"
    source "${PROJECT_ROOT}/lib/update-common.sh"

    set_current_channel "nightly"
    run cat "${TEST_TEMP_DIR}/.channel"
    assert_success
    assert_output "nightly"
}

# ============================================================================
# Version check tests (require network)
# ============================================================================

# bats test_tags=network
@test "v0 self update --check shows version info" {
    run "${PROJECT_ROOT}/bin/v0-self-update" --check
    assert_success
    assert_output --partial "Current version:"
    assert_output --partial "Current channel:"
}

# bats test_tags=network
@test "v0 self update --list shows available versions" {
    run "${PROJECT_ROOT}/bin/v0-self-update" --list
    assert_success
    assert_output --partial "Stable releases:"
}

# ============================================================================
# v0-self-version tests
# ============================================================================

@test "v0 self version shows version info" {
    run "${PROJECT_ROOT}/bin/v0-self-version"
    assert_success
    assert_output --partial "v0 version"
    assert_output --partial "Channel:"
    assert_output --partial "Install:"
    assert_output --partial "Path:"
}

@test "v0 self version --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0-self-version" --help
    assert_success
    assert_output --partial "Show version information"
}

@test "v0 self version routed from main command" {
    run "${PROJECT_ROOT}/bin/v0" self version
    assert_success
    assert_output --partial "v0 version"
}

# ============================================================================
# v0-self dispatcher tests
# ============================================================================

@test "v0 self shows help with no arguments" {
    run "${PROJECT_ROOT}/bin/v0-self"
    assert_success
    assert_output --partial "Self-management commands"
    assert_output --partial "update"
    assert_output --partial "version"
    assert_output --partial "debug"
}

@test "v0 self --help shows help" {
    run "${PROJECT_ROOT}/bin/v0-self" --help
    assert_success
    assert_output --partial "Self-management commands"
}

@test "v0 self unknown-command shows error" {
    run "${PROJECT_ROOT}/bin/v0-self" unknown-command
    assert_failure
    assert_output --partial "Unknown self command"
}

# ============================================================================
# Main v0 integration tests
# ============================================================================

@test "v0 --version reads from VERSION file" {
    run "${PROJECT_ROOT}/bin/v0" --version
    assert_success
    # Should show actual version from VERSION file, not hardcoded
    assert_output --partial "v0 "
}

@test "v0 --help mentions self update" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "self"
    assert_output --partial "update"
}
