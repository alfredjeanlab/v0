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

# ============================================================================
# Batching tests
# ============================================================================

@test "_status_init_blocker_cache populates cache with issue data" {
  mock_wk_show "v0-epic1" '{"id": "v0-epic1", "blockers": []}'
  mock_wk_show "v0-epic2" '{"id": "v0-epic2", "blockers": []}'

  _status_init_blocker_cache "v0-epic1" "v0-epic2"

  # Cache should contain both issues
  [[ "${_STATUS_ISSUE_CACHE}" == *"v0-epic1"* ]]
  [[ "${_STATUS_ISSUE_CACHE}" == *"v0-epic2"* ]]
}

@test "_status_init_blocker_cache fetches blockers in second batch" {
  mock_wk_show "v0-epic" '{"id": "v0-epic", "blockers": ["v0-blocker"]}'
  mock_wk_show "v0-blocker" '{"id": "v0-blocker", "status": "todo", "labels": ["plan:auth"]}'

  _status_init_blocker_cache "v0-epic"

  # Cache should contain both epic and its blocker
  [[ "${_STATUS_ISSUE_CACHE}" == *"v0-epic"* ]]
  [[ "${_STATUS_ISSUE_CACHE}" == *"v0-blocker"* ]]
}

@test "_status_init_blocker_cache skips empty and null IDs" {
  mock_wk_show "v0-epic" '{"id": "v0-epic", "blockers": []}'

  _status_init_blocker_cache "" "null" "v0-epic"

  # Should only have the valid epic
  [[ "${_STATUS_ISSUE_CACHE}" == *"v0-epic"* ]]
}

@test "_status_cache_lookup returns cached data" {
  mock_wk_show "v0-epic" '{"id": "v0-epic", "status": "todo", "blockers": []}'
  _status_init_blocker_cache "v0-epic"

  # Field 1 is ID, field 2 is status
  run _status_cache_lookup "v0-epic" 1
  assert_success
  assert_output "v0-epic"

  run _status_cache_lookup "v0-epic" 2
  assert_success
  assert_output "todo"
}

@test "_status_cache_lookup returns empty for uncached issue" {
  _STATUS_ISSUE_CACHE=""

  run _status_cache_lookup "v0-unknown" 1
  assert_success
  assert_output ""
}

@test "_status_get_blocker_display uses cache instead of wk call" {
  # Set up cache directly in TSV format: id<TAB>status<TAB>blockers<TAB>plan_label
  # Note: Using printf to ensure proper tab characters
  _STATUS_ISSUE_CACHE=$(printf '%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s' \
    "v0-epic" "" "v0-blocker" "" \
    "v0-blocker" "todo" "" "plan:cached-op")

  # Should use cache - no wk mocks needed
  run _status_get_blocker_display "v0-epic"
  assert_success
  assert_output "cached-op"
}

@test "_status_batch_get_blockers returns blocked operations" {
  mock_wk_show "v0-epic1" '{"id": "v0-epic1", "blockers": ["v0-blocker"]}'
  mock_wk_show "v0-epic2" '{"id": "v0-epic2", "blockers": []}'
  mock_wk_show "v0-blocker" '{"id": "v0-blocker", "status": "todo", "labels": ["plan:auth"]}'

  run _status_batch_get_blockers "v0-epic1" "v0-epic2"
  assert_success
  # Should only output blocked epic with its blocker display
  assert_output "v0-epic1	auth"
}

@test "_status_batch_get_blockers handles multiple blocked operations" {
  mock_wk_show "v0-epic1" '{"id": "v0-epic1", "blockers": ["v0-blocker1"]}'
  mock_wk_show "v0-epic2" '{"id": "v0-epic2", "blockers": ["v0-blocker2"]}'
  mock_wk_show "v0-blocker1" '{"id": "v0-blocker1", "status": "todo", "labels": ["plan:op1"]}'
  mock_wk_show "v0-blocker2" '{"id": "v0-blocker2", "status": "todo", "labels": ["plan:op2"]}'

  run _status_batch_get_blockers "v0-epic1" "v0-epic2"
  assert_success
  assert_line "v0-epic1	op1"
  assert_line "v0-epic2	op2"
}
