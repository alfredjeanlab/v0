#!/usr/bin/env bash
# test_helper.bash - Common setup/teardown for BATS tests
#
# Usage: load 'helpers/test_helper'

# Get the tests directory path
# TESTS_DIR points to the test-support package (for fixtures, mocks, etc.)
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PROJECT_ROOT is the v0 project root (two levels up from packages/test-support)
PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

# Track the original working directory to ensure test isolation
export ORIGINAL_PWD="${PWD}"

# Determine BATS library path (always use absolute paths to avoid issues in worktrees)
if [[ -n "${BATS_LIB_PATH:-}" ]]; then
    # Convert to absolute path if relative
    if [[ "${BATS_LIB_PATH}" == /* ]]; then
        _BATS_LIB="${BATS_LIB_PATH}"
    else
        _BATS_LIB="$(cd "${BATS_LIB_PATH}" && pwd)"
    fi
elif [[ -d "${TESTS_DIR}/bats/bats-support" ]]; then
    _BATS_LIB="${TESTS_DIR}/bats"
else
    # System installation (Homebrew on macOS, apt on Linux)
    _BATS_LIB="/usr/local/lib"
fi

# Load BATS helper libraries
load "${_BATS_LIB}/bats-support/load.bash"
load "${_BATS_LIB}/bats-assert/load.bash"

# ============================================================================
# Test Timeout
# ============================================================================
# Set a default timeout for all tests to prevent hangs
# Individual tests can override by setting BATS_TEST_TIMEOUT in setup_file() or the test
: "${BATS_TEST_TIMEOUT:=5}"
export BATS_TEST_TIMEOUT

# ============================================================================
# Directory Template Caching
# ============================================================================
# Pre-create common directory structures once per test file to reduce mkdir calls

_CACHED_STRUCTURE_TEMPLATE=""
_CLEANUP_DIRS=()

_create_cached_template() {
    if [[ -z "$_CACHED_STRUCTURE_TEMPLATE" ]]; then
        _CACHED_STRUCTURE_TEMPLATE=$(mktemp -d)
        # Pre-create common v0 directory structure
        mkdir -p "$_CACHED_STRUCTURE_TEMPLATE/project/.v0/build/operations"
        mkdir -p "$_CACHED_STRUCTURE_TEMPLATE/project/.v0/build/sessions"
        mkdir -p "$_CACHED_STRUCTURE_TEMPLATE/project/.v0/build/mergeq/logs"
        mkdir -p "$_CACHED_STRUCTURE_TEMPLATE/state"
        mkdir -p "$_CACHED_STRUCTURE_TEMPLATE/home/.local/state/v0"
    fi
}

_cleanup_template() {
    if [[ -n "$_CACHED_STRUCTURE_TEMPLATE" && -d "$_CACHED_STRUCTURE_TEMPLATE" ]]; then
        rm -rf "$_CACHED_STRUCTURE_TEMPLATE"
        _CACHED_STRUCTURE_TEMPLATE=""
    fi
}

# Batch cleanup all deferred directories
_cleanup_deferred() {
    local dir
    for dir in "${_CLEANUP_DIRS[@]}"; do
        [[ -n "$dir" && -d "$dir" ]] && /bin/rm -rf "$dir"
    done
    _CLEANUP_DIRS=()
}

# Default teardown_file - clean up cached template and deferred directories
# Test files can override this, but should call these cleanup functions
teardown_file() {
    _cleanup_deferred
    _cleanup_template
}

# Base setup function - creates isolated test environment
# Call this from custom setup() functions to get the standard environment
_base_setup() {
    _create_cached_template

    # Create unique temp directory for each test
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    # Fast copy from template instead of multiple mkdirs
    cp -r "$_CACHED_STRUCTURE_TEMPLATE/project" "$TEST_TEMP_DIR/"
    cp -r "$_CACHED_STRUCTURE_TEMPLATE/state" "$TEST_TEMP_DIR/"

    # Set up mock home directory
    export REAL_HOME="$HOME"
    cp -r "$_CACHED_STRUCTURE_TEMPLATE/home" "$TEST_TEMP_DIR/"
    export HOME="$TEST_TEMP_DIR/home"

    # Enable test mode to disable notifications and enable test safeguards
    export V0_TEST_MODE=1
    export V0_NO_NOTIFICATIONS=1  # Additional safety for notification suppression

    # Clear v0 state variables to ensure test isolation
    # This prevents tests from accidentally using the real project's config
    unset V0_ROOT
    unset V0_DIR
    unset PROJECT
    unset ISSUE_PREFIX
    unset BUILD_DIR
    unset PLANS_DIR
    unset V0_STATE_DIR
    unset V0_GIT_REMOTE
    unset V0_DEVELOP_BRANCH
    unset V0_WORKSPACE_MODE

    # Ensure we start in the project directory
    cd "$TEST_TEMP_DIR/project"

    # Track original PATH
    export ORIGINAL_PATH="$PATH"
}

# Default setup - calls _base_setup
# Override this in test files, but call _base_setup first for the standard environment
setup() {
    _base_setup
}

teardown() {
    # Restore HOME (only if REAL_HOME was set)
    [[ -n "${REAL_HOME:-}" ]] && export HOME="$REAL_HOME"

    # Restore PATH (only if ORIGINAL_PATH was set)
    [[ -n "${ORIGINAL_PATH:-}" ]] && export PATH="$ORIGINAL_PATH"

    # Clean up temp directory
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        if [[ -n "${BATS_FAST_CLEANUP:-}" ]]; then
            # Defer cleanup - batch at end of test file for better performance
            _CLEANUP_DIRS+=("$TEST_TEMP_DIR")
        else
            /bin/rm -rf "$TEST_TEMP_DIR"
        fi
    fi
}

# ============================================================================
# Standard V0 Environment Setup
# ============================================================================
# Call this helper in tests that need V0_ROOT, BUILD_DIR, etc. set up
# Usage: Add to your test's setup() after calling the base setup, or use
#        setup_v0_env directly if you have a custom setup

# Set standard V0 environment variables
# Usage: setup_v0_env [project_name] [issue_prefix]
# This sets V0_ROOT, PROJECT, BUILD_DIR, etc. based on TEST_TEMP_DIR
setup_v0_env() {
    local project="${1:-testproject}"
    local prefix="${2:-testp}"

    export V0_ROOT="$TEST_TEMP_DIR/project"
    export PROJECT="$project"
    export ISSUE_PREFIX="$prefix"
    export BUILD_DIR="$TEST_TEMP_DIR/project/.v0/build"
    export V0_DIR="${PROJECT_ROOT}"
    export V0_STATE_DIR="$HOME/.local/state/v0"
    export MERGEQ_DIR="${BUILD_DIR}/mergeq"
    export QUEUE_FILE="${MERGEQ_DIR}/queue.json"
    export QUEUE_LOCK="${MERGEQ_DIR}/.queue.lock"

    # Create v0rc if it doesn't exist
    if [[ ! -f "$TEST_TEMP_DIR/project/.v0.rc" ]]; then
        create_v0rc "$project" "$prefix"
    fi
}

# ============================================================================
# Source Caching
# ============================================================================
# Track sourced libraries to avoid re-sourcing (parsing overhead)
# Note: Uses simple string matching since macOS bash 3.2 doesn't support associative arrays

_SOURCED_LIBS=""

# Source a library file from packages/
# Usage: source_lib "v0-common.sh"
# Performance: Tracks sourced files to avoid duplicate parsing
source_lib() {
    local lib="$1"
    local lib_path=""

    # Skip if already sourced in this test run (use string matching for bash 3.2 compat)
    if [[ ":${_SOURCED_LIBS}:" == *":${lib}:"* ]]; then
        return 0
    fi

    # Map common libraries to their package locations
    case "$lib" in
        v0-common.sh)       lib_path="$PROJECT_ROOT/packages/cli/lib/v0-common.sh" ;;
        worker-common.sh)   lib_path="$PROJECT_ROOT/packages/worker/lib/worker-common.sh" ;;
        nudge-common.sh)    lib_path="$PROJECT_ROOT/packages/worker/lib/nudge-common.sh" ;;
        coffee-common.sh)   lib_path="$PROJECT_ROOT/packages/worker/lib/coffee-common.sh" ;;
        state-machine.sh)   lib_path="$PROJECT_ROOT/packages/state/lib/state-machine.sh" ;;
        update-common.sh)   lib_path="$PROJECT_ROOT/packages/cli/lib/update-common.sh" ;;
        debug-common.sh)    lib_path="$PROJECT_ROOT/packages/cli/lib/debug-common.sh" ;;
        grep.sh)            lib_path="$PROJECT_ROOT/packages/core/lib/grep.sh" ;;
        prune-daemon.sh)    lib_path="$PROJECT_ROOT/packages/core/lib/prune-daemon.sh" ;;
        *)
            # Try to find in packages subdirectories
            for pkg in cli core state worker mergeq merge feature hooks status workspace; do
                if [[ -f "$PROJECT_ROOT/packages/$pkg/lib/$lib" ]]; then
                    lib_path="$PROJECT_ROOT/packages/$pkg/lib/$lib"
                    break
                fi
            done
            ;;
    esac

    if [[ -n "$lib_path" && -f "$lib_path" ]]; then
        source "$lib_path"
        _SOURCED_LIBS="${_SOURCED_LIBS}:${lib}"
    else
        echo "Library not found: $lib" >&2
        return 1
    fi
}

# Source library with mocks enabled
# Usage: source_lib_with_mocks "v0-common.sh"
# Note: Does not use caching since mocks modify behavior
source_lib_with_mocks() {
    local lib="$1"
    local lib_path=""

    # Map to package locations
    case "$lib" in
        v0-common.sh)       lib_path="$PROJECT_ROOT/packages/cli/lib/v0-common.sh" ;;
        worker-common.sh)   lib_path="$PROJECT_ROOT/packages/worker/lib/worker-common.sh" ;;
        *)                  lib_path="$PROJECT_ROOT/packages/cli/lib/$lib" ;;
    esac

    # Add mock-bin to PATH before sourcing
    export PATH="$TESTS_DIR/helpers/mock-bin:$PATH"
    source "$lib_path"
    # Mark as sourced (with mocks) to prevent non-mock source_lib from re-sourcing
    _SOURCED_LIBS="${_SOURCED_LIBS}:${lib}_mocked"
}

# Create a minimal .v0.rc configuration file
# Usage: create_v0rc [project_name] [issue_prefix]
create_v0rc() {
    local project="${1:-testproject}"
    local prefix="${2:-test}"
    cat > "$TEST_TEMP_DIR/project/.v0.rc" <<EOF
PROJECT="$project"
ISSUE_PREFIX="$prefix"
EOF
}

# Create a .v0.rc with custom content
# Usage: create_v0rc_content "content"
create_v0rc_content() {
    echo "$1" > "$TEST_TEMP_DIR/project/.v0.rc"
}

# Create a state.json file for an operation
# Usage: create_operation_state "operation-name" '{"name": "op", "phase": "init"}'
#    OR: create_operation_state "operation-name" "phase" ["epic_id"]
# The second form creates a minimal state.json for blocking tests
create_operation_state() {
    local op_name="$1"
    local op_dir="$TEST_TEMP_DIR/project/.v0/build/operations/$op_name"
    mkdir -p "$op_dir"

    # Check if second arg looks like JSON
    if [[ "$2" == "{"* ]]; then
        # Original signature: full JSON content
        echo "$2" > "$op_dir/state.json"
    else
        # New signature: phase and optional epic_id
        local phase="$2"
        local epic_id="${3:-}"

        local epic_json="null"
        [[ -n "${epic_id}" ]] && [[ "${epic_id}" != "null" ]] && epic_json="\"${epic_id}\""

        cat > "$op_dir/state.json" <<EOF
{
  "name": "${op_name}",
  "phase": "${phase}",
  "epic_id": ${epic_json},
  "_schema_version": 2
}
EOF
    fi
}

# Create a queue.json file
# Usage: create_queue_file '{"version": 1, "entries": []}'
create_queue_file() {
    local json_content="$1"
    local queue_dir="$TEST_TEMP_DIR/project/.v0/build/mergeq"
    mkdir -p "$queue_dir/logs"
    echo "$json_content" > "$queue_dir/queue.json"
}

# Copy a fixture file to the test temp directory
# Usage: use_fixture "queues/multi-priority.json" "queue.json"
use_fixture() {
    local fixture="$1"
    local dest="$2"
    cp "$TESTS_DIR/fixtures/$fixture" "$TEST_TEMP_DIR/$dest"
}

# Assert that a file exists
# Usage: assert_file_exists "$path"
assert_file_exists() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "Expected file to exist: $path" >&2
        return 1
    fi
}

# Assert that a file does not exist
# Usage: assert_file_not_exists "$path"
assert_file_not_exists() {
    local path="$1"
    if [ -f "$path" ]; then
        echo "Expected file to not exist: $path" >&2
        return 1
    fi
}

# Assert that a directory exists
# Usage: assert_dir_exists "$path"
assert_dir_exists() {
    local path="$1"
    if [ ! -d "$path" ]; then
        echo "Expected directory to exist: $path" >&2
        return 1
    fi
}

# Assert JSON field equals value
# Usage: assert_json_field "file.json" ".field" "expected"
assert_json_field() {
    local file="$1"
    local field="$2"
    local expected="$3"
    local actual
    actual=$(jq -r "$field" "$file")
    if [ "$actual" != "$expected" ]; then
        echo "JSON field $field: expected '$expected', got '$actual'" >&2
        return 1
    fi
}

# Get JSON field value
# Usage: value=$(get_json_field "file.json" ".field")
get_json_field() {
    local file="$1"
    local field="$2"
    jq -r "$field" "$file"
}

# ============================================================================
# jq Optimization Helpers
# ============================================================================
# Batch multiple jq queries into one call for better performance

# Batch multiple jq queries into one call
# Usage: results=($(jq_batch "$file" '.field1' '.field2'))
# Returns: newline-separated results for each query
jq_batch() {
    local file="$1"
    shift
    local queries=("$@")

    # Build compound jq query
    local compound_query=""
    for q in "${queries[@]}"; do
        compound_query+="${q},"
    done
    compound_query="[${compound_query%,}]"

    jq -r "$compound_query | .[]" "$file"
}

# Check if JSON file has a non-empty entries array (without jq)
# Usage: if json_has_entries "$file"; then ...
json_has_entries() {
    local file="$1"
    [[ -s "$file" ]] && grep -q '"entries"[[:space:]]*:[[:space:]]*\[' "$file" && \
        ! grep -q '"entries"[[:space:]]*:[[:space:]]*\[\]' "$file"
}

# Check if JSON file has specific field (without jq)
# Usage: if json_has_field "$file" "status"; then ...
json_has_field() {
    local file="$1"
    local field="$2"
    [[ -s "$file" ]] && grep -q "\"$field\"" "$file"
}

# Create a mock git repository
# Usage: init_mock_git_repo [path]
# Performance: Uses cached git fixture if available for ~10x speedup
init_mock_git_repo() {
    local path="${1:-$TEST_TEMP_DIR/project}"
    local fixture_tar="${TESTS_DIR}/fixtures/git-repo.tar"

    if [[ -f "$fixture_tar" ]]; then
        # Fast path: extract pre-built repo and clone locally
        tar -xf "$fixture_tar" -C "$TEST_TEMP_DIR"
        git clone --quiet "$TEST_TEMP_DIR/cached-repo.git" "${path}.new" 2>/dev/null
        # Replace existing directory contents with cloned repo
        rm -rf "$path"
        mv "${path}.new" "$path"
        (
            cd "$path"
            git config user.email "test@example.com"
            git config user.name "Test User"
        )
    else
        # Fallback: original slow path (for environments without fixture)
        (
            cd "$path"
            git init --quiet
            git config user.email "test@example.com"
            git config user.name "Test User"
            echo "test" > README.md
            git add README.md
            git commit --quiet -m "Initial commit"
        )
    fi
}

# Create a branch in the mock git repo
# Usage: create_git_branch "branch-name" [path]
create_git_branch() {
    local branch="$1"
    local path="${2:-$TEST_TEMP_DIR/project}"
    (
        cd "$path"
        git checkout -b "$branch" --quiet 2>/dev/null || git checkout "$branch" --quiet
    )
}

# Freeze the date for reproducible tests
# Usage: freeze_date "2026-01-15T10:00:00Z"
freeze_date() {
    local frozen_date="$1"
    export MOCK_DATE="$frozen_date"
}

# ============================================================================
# Test Isolation Verification
# ============================================================================

# Verify that we are running in an isolated test environment
# Usage: assert_test_isolation (called automatically in setup, can be called manually)
assert_test_isolation() {
    # Verify we're not in the original working directory
    if [[ "$PWD" == "$ORIGINAL_PWD" ]] || [[ "$PWD" == "$PROJECT_ROOT" ]]; then
        echo "ERROR: Test is running in the original working directory!" >&2
        echo "  Current PWD: $PWD" >&2
        echo "  Original PWD: $ORIGINAL_PWD" >&2
        echo "  Tests must run in isolated temp directories." >&2
        return 1
    fi

    # Verify TEST_TEMP_DIR is set and we're inside it
    if [[ -z "$TEST_TEMP_DIR" ]] || [[ ! -d "$TEST_TEMP_DIR" ]]; then
        echo "ERROR: TEST_TEMP_DIR is not set or does not exist!" >&2
        return 1
    fi

    # Verify V0_TEST_MODE is enabled
    if [[ "$V0_TEST_MODE" != "1" ]]; then
        echo "ERROR: V0_TEST_MODE is not enabled!" >&2
        return 1
    fi

    return 0
}

# Assert that no files were created in the project root during tests
# Usage: assert_no_project_root_changes
assert_no_project_root_changes() {
    local new_files
    new_files=$(cd "$PROJECT_ROOT" && git status --porcelain 2>/dev/null | grep "^??" | wc -l)
    if [[ "$new_files" -gt 0 ]]; then
        echo "ERROR: New files were created in the project root during tests!" >&2
        (cd "$PROJECT_ROOT" && git status --porcelain | grep "^??") >&2
        return 1
    fi
    return 0
}

# Verify test environment variables are properly set
# Usage: assert_test_env
assert_test_env() {
    local errors=0

    if [[ "$V0_TEST_MODE" != "1" ]]; then
        echo "ERROR: V0_TEST_MODE should be 1, got: $V0_TEST_MODE" >&2
        errors=$((errors + 1))
    fi

    if [[ "$V0_NO_NOTIFICATIONS" != "1" ]]; then
        echo "ERROR: V0_NO_NOTIFICATIONS should be 1, got: $V0_NO_NOTIFICATIONS" >&2
        errors=$((errors + 1))
    fi

    if [[ -z "$TEST_TEMP_DIR" ]]; then
        echo "ERROR: TEST_TEMP_DIR is not set" >&2
        errors=$((errors + 1))
    fi

    return $errors
}

# ============================================================================
# Mock Binary Helpers
# ============================================================================

# Create mock binaries for commands not available in CI
# Usage: setup_mock_binaries [commands...]
# Example: setup_mock_binaries claude tmux
# This creates simple mock scripts and adds them to PATH
setup_mock_binaries() {
    local mock_dir="${TEST_TEMP_DIR}/mock-bin"
    mkdir -p "$mock_dir"

    for cmd in "$@"; do
        cat > "$mock_dir/$cmd" <<EOF
#!/bin/bash
echo "mock $cmd \$*"
exit 0
EOF
        chmod +x "$mock_dir/$cmd"
    done

    export PATH="$mock_dir:$PATH"
}

# ============================================================================
# Wok Mock Helpers
# ============================================================================

# Set up mock data directory and enable mock wk
# Call this in setup() after _base_setup
setup_wk_mocks() {
    export MOCK_DATA_DIR="${TEST_TEMP_DIR}/mock-data"
    mkdir -p "${MOCK_DATA_DIR}/wk"
    # Add mock-bin to PATH so wk command uses our mock
    export PATH="${TESTS_DIR}/helpers/mock-bin:${PATH}"
}

# mock_wk_show <issue_id> <json_response>
# Set up mock response for wk show <issue_id> -o json
mock_wk_show() {
    local issue_id="$1"
    local response="$2"

    mkdir -p "${MOCK_DATA_DIR}/wk"
    echo "${response}" > "${MOCK_DATA_DIR}/wk/${issue_id}.json"
}
