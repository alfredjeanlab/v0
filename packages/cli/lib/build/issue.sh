#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Issue filing utilities for v0-build
# Source this file to get issue filing functions

# file_plan_issue <name> <plan_file>
# Creates a single feature issue for the plan
# Arguments:
#   $1 = operation name (basename of plan)
#   $2 = path to plan file
# Returns: issue ID on stdout, or empty string on failure
# Logs progress to stderr for debugging
file_plan_issue() {
  local name="$1"
  local plan_file="$2"
  local title="Plan: ${name}"
  local description

  # Read plan file contents as description
  if [[ ! -f "${plan_file}" ]]; then
    echo "file_plan_issue: plan file not found: ${plan_file}" >&2
    return 1
  fi
  description=$(cat "${plan_file}")

  # Create feature issue and extract ID from output
  # Output format: "Created [feature] (todo) v0-abc1: Title"
  local issue_id output wk_err
  wk_err=$(mktemp)
  output=$(wk new feature "${title}" 2>"${wk_err}") || {
    echo "file_plan_issue: wk new failed: $(cat "${wk_err}")" >&2
    rm -f "${wk_err}"
    return 1
  }
  rm -f "${wk_err}"

  issue_id=$(echo "${output}" | grep -oE '\) [a-zA-Z0-9-]+:' | sed 's/^) //; s/:$//')

  if [[ -z "${issue_id}" ]]; then
    echo "file_plan_issue: failed to extract issue ID from: ${output}" >&2
    return 1
  fi

  # Set the description (plan content)
  if ! wk edit "${issue_id}" description "${description}" 2>/dev/null; then
    echo "file_plan_issue: warning: failed to set description for ${issue_id}" >&2
  fi

  # Add label
  if ! wk label "${issue_id}" "plan:${name}" 2>/dev/null; then
    echo "file_plan_issue: warning: failed to add label to ${issue_id}" >&2
  fi

  echo "${issue_id}"
}
