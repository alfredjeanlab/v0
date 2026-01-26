#!/usr/bin/env bats
# Tests for v0 mayor command
load '../packages/test-support/helpers/test_helper'

@test "v0 mayor --help shows usage" {
    run "${PROJECT_ROOT}/bin/v0" mayor --help
    assert_success
    assert_output --partial "orchestration assistant"
    assert_output --partial "Plan and dispatch features"
}

@test "v0 mayor prompt file exists" {
    [[ -f "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md" ]]
}

@test "v0 mayor prompt contains required sections" {
    run cat "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md"
    assert_success
    assert_output --partial "v0 prime"
    assert_output --partial "wk prime"
    assert_output --partial "Dispatching Work"
}

@test "v0 mayor prompt contains monitoring commands" {
    run cat "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md"
    assert_success
    assert_output --partial "v0 status"
    assert_output --partial "v0 attach"
}

@test "v0 mayor prompt contains managing commands" {
    run cat "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md"
    assert_success
    assert_output --partial "v0 cancel"
    assert_output --partial "v0 hold"
    assert_output --partial "v0 resume"
}

@test "v0 mayor prompt contains issue tracking section" {
    run cat "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md"
    assert_success
    assert_output --partial "Issue Tracking"
    assert_output --partial "wk list"
    assert_output --partial "wk show"
    assert_output --partial "wk new"
}

@test "v0 mayor prompt contains guidelines" {
    run cat "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md"
    assert_success
    assert_output --partial "clarifying questions"
    assert_output --partial "breaking down"
    assert_output --partial "Check status"
}

@test "v0 mayor prompt contains context recovery" {
    run cat "${PROJECT_ROOT}/packages/cli/lib/prompts/mayor.md"
    assert_success
    assert_output --partial "Context Recovery"
    assert_output --partial "after compaction"
}

@test "v0-mayor can be called directly with --help" {
    run "${PROJECT_ROOT}/bin/v0-mayor" --help
    assert_success
    assert_output --partial "orchestration assistant"
}

@test "v0 mayor help mentions model option" {
    run "${PROJECT_ROOT}/bin/v0" mayor --help
    assert_success
    assert_output --partial "--model"
    assert_output --partial "opus"
}

@test "v0 mayor help shows examples" {
    run "${PROJECT_ROOT}/bin/v0" mayor --help
    assert_success
    assert_output --partial "Examples:"
    assert_output --partial "v0 mayor"
    assert_output --partial "--model sonnet"
}
