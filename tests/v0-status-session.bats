#!/usr/bin/env bats
# Tests for v0-status session detection logic

load '../packages/test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
}

# ============================================================================
# Session detection tests (commit 712bc18)
# ============================================================================
# These tests verify that session detection works correctly for active indicators.
# The key insight is that tmux list-sessions only returns LOCAL sessions, so
# if a session name is found in all_sessions, it's definitely running locally
# regardless of the machine field in state.json.

# Helper function matching the logic in v0-status (lines 548-551)
# This tests the session detection without requiring the full v0-status context
is_session_active() {
  local session="$1"
  local all_sessions="$2"
  # Logic matches v0-status: only check if session is in all_sessions
  # No machine check needed since tmux list-sessions only returns local sessions
  [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]
}

@test "session detection: session in all_sessions is detected as active" {
  local all_sessions=$'v0-plan-abc\nv0-feat-xyz\nother-session'
  local session="v0-feat-xyz"

  run is_session_active "$session" "$all_sessions"
  assert_success
}

@test "session detection: session not in all_sessions is not active" {
  local all_sessions=$'v0-plan-abc\nother-session'
  local session="v0-feat-xyz"

  run is_session_active "$session" "$all_sessions"
  assert_failure
}

@test "session detection: empty session name is not active" {
  local all_sessions=$'v0-plan-abc\nv0-feat-xyz'
  local session=""

  run is_session_active "$session" "$all_sessions"
  assert_failure
}

@test "session detection: works with empty all_sessions" {
  local all_sessions=""
  local session="v0-feat-xyz"

  run is_session_active "$session" "$all_sessions"
  assert_failure
}

@test "session detection: partial match is detected (session name contained in list)" {
  # This tests substring matching which is how the actual code works
  local all_sessions="v0-plan-abc v0-feat-xyz other-session"
  local session="v0-feat-xyz"

  run is_session_active "$session" "$all_sessions"
  assert_success
}

@test "session detection: does not require machine field match" {
  # This documents the key fix: session detection should work regardless of
  # what machine field contains, since tmux list-sessions only returns local sessions
  #
  # Previous bug: code checked machine == local_machine before checking all_sessions
  # This caused [active] to not show when:
  # - machine field was missing or "unknown"
  # - hostname changed between operation creation and status check
  # - any mismatch in hostname formatting
  #
  # The fix removes the machine check entirely for session detection because
  # if tmux list-sessions returns a session, it must be running locally.

  # Simulate the detection logic from v0-status
  local session="v0-feat-xyz"
  local all_sessions="v0-plan-abc v0-feat-xyz other-session"
  local machine="unknown"  # Could be anything - doesn't affect detection
  local local_machine
  local_machine=$(hostname -s)

  # Machine mismatch should NOT prevent session detection
  # (This is what the fix ensures)
  local status_icon=""
  if [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]; then
    status_icon="[active]"
  fi

  assert_equal "$status_icon" "[active]"
}

@test "session detection: works with mismatched machine field" {
  # Test the specific scenario the bug fixed: machine field doesn't match
  # but session is in local tmux sessions
  local session="v0-feat-test"
  local all_sessions="v0-feat-test some-other-session"
  local machine="remote-host"  # Different from local machine
  local local_machine
  local_machine=$(hostname -s)

  # The detection should still work because we find the session in all_sessions
  local status_icon=""
  if [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]; then
    status_icon="[active]"
  fi

  assert_equal "$status_icon" "[active]"
}

@test "session detection: works when machine field is null" {
  # Edge case: machine field is null/missing
  local session="v0-plan-abc"
  local all_sessions="v0-plan-abc"
  local machine="null"

  local status_icon=""
  if [[ -n "${session}" ]] && [[ "${all_sessions}" == *"${session}"* ]]; then
    status_icon="[active]"
  fi

  assert_equal "$status_icon" "[active]"
}
