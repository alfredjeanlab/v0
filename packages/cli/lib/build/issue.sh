#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Issue filing utilities for v0-build
# Source this file to get issue filing functions

# create_feature_issue <name>
# Creates a feature issue with a placeholder description
# Arguments:
#   $1 = operation name
# Returns: issue ID on stdout, or empty string on failure
create_feature_issue() {
  local name="$1"
  local title="Plan: ${name}"

  # Create feature issue with placeholder description, -o id returns just the issue ID
  local issue_id wk_err
  wk_err=$(mktemp)
  issue_id=$(wk new feature "${title}" --description "Planning in progress..." -o id 2>"${wk_err}") || {
    echo "create_feature_issue: wk new failed: $(cat "${wk_err}")" >&2
    rm -f "${wk_err}"
    return 1
  }
  rm -f "${wk_err}"

  if [[ -z "${issue_id}" ]]; then
    echo "create_feature_issue: wk new returned empty ID" >&2
    return 1
  fi

  # Add plan label so issue can be resolved to operation name
  # This is needed for dependency tracking when blocked operations are resumed
  if ! wk label "${issue_id}" "plan:${name}" >/dev/null 2>&1; then
    echo "create_feature_issue: warning: failed to add label to ${issue_id}" >&2
  fi

  echo "${issue_id}"
}

# file_plan_issue <name> <plan_file> [existing_id] [prompt]
# Creates or updates a feature issue with plan content
# Arguments:
#   $1 = operation name (basename of plan)
#   $2 = path to plan file
#   $3 = (optional) existing issue ID to update instead of creating new
#   $4 = (optional) original prompt to include in description
# Returns: issue ID on stdout, or empty string on failure
# Logs progress to stderr for debugging
file_plan_issue() {
  local name="$1"
  local plan_file="$2"
  local existing_id="${3:-}"
  local prompt="${4:-}"
  local title="Plan: ${name}"
  local description

  # Read plan file contents as description
  if [[ ! -f "${plan_file}" ]]; then
    echo "file_plan_issue: plan file not found: ${plan_file}" >&2
    return 1
  fi
  description=$(cat "${plan_file}")

  # Prepend original prompt if provided
  if [[ -n "${prompt}" ]]; then
    description="Prompt: ${prompt}
---
${description}"
  fi

  local issue_id
  if [[ -n "${existing_id}" ]]; then
    # Update existing issue
    issue_id="${existing_id}"
  else
    # Create new issue (backwards compatibility), -o id returns just the issue ID
    local wk_err
    wk_err=$(mktemp)
    issue_id=$(wk new feature "${title}" -o id 2>"${wk_err}") || {
      echo "file_plan_issue: wk new failed: $(cat "${wk_err}")" >&2
      rm -f "${wk_err}"
      return 1
    }
    rm -f "${wk_err}"

    if [[ -z "${issue_id}" ]]; then
      echo "file_plan_issue: wk new returned empty ID" >&2
      return 1
    fi
  fi

  # Set the description (plan content)
  if ! wk edit "${issue_id}" description "${description}" >/dev/null 2>&1; then
    echo "file_plan_issue: warning: failed to set description for ${issue_id}" >&2
  fi

  # Add label
  if ! wk label "${issue_id}" "plan:${name}" >/dev/null 2>&1; then
    echo "file_plan_issue: warning: failed to add label to ${issue_id}" >&2
  fi

  echo "${issue_id}"
}
