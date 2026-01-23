#!/usr/bin/env bats
# Tests for v0-feature State Machine Logic

load '../helpers/test_helper'

# Setup for feature state tests
setup() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    TEST_TEMP_DIR="${temp_dir}"
    export TEST_TEMP_DIR

    mkdir -p "${TEST_TEMP_DIR}/project"
    mkdir -p "${TEST_TEMP_DIR}/project/.v0/build/operations"
    mkdir -p "${TEST_TEMP_DIR}/state"

    export REAL_HOME="${HOME}"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "${HOME}/.local/state/v0"

    # Disable OS notifications during tests
    export V0_TEST_MODE=1

    cd "${TEST_TEMP_DIR}/project" || return 1
    export ORIGINAL_PATH="${PATH}"

    # Create valid v0 config
    create_v0rc "testproject" "testp"

    # Export paths
    export V0_ROOT="${TEST_TEMP_DIR}/project"
    export PROJECT="testproject"
    export ISSUE_PREFIX="testp"
    export BUILD_DIR="${TEST_TEMP_DIR}/project/.v0/build"
}

teardown() {
    export HOME="${REAL_HOME}"
    export PATH="${ORIGINAL_PATH}"

    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# Helper to define state management functions
source_state_functions() {
    # Extracted from v0-feature for testing
    local NAME="$1"
    STATE_DIR="${BUILD_DIR}/operations/${NAME}"
    STATE_FILE="${STATE_DIR}/state.json"

    update_state() {
        local key="$1"
        local value="$2"
        local tmp
        tmp=$(mktemp)
        jq ".${key} = ${value}" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
    }

    get_state() {
        jq -r ".$1 // empty" "${STATE_FILE}"
    }

    is_after_op_merged() {
        local op="$1"
        local state_file="${BUILD_DIR}/operations/${op}/state.json"
        [ ! -f "${state_file}" ] && return 1
        local phase
        phase=$(jq -r '.phase' "${state_file}")
        [ "${phase}" = "merged" ]
    }
}

# ============================================================================
# init_state() / State Creation tests
# ============================================================================

@test "init_state creates valid JSON structure" {
    local NAME="my-feature"
    local STATE_DIR="${BUILD_DIR}/operations/${NAME}"
    local STATE_FILE="${STATE_DIR}/state.json"
    mkdir -p "${STATE_DIR}/logs"

    # Create minimal state
    cat > "${STATE_FILE}" <<EOF
{
  "name": "${NAME}",
  "phase": "init",
  "prompt": "Build the thing",
  "created_at": "2026-01-15T10:00:00Z"
}
EOF

    # Validate JSON structure
    run jq -e '.name == "my-feature"' "${STATE_FILE}"
    assert_success

    run jq -e '.phase == "init"' "${STATE_FILE}"
    assert_success

    run jq -e '.prompt == "Build the thing"' "${STATE_FILE}"
    assert_success
}

@test "init_state creates state directory and logs" {
    local NAME="test-op"
    local STATE_DIR="${BUILD_DIR}/operations/${NAME}"
    mkdir -p "${STATE_DIR}/logs"

    assert_dir_exists "${STATE_DIR}"
    assert_dir_exists "${STATE_DIR}/logs"
}

@test "state file can be loaded from fixtures" {
    local NAME="test-feature"
    local STATE_DIR="${BUILD_DIR}/operations/${NAME}"
    local STATE_FILE="${STATE_DIR}/state.json"
    mkdir -p "${STATE_DIR}"

    cp "${TESTS_DIR}/fixtures/states/init-state.json" "${STATE_FILE}"

    run jq -r '.name' "${STATE_FILE}"
    assert_success
    assert_output "test-feature"

    run jq -r '.phase' "${STATE_FILE}"
    assert_success
    assert_output "init"
}

# ============================================================================
# update_state() tests
# ============================================================================

@test "update_state modifies phase correctly" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "phase": "init"}' > "${STATE_FILE}"

    update_state "phase" '"planned"'

    run jq -r '.phase' "${STATE_FILE}"
    assert_success
    assert_output "planned"
}

@test "update_state preserves other fields" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}" <<'EOF'
{"name": "test-op", "phase": "init", "prompt": "original prompt"}
EOF

    update_state "phase" '"executing"'

    # Original field preserved
    run jq -r '.prompt' "${STATE_FILE}"
    assert_output "original prompt"
}

