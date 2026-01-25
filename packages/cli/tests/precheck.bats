#!/usr/bin/env bats
# Tests for v0 precheck functionality

load '../../test-support/helpers/test_helper'

# ============================================================================
# v0_precheck() tests
# ============================================================================

@test "v0_precheck succeeds when all deps present" {
    source_lib "v0-common.sh"

    # Override command to make all deps appear present
    function command() {
        case "$2" in
            git|tmux|jq|wk|claude) return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

    run v0_precheck
    assert_success
}

@test "v0_precheck fails when deps missing" {
    source_lib "v0-common.sh"

    # Override command to simulate missing wk and claude
    function command() {
        case "$2" in
            wk|claude) return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

    run v0_precheck
    assert_failure
    assert_output --partial "Missing required dependencies"
    assert_output --partial "wk"
    assert_output --partial "claude"
}

@test "v0_precheck lists all missing deps" {
    source_lib "v0-common.sh"

    # Override command to simulate all deps missing
    function command() {
        case "$2" in
            git|tmux|jq|wk|claude) return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

    run v0_precheck
    assert_failure
    assert_output --partial "git"
    assert_output --partial "tmux"
    assert_output --partial "jq"
    assert_output --partial "wk"
    assert_output --partial "claude"
}

@test "v0_precheck shows installation instructions for missing deps" {
    source_lib "v0-common.sh"

    # Override command to simulate missing jq
    function command() {
        case "$2" in
            jq) return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

    run v0_precheck
    assert_failure
    assert_output --partial "Installation instructions"
    assert_output --partial "jq:"
}

# ============================================================================
# v0_install_instructions() tests
# ============================================================================

@test "v0_install_instructions returns brew for macOS git" {
    source_lib "v0-common.sh"

    function uname() { echo "Darwin"; }
    export -f uname

    run v0_install_instructions "git"
    assert_output --partial "brew install git"
}

@test "v0_install_instructions returns apt for Linux git" {
    source_lib "v0-common.sh"

    function uname() { echo "Linux"; }
    export -f uname

    run v0_install_instructions "git"
    assert_output --partial "apt install git"
}

@test "v0_install_instructions returns brew for macOS tmux" {
    source_lib "v0-common.sh"

    function uname() { echo "Darwin"; }
    export -f uname

    run v0_install_instructions "tmux"
    assert_output --partial "brew install tmux"
}

@test "v0_install_instructions returns apt for Linux jq" {
    source_lib "v0-common.sh"

    function uname() { echo "Linux"; }
    export -f uname

    run v0_install_instructions "jq"
    assert_output --partial "apt install jq"
}

@test "v0_install_instructions shows URL for wk" {
    source_lib "v0-common.sh"

    run v0_install_instructions "wk"
    assert_output --partial "github.com"
}

@test "v0_install_instructions shows URL for claude" {
    source_lib "v0-common.sh"

    run v0_install_instructions "claude"
    assert_output --partial "claude.ai"
    assert_output --partial "npm install"
}

@test "v0_install_instructions handles unknown command" {
    source_lib "v0-common.sh"

    run v0_install_instructions "unknowncmd"
    assert_output --partial "no installation instructions available"
}

@test "v0_install_instructions returns URL for unknown OS" {
    source_lib "v0-common.sh"

    function uname() { echo "FreeBSD"; }
    export -f uname

    run v0_install_instructions "git"
    assert_output --partial "git-scm.com"
}

# ============================================================================
# V0_REQUIRED_DEPS array tests
# ============================================================================

@test "V0_REQUIRED_DEPS contains expected dependencies" {
    source_lib "v0-common.sh"

    [[ " ${V0_REQUIRED_DEPS[*]} " == *" git "* ]]
    [[ " ${V0_REQUIRED_DEPS[*]} " == *" tmux "* ]]
    [[ " ${V0_REQUIRED_DEPS[*]} " == *" jq "* ]]
    [[ " ${V0_REQUIRED_DEPS[*]} " == *" wk "* ]]
    [[ " ${V0_REQUIRED_DEPS[*]} " == *" claude "* ]]
    [[ " ${V0_REQUIRED_DEPS[*]} " == *" flock "* ]]
}
