#!/usr/bin/env bats
# Tests for standalone mode functionality

load '../../test-support/helpers/test_helper'

# ============================================================================
# V0_STANDALONE_DIR constant tests
# ============================================================================

@test "V0_STANDALONE_DIR is set after sourcing v0-common.sh" {
    source_lib "v0-common.sh"

    assert [ -n "$V0_STANDALONE_DIR" ]
    # Should follow XDG spec
    [[ "$V0_STANDALONE_DIR" == *"/.local/state/v0/standalone" ]]
}

@test "V0_STANDALONE_DIR respects XDG_STATE_HOME when set" {
    export XDG_STATE_HOME="/custom/state"
    source_lib "v0-common.sh"

    assert_equal "$V0_STANDALONE_DIR" "/custom/state/v0/standalone"
}

# ============================================================================
# v0_init_standalone() tests
# ============================================================================

@test "v0_init_standalone creates directory structure" {
    source_lib "v0-common.sh"
    # Override to use test directory
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"

    # Mock wk init to just create config.toml
    wk() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "${V0_STANDALONE_DIR}/.wok"
            echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"
            return 0
        fi
        command wk "$@"
    }
    export -f wk

    v0_init_standalone

    # Verify directory structure
    assert [ -d "${V0_STANDALONE_DIR}/build/chore" ]
    assert [ -d "${V0_STANDALONE_DIR}/logs" ]
    assert [ -f "${V0_STANDALONE_DIR}/.wok/config.toml" ]
}

@test "v0_init_standalone is idempotent" {
    source_lib "v0-common.sh"
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"

    # Create the structure first
    mkdir -p "${V0_STANDALONE_DIR}/build/chore"
    mkdir -p "${V0_STANDALONE_DIR}/logs"
    mkdir -p "${V0_STANDALONE_DIR}/.wok"
    echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"

    # Should not error when called again
    run v0_init_standalone
    assert_success
}

# ============================================================================
# v0_load_standalone_config() tests
# ============================================================================

@test "v0_load_standalone_config sets V0_STANDALONE=1" {
    source_lib "v0-common.sh"
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"

    # Mock wk init
    wk() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "${V0_STANDALONE_DIR}/.wok"
            echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"
            return 0
        fi
        command wk "$@"
    }
    export -f wk

    v0_load_standalone_config

    assert_equal "$V0_STANDALONE" "1"
}

@test "v0_load_standalone_config sets PROJECT to standalone" {
    source_lib "v0-common.sh"
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"

    wk() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "${V0_STANDALONE_DIR}/.wok"
            echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"
            return 0
        fi
        command wk "$@"
    }
    export -f wk

    v0_load_standalone_config

    assert_equal "$PROJECT" "standalone"
}

@test "v0_load_standalone_config sets ISSUE_PREFIX to chore" {
    source_lib "v0-common.sh"
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"

    wk() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "${V0_STANDALONE_DIR}/.wok"
            echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"
            return 0
        fi
        command wk "$@"
    }
    export -f wk

    v0_load_standalone_config

    assert_equal "$ISSUE_PREFIX" "chore"
}

@test "v0_load_standalone_config sets BUILD_DIR to standalone build path" {
    source_lib "v0-common.sh"
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"

    wk() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "${V0_STANDALONE_DIR}/.wok"
            echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"
            return 0
        fi
        command wk "$@"
    }
    export -f wk

    v0_load_standalone_config

    assert_equal "$BUILD_DIR" "${V0_STANDALONE_DIR}/build"
}

@test "v0_load_standalone_config clears V0_ROOT" {
    source_lib "v0-common.sh"
    V0_STANDALONE_DIR="${TEST_TEMP_DIR}/standalone"
    V0_ROOT="/some/previous/root"

    wk() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "${V0_STANDALONE_DIR}/.wok"
            echo 'prefix = "chore"' > "${V0_STANDALONE_DIR}/.wok/config.toml"
            return 0
        fi
        command wk "$@"
    }
    export -f wk

    v0_load_standalone_config

    assert_equal "$V0_ROOT" ""
}

# ============================================================================
# v0_is_standalone() tests
# ============================================================================

@test "v0_is_standalone returns true when V0_STANDALONE=1" {
    source_lib "v0-common.sh"
    export V0_STANDALONE=1

    run v0_is_standalone
    assert_success
}

@test "v0_is_standalone returns false when V0_STANDALONE=0" {
    source_lib "v0-common.sh"
    export V0_STANDALONE=0

    run v0_is_standalone
    assert_failure
}

@test "v0_is_standalone returns false when V0_STANDALONE is unset" {
    source_lib "v0-common.sh"
    unset V0_STANDALONE

    run v0_is_standalone
    assert_failure
}

# ============================================================================
# bin/v0 standalone dispatch tests
# ============================================================================

@test "v0 build shows error outside project" {
    cd "${TEST_TEMP_DIR}"
    rm -f "${TEST_TEMP_DIR}/project/.v0.rc"  # Ensure no .v0.rc

    run "$PROJECT_ROOT/bin/v0" build test-feature
    assert_failure
    assert_output --partial "Error: Not in a v0 project directory"
}

@test "v0 plan shows error outside project" {
    cd "${TEST_TEMP_DIR}"
    rm -f "${TEST_TEMP_DIR}/project/.v0.rc"

    run "$PROJECT_ROOT/bin/v0" plan test-plan
    assert_failure
    assert_output --partial "Error: Not in a v0 project directory"
}

@test "v0 error message suggests v0 chore" {
    cd "${TEST_TEMP_DIR}"
    rm -f "${TEST_TEMP_DIR}/project/.v0.rc"

    run "$PROJECT_ROOT/bin/v0" build test-feature
    assert_failure
    assert_output --partial "v0 chore"
}

@test "v0 error message suggests v0 help" {
    cd "${TEST_TEMP_DIR}"
    rm -f "${TEST_TEMP_DIR}/project/.v0.rc"

    run "$PROJECT_ROOT/bin/v0" build test-feature
    assert_failure
    assert_output --partial "v0 help"
}

# ============================================================================
# Standalone template tests
# ============================================================================

@test "standalone chore template exists" {
    assert [ -f "$PROJECT_ROOT/packages/cli/lib/templates/claude.chore.standalone.md" ]
}

@test "standalone chore template contains workflow" {
    run cat "$PROJECT_ROOT/packages/cli/lib/templates/claude.chore.standalone.md"
    assert_success
    assert_output --partial "Workflow"
    assert_output --partial "start-chore"
    assert_output --partial "completed"
}

@test "standalone chore template mentions no git" {
    run cat "$PROJECT_ROOT/packages/cli/lib/templates/claude.chore.standalone.md"
    assert_success
    assert_output --partial "No git"
}

@test "standalone chore template has CWD placeholder" {
    run cat "$PROJECT_ROOT/packages/cli/lib/templates/claude.chore.standalone.md"
    assert_success
    assert_output --partial "{{CWD}}"
}
