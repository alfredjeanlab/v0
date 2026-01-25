#!/usr/bin/env bats
# Tests for help-colors.sh - Help output colorization functions

load '../../test-support/helpers/test_helper'

setup() {
    _base_setup
    source_lib "v0-common.sh"
}

# ============================================================================
# v0_colorize_help() tests - Section headers
# ============================================================================

@test "v0_colorize_help colorizes section headers" {
    # Force TTY colors for testing
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    result=$(echo "Commands:" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;74m'* ]]  # Contains section color
    [[ "$result" == *"Commands:"* ]]
}

@test "v0_colorize_help colorizes Options: header" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    result=$(echo "Options:" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;74m'* ]]
    [[ "$result" == *"Options:"* ]]
}

@test "v0_colorize_help colorizes Examples: header" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    result=$(echo "Examples:" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;74m'* ]]
    [[ "$result" == *"Examples:"* ]]
}

@test "v0_colorize_help does not colorize non-header lines ending with colon" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    # Line that starts with spaces should not be treated as header
    result=$(echo "  some text:" | v0_colorize_help)
    [[ "$result" != *$'\033[38;5;74m'"some text:"* ]]
}

@test "v0_colorize_help colorizes Usage: prefix" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    result=$(echo "Usage: v0 <command> [args]" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;74m'"Usage:"* ]]  # Usage: is colored
    [[ "$result" == *"v0 <command> [args]"* ]]     # Rest is preserved
}

@test "v0_colorize_help leaves content after Usage: uncolored" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    result=$(echo "Usage: mycommand --flag" | v0_colorize_help)
    # The reset should come right after "Usage:"
    [[ "$result" == $'\033[38;5;74m'"Usage:"$'\033[0m'" mycommand --flag" ]]
}

# ============================================================================
# v0_colorize_help() tests - Command colorization
# ============================================================================

@test "v0_colorize_help colorizes command names" {
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(echo "  build   Build things" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;250m'* ]]  # Contains command color
    [[ "$result" == *"build"* ]]
}

@test "v0_colorize_help colorizes flags with double dash" {
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(echo "  --help    Show help" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;250m'* ]]
    [[ "$result" == *"--help"* ]]
}

@test "v0_colorize_help colorizes flags with single dash" {
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(echo "  -h    Show help" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;250m'* ]]
    [[ "$result" == *"-h"* ]]
}

@test "v0_colorize_help preserves non-indented lines" {
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(echo "This is a description line" | v0_colorize_help)
    # Should not have command color applied to non-indented lines
    [[ "$result" == "This is a description line" ]]
}

# ============================================================================
# v0_colorize_help() tests - Default value colorization
# ============================================================================

@test "v0_colorize_help colorizes defaults" {
    C_HELP_DEFAULT=$'\033[38;5;243m'
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(echo "  --foo   Option (default: bar)" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;243m'* ]]  # Contains default color
    [[ "$result" == *"default: bar"* ]]
}

@test "v0_colorize_help colorizes uppercase Default" {
    C_HELP_DEFAULT=$'\033[38;5;243m'
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(echo "  --opt   Some option (Default: value)" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;243m'* ]]
    [[ "$result" == *"Default: value"* ]]
}

# ============================================================================
# v0_colorize_help() tests - Non-TTY mode (no colors)
# ============================================================================

@test "v0_colorize_help preserves plain text when not TTY" {
    # Unset colors to simulate non-TTY
    C_HELP_SECTION=''
    C_HELP_COMMAND=''
    C_HELP_DEFAULT=''
    C_RESET=''

    result=$(echo -e "Commands:\n  build   Build things" | v0_colorize_help)
    [[ "$result" != *$'\033['* ]]  # No escape codes
    [[ "$result" == *"Commands:"* ]]
    [[ "$result" == *"build"* ]]
}

@test "v0_colorize_help handles empty color variables gracefully" {
    C_HELP_SECTION=''
    C_HELP_COMMAND=''
    C_HELP_DEFAULT=''
    C_RESET=''

    result=$(echo "  --foo  Description (default: x)" | v0_colorize_help)
    # Should output the line without errors
    [[ "$result" == *"--foo"* ]]
    [[ "$result" == *"default: x"* ]]
}

# ============================================================================
# v0_colorize_help() tests - Multi-line processing
# ============================================================================

@test "v0_colorize_help handles multiple lines" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(printf "Commands:\n  build   Build\n  fix     Fix bugs" | v0_colorize_help)

    # Should have section header colored
    [[ "$result" == *$'\033[38;5;74m'"Commands:"* ]]
    # Should have commands colored
    [[ "$result" == *"build"* ]]
    [[ "$result" == *"fix"* ]]
}

@test "v0_colorize_help preserves empty lines" {
    C_HELP_SECTION=''
    C_HELP_COMMAND=''
    C_RESET=''

    input=$'Line 1\n\nLine 3'
    result=$(echo "$input" | v0_colorize_help)

    # Count lines - should be 3
    line_count=$(echo "$result" | wc -l | tr -d ' ')
    [[ "$line_count" -eq 3 ]]
}

# ============================================================================
# v0_help() tests
# ============================================================================

@test "v0_help is an alias for v0_colorize_help" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_RESET=$'\033[0m'

    result=$(echo "Commands:" | v0_help)
    [[ "$result" == *$'\033[38;5;74m'* ]]
    [[ "$result" == *"Commands:"* ]]
}

@test "v0_help works with heredoc input" {
    C_HELP_SECTION=$'\033[38;5;74m'
    C_HELP_COMMAND=$'\033[38;5;250m'
    C_RESET=$'\033[0m'

    result=$(v0_help <<'EOF'
Commands:
  test    Run tests
EOF
)
    [[ "$result" == *"Commands:"* ]]
    [[ "$result" == *"test"* ]]
}

# ============================================================================
# Color constant tests
# ============================================================================

@test "C_HELP_SECTION is defined when TTY" {
    # Force re-source with TTY simulation would be complex,
    # so we just verify the constant exists after sourcing
    [[ -n "${C_HELP_SECTION+x}" ]]
}

@test "C_HELP_COMMAND is defined when TTY" {
    [[ -n "${C_HELP_COMMAND+x}" ]]
}

@test "C_HELP_DEFAULT is defined when TTY" {
    [[ -n "${C_HELP_DEFAULT+x}" ]]
}
