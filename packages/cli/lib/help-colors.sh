#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# help-colors.sh - Helper functions for colorizing help output

# Format help text with consistent colors
# Reads from stdin, writes to stdout
# Colorizes:
#   - Section headers (lines ending with : at column 0)
#   - Commands and flags (first word after leading spaces)
#   - Defaults (text in parentheses containing "default")
v0_colorize_help() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Section headers: lines that end with ":" and start at column 0
        if [[ "$line" =~ ^[A-Z][a-zA-Z\ ]*:$ ]]; then
            printf '%b%s%b\n' "${C_HELP_SECTION}" "$line" "${C_RESET}"
        # Lines with commands/flags (indented lines)
        elif [[ "$line" =~ ^[\ ]{2,} ]]; then
            # Colorize defaults in parentheses containing "default"
            if [[ -n "${C_HELP_DEFAULT}" ]] && [[ "$line" =~ \(.*[Dd]efault.*\) ]]; then
                line=$(printf '%s' "$line" | sed -E "s/\(([^)]*[Dd]efault[^)]*)\)/${C_HELP_DEFAULT//\\/\\\\}(\1)${C_RESET//\\/\\\\}/g")
            fi
            # Colorize leading command/flag (first word after leading spaces)
            if [[ "$line" =~ ^([\ ]+)(--?[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+)(.*) ]]; then
                local spaces="${BASH_REMATCH[1]}"
                local cmd="${BASH_REMATCH[2]}"
                local rest="${BASH_REMATCH[3]}"
                printf '%s%b%s%b%s\n' "$spaces" "${C_HELP_COMMAND}" "$cmd" "${C_RESET}" "$rest"
            else
                printf '%s\n' "$line"
            fi
        else
            printf '%s\n' "$line"
        fi
    done
}

# Wrapper to output help with colors
# Usage: v0_help <<'EOF' ... EOF
v0_help() {
    v0_colorize_help
}
