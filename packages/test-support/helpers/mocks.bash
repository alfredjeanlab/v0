#!/usr/bin/env bash
# mocks.bash - Mock functions for testing
#
# This file provides mock functions and utilities for testing v0 scripts
# without actually executing external commands like git, tmux, etc.
#
# Usage: source 'helpers/mocks.bash'

# Mock configuration - set these before using mocks
export MOCK_GIT_CONFLICT="${MOCK_GIT_CONFLICT:-false}"
export MOCK_TMUX_SESSION_EXISTS="${MOCK_TMUX_SESSION_EXISTS:-false}"
export MOCK_DATE="${MOCK_DATE:-}"
export MOCK_GIT_BRANCH="${MOCK_GIT_BRANCH:-main}"
export MOCK_GIT_WORKTREE_LIST="${MOCK_GIT_WORKTREE_LIST:-}"

# Track mock calls for verification
declare -a MOCK_CALLS=()

# Record a mock call
# Usage: record_mock_call "git" "status"
record_mock_call() {
    MOCK_CALLS+=("$*")
}

# Check if a mock was called with specific args
# Usage: assert_mock_called "git status"
assert_mock_called() {
    local expected="$1"
    for call in "${MOCK_CALLS[@]}"; do
        if [[ "$call" == *"$expected"* ]]; then
            return 0
        fi
    done
    echo "Mock was not called with: $expected" >&2
    echo "Recorded calls: ${MOCK_CALLS[*]}" >&2
    return 1
}

# Clear recorded mock calls
clear_mock_calls() {
    MOCK_CALLS=()
}

# Mock git command
mock_git() {
    record_mock_call "git" "$@"

    case "$1" in
        "worktree")
            case "$2" in
                "list")
                    if [ -n "$MOCK_GIT_WORKTREE_LIST" ]; then
                        echo "$MOCK_GIT_WORKTREE_LIST"
                    else
                        echo "/path/to/worktree  abc1234 [branch-name]"
                    fi
                    ;;
                "remove")
                    return 0
                    ;;
                "add")
                    return 0
                    ;;
            esac
            ;;
        "merge-tree")
            if [ "$MOCK_GIT_CONFLICT" = "true" ]; then
                echo "CONFLICT (content): Merge conflict in file.txt"
                return 1
            fi
            return 0
            ;;
        "merge")
            if [ "$MOCK_GIT_CONFLICT" = "true" ]; then
                echo "CONFLICT (content): Merge conflict in file.txt"
                echo "Automatic merge failed; fix conflicts and then commit the result."
                return 1
            fi
            return 0
            ;;
        "status")
            if [ "$2" = "--porcelain" ]; then
                # Return empty by default (clean)
                echo ""
            else
                echo "On branch $MOCK_GIT_BRANCH"
            fi
            ;;
        "branch")
            case "$2" in
                "-D"|"-d")
                    return 0
                    ;;
                *)
                    echo "$MOCK_GIT_BRANCH"
                    ;;
            esac
            ;;
        "checkout")
            return 0
            ;;
        "fetch")
            return 0
            ;;
        "push")
            return 0
            ;;
        "rev-parse")
            case "$2" in
                "--git-dir")
                    echo ".git"
                    ;;
                "HEAD")
                    echo "abc1234567890"
                    ;;
                *)
                    echo "abc1234567890"
                    ;;
            esac
            ;;
        "ls-remote")
            # Default: branch exists
            echo "abc1234567890	refs/heads/$4"
            ;;
        "init")
            mkdir -p .git
            return 0
            ;;
        "-C")
            # Handle git -C <path> <command>
            shift 2  # Skip -C and path
            mock_git "$@"
            return $?
            ;;
        *)
            # Default passthrough behavior - echo the command
            echo "mock git: $*"
            return 0
            ;;
    esac
}

# Mock tmux command
mock_tmux() {
    record_mock_call "tmux" "$@"

    case "$1" in
        "has-session")
            if [ "$MOCK_TMUX_SESSION_EXISTS" = "true" ]; then
                return 0
            fi
            return 1
            ;;
        "new-session")
            return 0
            ;;
        "kill-session")
            return 0
            ;;
        "attach"|"attach-session")
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Mock date command
mock_date() {
    record_mock_call "date" "$@"

    if [ -n "$MOCK_DATE" ]; then
        # Parse the format argument
        case "$*" in
            *"+%Y-%m-%dT%H:%M:%SZ"*)
                echo "$MOCK_DATE"
                ;;
            *"+%s"*)
                # Convert ISO8601 to epoch (approximate)
                echo "1736935200"  # Fixed epoch for testing
                ;;
            *)
                echo "$MOCK_DATE"
                ;;
        esac
    else
        # Fall back to real date
        command date "$@"
    fi
}

# Mock jq command - passthrough by default since we need it for testing
mock_jq() {
    record_mock_call "jq" "$@"
    command jq "$@"
}

# Mock wk command
mock_wk() {
    record_mock_call "wk" "$@"

    case "$1" in
        "list")
            # Return empty by default
            echo ""
            ;;
        "init")
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Mock osascript (macOS notifications)
mock_osascript() {
    record_mock_call "osascript" "$@"
    return 0
}

# Mock pgrep
mock_pgrep() {
    record_mock_call "pgrep" "$@"
    return 1  # Default: process not found
}

# Mock pkill
mock_pkill() {
    record_mock_call "pkill" "$@"
    return 0
}

# Install mocks by creating wrapper functions
install_mocks() {
    # Create mock-bin directory if it doesn't exist
    local mock_bin="$TESTS_DIR/helpers/mock-bin"
    mkdir -p "$mock_bin"

    # Create mock scripts
    cat > "$mock_bin/git" <<'EOF'
#!/bin/bash
source "$(dirname "$0")/../mocks.bash"
mock_git "$@"
EOF
    chmod +x "$mock_bin/git"

    cat > "$mock_bin/tmux" <<'EOF'
#!/bin/bash
source "$(dirname "$0")/../mocks.bash"
mock_tmux "$@"
EOF
    chmod +x "$mock_bin/tmux"

    # Add mock-bin to PATH
    export PATH="$mock_bin:$PATH"
}

# Enable function-based mocks (overrides commands in current shell)
enable_function_mocks() {
    git() { mock_git "$@"; }
    tmux() { mock_tmux "$@"; }
    wk() { mock_wk "$@"; }
    osascript() { mock_osascript "$@"; }
    pgrep() { mock_pgrep "$@"; }
    pkill() { mock_pkill "$@"; }

    export -f git tmux wk osascript pgrep pkill
}

# Disable function-based mocks (restore original commands)
disable_function_mocks() {
    unset -f git tmux wk osascript pgrep pkill
}
