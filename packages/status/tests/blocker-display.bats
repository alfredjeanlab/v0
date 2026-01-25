#!/usr/bin/env bats
# blocker-display.bats - Tests for blocker display helper

load '../../test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  setup_wk_mocks
  source "${PROJECT_ROOT}/packages/status/lib/blocker-display.sh"
}

@test "_status_get_blocker_display returns empty for no epic_id" {
  run _status_get_blocker_display ""
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display returns empty for null epic_id" {
  run _status_get_blocker_display "null"
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display returns op name for open blocker" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-blocker"]}'
  mock_wk_show "v0-blocker" '{"status": "todo", "labels": ["plan:auth"]}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "auth"
}

@test "_status_get_blocker_display skips closed blockers" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-closed", "v0-open"]}'
  mock_wk_show "v0-closed" '{"status": "done", "labels": ["plan:done-op"]}'
  mock_wk_show "v0-open" '{"status": "todo", "labels": ["plan:real-blocker"]}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "real-blocker"
}

@test "_status_get_blocker_display returns empty when all blockers resolved" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-done1", "v0-done2"]}'
  mock_wk_show "v0-done1" '{"status": "done", "labels": []}'
  mock_wk_show "v0-done2" '{"status": "closed", "labels": []}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display returns issue ID when no plan label" {
  mock_wk_show "v0-epic" '{"blockers": ["v0-ext-issue"]}'
  mock_wk_show "v0-ext-issue" '{"status": "todo", "labels": ["bug"]}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "v0-ext-issue"
}

@test "_status_get_blocker_display returns empty when no blockers" {
  mock_wk_show "v0-epic" '{"blockers": []}'

  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output ""
}
