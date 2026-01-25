#!/usr/bin/env bats
# blocking.bats - Unit tests for blocking.sh functions

load '../../test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  setup_wk_mocks
  # blocking.sh has dependencies on other libs
  source_lib "io.sh"           # sm_read_state
  source_lib "logging.sh"      # sm_emit_event
  source_lib "v0-common.sh"    # v0_get_first_open_blocker, v0_is_blocked, etc.
  source_lib "blocking.sh"
}

@test "sm_is_blocked returns false when no epic_id" {
  create_operation_state "test-op" "queued"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_is_blocked returns false when epic_id is null" {
  create_operation_state "test-op" "queued" "null"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_is_blocked returns true when wok has open blockers" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"], "status": "todo"}'
  mock_wk_show "v0-blocker1" '{"status": "in_progress"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocked "test-op"
  assert_success
}

@test "sm_is_blocked returns false when all blockers done" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"], "status": "todo"}'
  mock_wk_show "v0-blocker1" '{"status": "done"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocked "test-op"
  assert_failure
}

@test "sm_get_blocker returns empty when no blockers" {
  mock_wk_show "v0-epic123" '{"blockers": [], "status": "todo"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output ""
}

@test "sm_get_blocker returns operation name when plan label exists" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "todo", "labels": ["plan:auth-feature"]}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output "auth-feature"
}

@test "sm_get_blocker returns issue ID when no plan label" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "todo", "labels": []}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output "v0-blocker1"
}

@test "sm_get_blocker skips closed blockers" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-closed", "v0-open"]}'
  mock_wk_show "v0-closed" '{"status": "done", "labels": []}'
  mock_wk_show "v0-open" '{"status": "todo", "labels": ["plan:real-blocker"]}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_get_blocker "test-op"
  assert_success
  assert_output "real-blocker"
}

@test "sm_is_blocker_merged returns true when no epic_id" {
  create_operation_state "test-op" "queued"

  run sm_is_blocker_merged "test-op"
  assert_success
}

@test "sm_is_blocker_merged returns true when no open blockers" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "done"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocker_merged "test-op"
  assert_success
}

@test "sm_is_blocker_merged returns false when open blockers exist" {
  mock_wk_show "v0-epic123" '{"blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-blocker1" '{"status": "in_progress"}'
  create_operation_state "test-op" "queued" "v0-epic123"

  run sm_is_blocker_merged "test-op"
  assert_failure
}

@test "sm_find_dependents returns operations blocked by given op" {
  # merged-op blocks dependent-op
  mock_wk_show "v0-merged" '{"blocking": ["v0-dependent"]}'
  mock_wk_show "v0-dependent" '{"labels": ["plan:dependent-op"]}'
  create_operation_state "merged-op" "merged" "v0-merged"
  create_operation_state "dependent-op" "queued" "v0-dependent"

  run sm_find_dependents "merged-op"
  assert_success
  assert_output "dependent-op"
}

@test "sm_find_dependents ignores non-operation issues" {
  mock_wk_show "v0-merged" '{"blocking": ["v0-random-issue"]}'
  mock_wk_show "v0-random-issue" '{"labels": []}'
  create_operation_state "merged-op" "merged" "v0-merged"

  run sm_find_dependents "merged-op"
  assert_success
  assert_output ""
}