@test "update_state can set null values" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "phase": "init", "worktree": "/some/path"}' > "${STATE_FILE}"

    update_state "worktree" 'null'

    run jq -r '.worktree' "${STATE_FILE}"
    assert_output "null"
}

@test "update_state can set string values with quotes" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "worktree": null}' > "${STATE_FILE}"

    update_state "worktree" '"/path/to/worktree"'

    run jq -r '.worktree' "${STATE_FILE}"
    assert_output "/path/to/worktree"
}

@test "update_state can set boolean values" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "merge_queued": false}' > "${STATE_FILE}"

    update_state "merge_queued" 'true'

    run jq -r '.merge_queued' "${STATE_FILE}"
    assert_output "true"
}

@test "update_state can add new fields" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op"}' > "${STATE_FILE}"

    update_state "new_field" '"new value"'

    run jq -r '.new_field' "${STATE_FILE}"
    assert_output "new value"
}

# ============================================================================
# get_state() tests
# ============================================================================

@test "get_state retrieves existing field" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "phase": "executing"}' > "${STATE_FILE}"

    run get_state "phase"
    assert_success
    assert_output "executing"
}

@test "get_state returns empty for missing field" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op"}' > "${STATE_FILE}"

    run get_state "nonexistent"
    assert_success
    assert_output ""
}

@test "get_state handles null values" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "worktree": null}' > "${STATE_FILE}"

    run get_state "worktree"
    assert_success
    assert_output ""
}

@test "get_state handles nested paths" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-op", "labels": ["bug", "urgent"]}' > "${STATE_FILE}"

    run get_state "labels[0]"
    assert_success
    assert_output "bug"
}

# ============================================================================
# is_after_op_merged() tests
# ============================================================================

@test "is_after_op_merged returns true for merged operation" {
    source_state_functions "child"

    # Create parent operation in merged state
    mkdir -p "${BUILD_DIR}/operations/parent"
    echo '{"phase": "merged"}' > "${BUILD_DIR}/operations/parent/state.json"

    run is_after_op_merged "parent"
    assert_success
}

@test "is_after_op_merged returns false for non-merged operation" {
    source_state_functions "child"

    # Create parent operation in executing state
    mkdir -p "${BUILD_DIR}/operations/parent"
    echo '{"phase": "executing"}' > "${BUILD_DIR}/operations/parent/state.json"

    run is_after_op_merged "parent"
    assert_failure
}

@test "is_after_op_merged returns false for missing operation" {
    source_state_functions "child"

    run is_after_op_merged "nonexistent"
    assert_failure
}

@test "is_after_op_merged handles init phase" {
    source_state_functions "child"

    mkdir -p "${BUILD_DIR}/operations/parent"
    echo '{"phase": "init"}' > "${BUILD_DIR}/operations/parent/state.json"

    run is_after_op_merged "parent"
    assert_failure
}

@test "is_after_op_merged handles completed phase (not merged)" {
    source_state_functions "child"

    mkdir -p "${BUILD_DIR}/operations/parent"
    echo '{"phase": "completed"}' > "${BUILD_DIR}/operations/parent/state.json"

    run is_after_op_merged "parent"
    assert_failure
}

# ============================================================================
# Name validation tests (extracted from v0-feature logic)
# ============================================================================

