#!/usr/bin/env bats
# Tests for v0-prime - Quick-start guide
load '../packages/test-support/helpers/test_helper'

@test "v0 prime shows quick-start guide" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 Quick Start"
}

@test "v0 prime shows core workflows" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "Fix a bug"
    assert_output --partial "Run a feature pipeline"
    assert_output --partial "Process chores"
}

@test "v0 prime shows essential commands" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 status"
    assert_output --partial "v0 attach"
}

@test "v0 prime references full help" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 --help"
}

@test "v0 prime works without project config" {
    # Run outside any project directory
    cd /tmp
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 Quick Start"
}

@test "v0-prime can be called directly" {
    run "${PROJECT_ROOT}/bin/v0-prime"
    assert_success
    assert_output --partial "v0 Quick Start"
}

@test "v0 help shows prime command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "prime"
    assert_output --partial "Quick-start guide"
}
