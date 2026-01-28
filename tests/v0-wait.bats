#!/usr/bin/env bats
# v0-wait.bats - Tests for v0-wait script

load '../packages/test-support/helpers/test_helper'

V0_WAIT="${PROJECT_ROOT}/bin/v0-wait"

setup_isolated_project() {
    local isolated_dir="${TEST_TEMP_DIR}/isolated"
    mkdir -p "${isolated_dir}/project/.v0/build/operations"
    cat > "${isolated_dir}/project/.v0.rc" <<EOF
PROJECT="testproject"
ISSUE_PREFIX="test"
EOF
    echo "${isolated_dir}/project"
}

create_isolated_operation() {
    local project_dir="$1"
    local op_name="$2"
    local json_content="$3"
    local op_dir="${project_dir}/.v0/build/operations/${op_name}"
    mkdir -p "${op_dir}"
    echo "${json_content}" > "${op_dir}/state.json"
}

setup() {
    _base_setup
}

# ============================================================================
# Help and Usage Tests
# ============================================================================

@test "v0-wait: --help shows usage" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --help
    '
    assert_success
    assert_output --partial "Usage: v0 wait"
    assert_output --partial "Wait for an operation"
}

@test "v0-wait: requires target" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'"
    '
    assert_failure
    assert_output --partial "Target (operation, roadmap, or issue) required"
}

@test "v0-wait: unknown option shows error" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option"
}

# ============================================================================
# Immediate Completion Tests
# ============================================================================

@test "v0-wait: returns 0 for merged operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: returns 1 for cancelled operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "cancelled", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_failure
    [ "$status" -eq 1 ]
    assert_output --partial "failed or was cancelled"
}

@test "v0-wait: returns 3 for non-existent operation" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" nonexistent
    '
    assert_failure
    [ "$status" -eq 3 ]
    assert_output --partial "not found"
}

# ============================================================================
# Issue ID Tests
# ============================================================================

@test "v0-wait: finds operation by issue ID" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine", "epic_id": "TEST-123"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --issue TEST-123
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: returns 3 for unknown issue ID" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" --issue UNKNOWN-999
    '
    assert_failure
    [ "$status" -eq 3 ]
    assert_output --partial "No work found for issue"
}

# ============================================================================
# Timeout Tests
# ============================================================================

@test "v0-wait: timeout returns 2 for non-terminal operation" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout 1s
    '
    assert_failure
    [ "$status" -eq 2 ]
    assert_output --partial "Timeout"
}

@test "v0-wait: parses duration formats correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "executing", "machine": "testmachine"}'

    # Test seconds format
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout 1s
    '
    assert_failure
    [ "$status" -eq 2 ]

    # Test invalid format
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout invalid
    '
    assert_failure
    assert_output --partial "Invalid duration format"
}

# ============================================================================
# Quiet Mode Tests
# ============================================================================

@test "v0-wait: --quiet suppresses progress output" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --quiet
    '
    assert_success
    assert_output ""
}

# ============================================================================
# v0 Command Integration Tests
# ============================================================================

@test "v0 wait command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${PROJECT_ROOT}"'/bin/v0" wait --help
    '
    assert_success
    assert_output --partial "Usage: v0 wait"
}

@test "v0 --help shows wait command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "wait"
}

# ============================================================================
# Auto-detect Issue ID Tests
# ============================================================================

@test "v0-wait: auto-detects issue ID without --issue flag" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" \
      '{"name": "testop", "phase": "merged", "machine": "testmachine", "epic_id": "test-abc123"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-abc123
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: operation name takes precedence over issue ID pattern" {
    # If someone names an operation with a pattern like issue ID, it should work as operation name
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "test-abc" \
      '{"name": "test-abc", "phase": "merged", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-abc
    '
    assert_success
    assert_output --partial "completed successfully"
}

# ============================================================================
# Bug Fix State Tests
# ============================================================================

@test "v0-wait: waits for bug fix completion by issue ID" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create fix state
    mkdir -p "${project_dir}/.v0/build/fix/test-bug123"
    echo '{"issue_id": "test-bug123", "status": "pushed"}' > \
      "${project_dir}/.v0/build/fix/test-bug123/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-bug123
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: waits for in-progress bug fix with timeout" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create fix state that's in progress
    mkdir -p "${project_dir}/.v0/build/fix/test-bug456"
    echo '{"issue_id": "test-bug456", "status": "started"}' > \
      "${project_dir}/.v0/build/fix/test-bug456/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-bug456 --timeout 1s
    '
    assert_failure
    [ "$status" -eq 2 ]
    assert_output --partial "Timeout"
}