validate_operation_name() {
    local name="$1"
    [[ "${name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]
}

@test "name validation accepts valid lowercase name" {
    run validate_operation_name "valid-feature-name"
    assert_success
}

@test "name validation accepts name with numbers" {
    run validate_operation_name "feature-123"
    assert_success
}

@test "name validation accepts uppercase letters" {
    run validate_operation_name "Feature-Name"
    assert_success
}

@test "name validation accepts single word" {
    run validate_operation_name "feature"
    assert_success
}

@test "name validation rejects underscore" {
    run validate_operation_name "feature_with_underscore"
    assert_failure
}

@test "name validation rejects name starting with number" {
    run validate_operation_name "123-starts-with-number"
    assert_failure
}

@test "name validation rejects name starting with hyphen" {
    run validate_operation_name "-starts-with-hyphen"
    assert_failure
}

@test "name validation rejects empty string" {
    run validate_operation_name ""
    assert_failure
}

@test "name validation rejects special characters" {
    run validate_operation_name "feature@special"
    assert_failure
}

@test "name validation rejects spaces" {
    run validate_operation_name "feature with spaces"
    assert_failure
}

# ============================================================================
# Circular dependency detection tests
# ============================================================================

check_circular_dependency() {
    local start_op="$1"
    local current_op="$2"
    local visited="$3"

    # Check if we've visited this node
    if [[ "${visited}" == *":${current_op}:"* ]]; then
        echo "circular dependency detected"
        return 1
    fi

    # Get the after dependency
    local state_file="${BUILD_DIR}/operations/${current_op}/state.json"
    if [ ! -f "${state_file}" ]; then
        return 0
    fi

    local after
    after=$(jq -r '.after // empty' "${state_file}")
    if [ -z "${after}" ]; then
        return 0
    fi

    # Recurse
    check_circular_dependency "${start_op}" "${after}" "${visited}:${current_op}:"
}

@test "circular dependency detection catches simple cycle" {
    # Setup: A depends on B, B depends on A
    mkdir -p "${BUILD_DIR}/operations/feature-a" "${BUILD_DIR}/operations/feature-b"
    echo '{"name": "feature-a", "after": "feature-b"}' > "${BUILD_DIR}/operations/feature-a/state.json"
    echo '{"name": "feature-b", "after": "feature-a"}' > "${BUILD_DIR}/operations/feature-b/state.json"

    run check_circular_dependency "feature-a" "feature-b" ":feature-a:"
    assert_failure
    assert_output --partial "circular"
}

@test "circular dependency detection allows valid chain" {
    # Setup: A depends on B, B depends on C (no cycle)
    mkdir -p "${BUILD_DIR}/operations/feature-a" "${BUILD_DIR}/operations/feature-b" "${BUILD_DIR}/operations/feature-c"
    echo '{"name": "feature-a", "after": "feature-b"}' > "${BUILD_DIR}/operations/feature-a/state.json"
    echo '{"name": "feature-b", "after": "feature-c"}' > "${BUILD_DIR}/operations/feature-b/state.json"
    echo '{"name": "feature-c"}' > "${BUILD_DIR}/operations/feature-c/state.json"

    run check_circular_dependency "feature-a" "feature-b" ":feature-a:"
    assert_success
}

@test "circular dependency detection handles missing operation" {
    mkdir -p "${BUILD_DIR}/operations/feature-a"
    echo '{"name": "feature-a", "after": "nonexistent"}' > "${BUILD_DIR}/operations/feature-a/state.json"

    run check_circular_dependency "feature-a" "nonexistent" ":feature-a:"
    assert_success
}

# ============================================================================
# State phase transitions tests
# ============================================================================

@test "state transitions from init to planned" {
    local NAME="test-op"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    cp "${TESTS_DIR}/fixtures/states/init-state.json" "${STATE_FILE}"

    update_state "phase" '"planned"'

    run get_state "phase"
    assert_output "planned"
}

@test "state transitions from executing to completed" {
    local NAME="test-feature"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    cp "${TESTS_DIR}/fixtures/states/executing-state.json" "${STATE_FILE}"

    update_state "phase" '"completed"'
    update_state "completed_at" '"2026-01-15T12:00:00Z"'

    run get_state "phase"
    assert_output "completed"

    run get_state "completed_at"
    assert_output "2026-01-15T12:00:00Z"
}

@test "state with dependency stores after field" {
    local NAME="child-feature"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    cp "${TESTS_DIR}/fixtures/states/with-dependency.json" "${STATE_FILE}"

    run get_state "after"
    assert_output "parent-feature"
}

# ============================================================================
# on-complete.sh issue closing tests
# ============================================================================

# Helper to create on-complete.sh script for testing
create_on_complete_script() {
    local op_name="$1"
    local state_file="$2"
    local script_path="${TEST_TEMP_DIR}/on-complete.sh"

    cat > "${script_path}" <<WRAPPER
#!/bin/bash
STATE_FILE="${state_file}"
OP_NAME="${op_name}"

# Safety net: Close any remaining open issues (handles bypassed stop hooks)
OPEN_IDS=\$(wk list --label "plan:\${OP_NAME}" --status todo 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+' || true)
IN_PROGRESS_IDS=\$(wk list --label "plan:\${OP_NAME}" --status in_progress 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+' || true)
ALL_OPEN_IDS="\${OPEN_IDS} \${IN_PROGRESS_IDS}"
ALL_OPEN_IDS=\$(echo "\${ALL_OPEN_IDS}" | xargs)  # Trim whitespace
if [[ -n "\${ALL_OPEN_IDS}" ]]; then
  echo "Closing remaining issues: \${ALL_OPEN_IDS}"
  # shellcheck disable=SC2086
  wk done \${ALL_OPEN_IDS} --reason "Auto-closed by on-complete handler" 2>/dev/null || true
fi

COMPLETED_JSON=\$(wk list --format json --label "plan:\${OP_NAME}" --status done 2>/dev/null | jq '[.issues[].id]' || echo '[]')
if [[ "\${COMPLETED_JSON}" != "[]" ]]; then
  tmp=\$(mktemp)
  jq ".completed = \${COMPLETED_JSON}" "\${STATE_FILE}" > "\${tmp}" && mv "\${tmp}" "\${STATE_FILE}"
fi

tmp=\$(mktemp)
jq '.phase = "completed" | .completed_at = "'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'"' "\${STATE_FILE}" > "\${tmp}" && mv "\${tmp}" "\${STATE_FILE}"
WRAPPER
    chmod +x "${script_path}"
    echo "${script_path}"
}

@test "on-complete closes remaining todo issues before recording" {
    local NAME="test-feature"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-feature", "phase": "executing"}' > "${STATE_FILE}"

    # Create mock wk that tracks calls and returns issues
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/wk" <<'EOF'
#!/bin/bash
echo "$@" >> "$TEST_TEMP_DIR/wk.log"
if [[ "$1" == "list" ]] && [[ "$*" == *"--status todo"* ]]; then
    echo "testp-1234 - Open task"
fi
if [[ "$1" == "list" ]] && [[ "$*" == *"--status in_progress"* ]]; then
    echo "testp-5678 - In progress task"
fi
if [[ "$1" == "list" ]] && [[ "$*" == *"--status done"* ]]; then
    echo '{"issues":[{"id":"testp-1234"},{"id":"testp-5678"}]}'
fi
if [[ "$1" == "done" ]]; then
    echo "Marking done: $*" >> "$TEST_TEMP_DIR/wk.log"
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/wk"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    # Create and run on-complete script
    local script
    script=$(create_on_complete_script "${NAME}" "${STATE_FILE}")
    run bash "${script}"
    assert_success

    # Verify wk done was called with both issue IDs
    run cat "${TEST_TEMP_DIR}/wk.log"
    assert_output --partial "done testp-1234 testp-5678"
    assert_output --partial "Auto-closed by on-complete handler"
}

@test "on-complete handles no remaining issues gracefully" {
    local NAME="test-feature"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-feature", "phase": "executing"}' > "${STATE_FILE}"

    # Create mock wk that returns no issues
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/wk" <<'EOF'
#!/bin/bash
echo "$@" >> "$TEST_TEMP_DIR/wk.log"
if [[ "$1" == "list" ]] && [[ "$*" == *"--status done"* ]]; then
    echo '{"issues":[]}'
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/wk"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    # Create and run on-complete script
    local script
    script=$(create_on_complete_script "${NAME}" "${STATE_FILE}")
    run bash "${script}"
    assert_success

    # Verify wk done was NOT called (no issues to close)
    run cat "${TEST_TEMP_DIR}/wk.log"
    refute_output --partial "done testp"
}

@test "on-complete updates phase to completed" {
    local NAME="test-feature"
    source_state_functions "${NAME}"

    mkdir -p "${STATE_DIR}"
    echo '{"name": "test-feature", "phase": "executing"}' > "${STATE_FILE}"

    # Create mock wk that returns no issues
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/wk" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]] && [[ "$*" == *"--status done"* ]]; then
    echo '{"issues":[]}'
fi
exit 0
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/wk"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    # Create and run on-complete script
    local script
    script=$(create_on_complete_script "${NAME}" "${STATE_FILE}")
    run bash "${script}"
    assert_success

    # Verify phase was updated
    run jq -r '.phase' "${STATE_FILE}"
    assert_output "completed"

    # Verify completed_at was set
    run jq -r '.completed_at' "${STATE_FILE}"
    refute_output "null"
}
