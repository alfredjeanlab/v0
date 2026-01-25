#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# operations/io.sh - JSON file read/write operations
#
# This module provides:
# - Single field read/update
# - Bulk field updates (atomic)
# - Batch read optimization
# - Full state read as associative array
#
# External commands: jq, mktemp, mv, rm

# Requires: sm_get_state_file from rules.sh

# ============================================================================
# State File Operations
# ============================================================================

# sm_read_state <op> <field>
# Read a field from state file
# Returns: field value, empty if not found
sm_read_state() {
  local op="$1"
  local field="$2"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  jq -r ".${field} // empty" "${state_file}"
}

# sm_update_state <op> <field> <value>
# Update a single field in state file
# Value should be a valid JSON value (quoted strings, numbers, etc.)
sm_update_state() {
  local op="$1"
  local field="$2"
  local value="$3"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  if jq ".${field} = ${value}" "${state_file}" > "${tmp}"; then
    mv "${tmp}" "${state_file}"
    return 0
  else
    rm -f "${tmp}"
    return 1
  fi
}

# sm_bulk_update_state <op> <field1> <value1> [<field2> <value2> ...]
# Update multiple fields atomically in state file
# Values should be valid JSON values
sm_bulk_update_state() {
  local op="$1"
  shift
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  local jq_filter="."

  while [[ $# -gt 0 ]]; do
    local field="$1"
    local value="$2"
    jq_filter="${jq_filter} | .${field} = ${value}"
    shift 2
  done

  if jq "${jq_filter}" "${state_file}" > "${tmp}"; then
    mv "${tmp}" "${state_file}"
    return 0
  else
    rm -f "${tmp}"
    return 1
  fi
}

# ============================================================================
# Batch State Reads (Performance Optimization)
# ============================================================================

# sm_read_state_fields <op> <field1> [field2] [field3] ...
# Read multiple fields in a single jq invocation
# Returns tab-separated values in order requested
sm_read_state_fields() {
  local op="$1"
  shift
  local state_file
  state_file=$(sm_get_state_file "${op}")

  [[ ! -f "${state_file}" ]] && return 1

  # Build jq filter: [.field1, .field2, ...] | @tsv
  local fields=()
  for field in "$@"; do
    fields+=(".${field} // empty")
  done
  local filter
  filter="[$(IFS=,; echo "${fields[*]}")] | @tsv"

  jq -r "${filter}" "${state_file}"
}

# sm_read_all_state <op>
# Read entire state file as associative array (bash 4+)
# Usage: declare -A state; sm_read_all_state "op" state
sm_read_all_state() {
  local op="$1"
  local -n _state_ref="$2"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  [[ ! -f "${state_file}" ]] && return 1

  # Read all key-value pairs
  while IFS=$'\t' read -r key value; do
    _state_ref["${key}"]="${value}"
  done < <(jq -r 'to_entries | .[] | [.key, (.value | tostring)] | @tsv' "${state_file}")
}

# sm_get_state_version <op>
# Get schema version from state file (defaults to 0 for legacy files)
sm_get_state_version() {
  local op="$1"
  local state_file
  state_file=$(sm_get_state_file "${op}")

  if [[ ! -f "${state_file}" ]]; then
    return 1
  fi

  local version
  version=$(jq -r '._schema_version // 0' "${state_file}")
  echo "${version}"
}