# ============================================================================
# Chore State Tests
# ============================================================================

@test "v0-wait: waits for chore completion with pushed status" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create chore state with pushed status
    mkdir -p "${project_dir}/.v0/build/chore/test-chore456"
    echo '{"issue_id": "test-chore456", "status": "pushed"}' > \
      "${project_dir}/.v0/build/chore/test-chore456/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-chore456
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: waits for chore completion with completed status" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create chore state with completed status (standalone mode)
    mkdir -p "${project_dir}/.v0/build/chore/test-chore789"
    echo '{"issue_id": "test-chore789", "status": "completed"}' > \
      "${project_dir}/.v0/build/chore/test-chore789/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-chore789
    '
    assert_success
    assert_output --partial "completed successfully"
}

# ============================================================================
# Roadmap State Tests
# ============================================================================

@test "v0-wait: waits for roadmap by name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create roadmap state
    mkdir -p "${project_dir}/.v0/build/roadmaps/myproject"
    echo '{"name": "myproject", "phase": "completed"}' > \
      "${project_dir}/.v0/build/roadmaps/myproject/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" myproject
    '
    assert_success
    assert_output --partial "Waiting for 'roadmap:myproject'"
    assert_output --partial "completed successfully"
}

@test "v0-wait: waits for roadmap by idea_id" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create roadmap state with idea_id
    mkdir -p "${project_dir}/.v0/build/roadmaps/api-rewrite"
    echo '{"name": "api-rewrite", "phase": "completed", "idea_id": "test-idea123"}' > \
      "${project_dir}/.v0/build/roadmaps/api-rewrite/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-idea123
    '
    assert_success
    assert_output --partial "completed successfully"
}

@test "v0-wait: roadmap failed state returns exit code 1" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create roadmap state with failed phase
    mkdir -p "${project_dir}/.v0/build/roadmaps/failing"
    echo '{"name": "failing", "phase": "failed"}' > \
      "${project_dir}/.v0/build/roadmaps/failing/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" failing
    '
    assert_failure
    [ "$status" -eq 1 ]
    assert_output --partial "failed or was cancelled"
}

@test "v0-wait: roadmap interrupted state returns exit code 1" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Create roadmap state with interrupted phase
    mkdir -p "${project_dir}/.v0/build/roadmaps/interrupted"
    echo '{"name": "interrupted", "phase": "interrupted"}' > \
      "${project_dir}/.v0/build/roadmaps/interrupted/state.json"

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" interrupted
    '
    assert_failure
    [ "$status" -eq 1 ]
    assert_output --partial "failed or was cancelled"
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "v0-wait: not found for unknown name returns exit code 3" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" unknownname
    '
    assert_failure
    [ "$status" -eq 3 ]
    assert_output --partial "not found"
}

# ============================================================================
# Held Operation Tests
# ============================================================================

@test "v0-wait: held operation returns exit code 4" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "planned", "machine": "testmachine", "held": true}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_failure
    [ "$status" -eq 4 ]
}

@test "v0-wait: held operation shows paused message" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "planned", "machine": "testmachine", "held": true}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_failure
    assert_output --partial "paused (held)"
}

@test "v0-wait: held operation shows resume hint" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "planned", "machine": "testmachine", "held": true}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop
    '
    assert_failure
    assert_output --partial "v0 resume testop"
}

@test "v0-wait: --quiet suppresses held message but returns 4" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "planned", "machine": "testmachine", "held": true}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --quiet
    '
    assert_failure
    [ "$status" -eq 4 ]
    assert_output ""
}

@test "v0-wait: held operation via issue ID returns exit code 4" {
    local project_dir
    project_dir=$(setup_isolated_project)
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "planned", "machine": "testmachine", "held": true, "epic_id": "test-held123"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" test-held123
    '
    assert_failure
    [ "$status" -eq 4 ]
    assert_output --partial "paused (held)"
}

@test "v0-wait: non-held planned operation times out" {
    local project_dir
    project_dir=$(setup_isolated_project)
    # Planned but NOT held - should timeout, not return held status
    create_isolated_operation "${project_dir}" "testop" '{"name": "testop", "phase": "planned", "machine": "testmachine"}'

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u BUILD_DIR bash -c '
        cd "'"${project_dir}"'" || exit 1
        "'"${V0_WAIT}"'" testop --timeout 1s
    '
    assert_failure
    [ "$status" -eq 2 ]
    assert_output --partial "Timeout"
}
