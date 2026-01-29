#!/usr/bin/env bats
# timestamps.bats - Unit tests for timestamp formatting functions

load '../../test-support/helpers/test_helper'

setup() {
  _base_setup
  setup_v0_env
  source "${PROJECT_ROOT}/packages/status/lib/timestamps.sh"
}

# ============================================================================
# timestamp_to_epoch() tests
# ============================================================================

@test "timestamp_to_epoch converts valid ISO8601" {
  run timestamp_to_epoch "2026-01-15T10:30:00Z"
  assert_success
  # Output should be a valid epoch (numeric)
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "timestamp_to_epoch handles midnight" {
  run timestamp_to_epoch "2026-01-15T00:00:00Z"
  assert_success
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "timestamp_to_epoch handles end of day" {
  run timestamp_to_epoch "2026-01-15T23:59:59Z"
  assert_success
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "timestamp_to_epoch returns reasonable value" {
  local epoch
  epoch=$(timestamp_to_epoch "2026-01-15T10:00:00Z")

  # Should be after Jan 1 2026 (1767225600) and before Jan 1 2027 (1798761600)
  [ "$epoch" -gt 1767225600 ]
  [ "$epoch" -lt 1798761600 ]
}

# ============================================================================
# format_elapsed() tests
# ============================================================================

@test "format_elapsed shows 'just now' for under 60 seconds" {
  run format_elapsed 0
  assert_output "just now"

  run format_elapsed 30
  assert_output "just now"

  run format_elapsed 59
  assert_output "just now"
}

@test "format_elapsed shows minutes for 60-3599 seconds" {
  run format_elapsed 60
  assert_output "1 min ago"
}

@test "format_elapsed shows minutes for 90 seconds" {
  run format_elapsed 90
  assert_output "1 min ago"
}

@test "format_elapsed shows correct minutes" {
  run format_elapsed 180
  assert_output "3 min ago"
}

@test "format_elapsed shows minutes at boundary" {
  run format_elapsed 3599
  assert_output "59 min ago"
}

@test "format_elapsed shows hours for 3600+ seconds" {
  run format_elapsed 3600
  assert_output "1 hr ago"
}

@test "format_elapsed shows correct hours" {
  run format_elapsed 7200
  assert_output "2 hr ago"
}

@test "format_elapsed shows days for 86400+ seconds" {
  run format_elapsed 86400
  assert_output "1 day ago"
}

# ============================================================================
# format_elapsed_extended tests (alternative formatting)
# ============================================================================

# Extended version that handles days with different formatting
format_elapsed_extended() {
  local seconds="$1"
  if [ "$seconds" -lt 60 ]; then
    echo "${seconds}s"
  elif [ "$seconds" -lt 3600 ]; then
    local mins=$((seconds / 60))
    local secs=$((seconds % 60))
    echo "${mins}m ${secs}s"
  elif [ "$seconds" -lt 86400 ]; then
    local hours=$((seconds / 3600))
    local mins=$(( (seconds % 3600) / 60 ))
    echo "${hours}h ${mins}m"
  else
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    echo "${days}d ${hours}h"
  fi
}

@test "format_elapsed_extended handles seconds" {
  run format_elapsed_extended 30
  assert_output "30s"
}

@test "format_elapsed_extended handles minutes and seconds" {
  run format_elapsed_extended 90
  assert_output "1m 30s"
}

@test "format_elapsed_extended handles hours and minutes" {
  run format_elapsed_extended 3665
  assert_output "1h 1m"
}

@test "format_elapsed_extended handles days and hours" {
  run format_elapsed_extended 90000
  assert_output "1d 1h"
}

@test "format_elapsed_extended handles exactly 1 day" {
  run format_elapsed_extended 86400
  assert_output "1d 0h"
}

@test "format_elapsed_extended handles 2 days" {
  run format_elapsed_extended 172800
  assert_output "2d 0h"
}

# ============================================================================
# format_elapsed with day support tests
# ============================================================================

@test "format_elapsed shows multiple days" {
  run format_elapsed 172800
  assert_output "2 day ago"
}

@test "format_elapsed shows hours under 24h" {
  run format_elapsed 7200
  assert_output "2 hr ago"
}

# ============================================================================
# get_last_updated_timestamp() tests
# ============================================================================

@test "get_last_updated_timestamp returns merged_at for merged phase" {
  run get_last_updated_timestamp "merged" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "2026-01-03T10:00:00Z" "null"
  assert_success
  assert_output "2026-01-03T10:00:00Z"
}

@test "get_last_updated_timestamp returns completed_at for completed phase" {
  run get_last_updated_timestamp "completed" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "null" "null"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp returns completed_at for pending_merge phase" {
  run get_last_updated_timestamp "pending_merge" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "null" "null"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp returns held_at for held phase" {
  run get_last_updated_timestamp "held" "2026-01-01T10:00:00Z" "null" "null" "2026-01-04T10:00:00Z"
  assert_success
  assert_output "2026-01-04T10:00:00Z"
}

@test "get_last_updated_timestamp returns updated_at for init phase when available" {
  run get_last_updated_timestamp "init" "2026-01-01T10:00:00Z" "null" "null" "null" "2026-01-02T10:00:00Z"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at for init phase when updated_at is null" {
  run get_last_updated_timestamp "init" "2026-01-01T10:00:00Z" "null" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp returns updated_at for planned phase when available" {
  run get_last_updated_timestamp "planned" "2026-01-01T10:00:00Z" "null" "null" "null" "2026-01-02T10:00:00Z"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at for planned phase when updated_at is null" {
  run get_last_updated_timestamp "planned" "2026-01-01T10:00:00Z" "null" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp returns updated_at for queued phase when available" {
  run get_last_updated_timestamp "queued" "2026-01-01T10:00:00Z" "null" "null" "null" "2026-01-02T10:00:00Z"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at for queued phase when updated_at is null" {
  run get_last_updated_timestamp "queued" "2026-01-01T10:00:00Z" "null" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp returns updated_at for executing phase when available" {
  run get_last_updated_timestamp "executing" "2026-01-01T10:00:00Z" "null" "null" "null" "2026-01-02T10:00:00Z"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at for executing phase when updated_at is null" {
  run get_last_updated_timestamp "executing" "2026-01-01T10:00:00Z" "null" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to completed_at when merged_at is null for merged phase" {
  run get_last_updated_timestamp "merged" "2026-01-01T10:00:00Z" "2026-01-02T10:00:00Z" "null" "null"
  assert_success
  assert_output "2026-01-02T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at when merged_at and completed_at are null for merged phase" {
  run get_last_updated_timestamp "merged" "2026-01-01T10:00:00Z" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at when completed_at is null for completed phase" {
  run get_last_updated_timestamp "completed" "2026-01-01T10:00:00Z" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}

@test "get_last_updated_timestamp falls back to created_at when held_at is null for held phase" {
  run get_last_updated_timestamp "held" "2026-01-01T10:00:00Z" "null" "null" "null"
  assert_success
  assert_output "2026-01-01T10:00:00Z"
}
