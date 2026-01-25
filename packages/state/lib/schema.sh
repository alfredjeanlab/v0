#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/schema.sh - Schema versioning and migration
#
# This module provides:
# - Schema migration
# - Auto-migration on access
# - Phase access with schema check
#
# External commands: date (via sm_bulk_update_state, sm_emit_event)

# Requires: SM_STATE_VERSION from rules.sh
# Requires: sm_get_state_file from rules.sh
# Requires: sm_bulk_update_state, sm_get_state_version, sm_read_state from io.sh
# Requires: sm_emit_event from logging.sh

# ============================================================================
# Schema Versioning Functions
# ============================================================================

# sm_migrate_state <op>
# Migrate state file to current schema version
sm_migrate_state() {
  local op="$1"
  local version
  version=$(sm_get_state_version "${op}")

  # Already current
  [[ "${version}" -ge "${SM_STATE_VERSION}" ]] && return 0

  # Migration from v0 (legacy) to v1
  if [[ "${version}" -eq 0 ]]; then
    sm_bulk_update_state "${op}" \
      "_schema_version" "${SM_STATE_VERSION}" \
      "_migrated_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    sm_emit_event "${op}" "schema:migrated" "v0 -> v${SM_STATE_VERSION}"
  fi

  # Future migrations: v1 -> v2, etc.
  # if [[ "${version}" -eq 1 ]]; then
  #   # migrate v1 -> v2
  # fi
}

# sm_ensure_current_schema <op>
# Called by transition functions to auto-migrate on first access
sm_ensure_current_schema() {
  local op="$1"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  # Skip if no state file
  [[ ! -f "${state_file}" ]] && return 0

  local version
  version=$(jq -r '._schema_version // 0' "${state_file}")
  if [[ "${version}" -lt "${SM_STATE_VERSION}" ]]; then
    sm_migrate_state "${op}"
  fi
}

# sm_get_phase <op>
# Get current phase of an operation
sm_get_phase() {
  local op="$1"
  sm_ensure_current_schema "${op}"
  sm_read_state "${op}" "phase"
}
