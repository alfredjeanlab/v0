#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Grep wrapper that prefers ripgrep (rg) when available
# Source this file to get grep utilities

# Grep command to use (set by _v0_init_grep)
_V0_GREP_CMD=""

# Initialize grep command detection (call once at script start)
# Sets _V0_GREP_CMD to "rg" if ripgrep is available, otherwise "grep"
_v0_init_grep() {
  if command -v rg >/dev/null 2>&1; then
    _V0_GREP_CMD="rg"
  else
    _V0_GREP_CMD="grep"
  fi
}

# Auto-initialize on source
_v0_init_grep

# v0_grep - Basic grep replacement
# Supports common grep options, translating to rg equivalents when using ripgrep
# Usage: v0_grep [options] pattern [file...]
# Options: -q (quiet), -o (only matching), -E (extended regex), -F (fixed strings),
#          -c (count), -v (invert), -n (line numbers), -m N (max count)
v0_grep() {
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    _v0_grep_rg "$@"
  else
    grep "$@"
  fi
}

# Internal: translate grep options to rg and execute
_v0_grep_rg() {
  local rg_args=()
  local pattern=""
  local files=()
  local skip_next=false

  for arg in "$@"; do
    if $skip_next; then
      rg_args+=("$arg")
      skip_next=false
      continue
    fi

    case "$arg" in
      -E)
        # Extended regex is rg default, skip
        ;;
      -m[0-9]*)
        # -m1 -> -m 1 (rg requires space)
        local count="${arg#-m}"
        rg_args+=("-m" "$count")
        ;;
      -m)
        # -m N format, next arg is count
        rg_args+=("-m")
        skip_next=true
        ;;
      -oE|-Eo)
        # Combined -oE or -Eo: just -o for rg
        rg_args+=("-o")
        ;;
      -qE|-Eq)
        # Combined -qE or -Eq: just -q for rg
        rg_args+=("-q")
        ;;
      -qF|-Fq)
        # Combined -qF or -Fq
        rg_args+=("-q" "-F")
        ;;
      -q|-o|-c|-v|-F|-n|-i|-l|-w)
        # Direct mappings
        rg_args+=("$arg")
        ;;
      -*)
        # Pass through other options
        rg_args+=("$arg")
        ;;
      *)
        if [[ -z "$pattern" ]]; then
          pattern="$arg"
        else
          files+=("$arg")
        fi
        ;;
    esac
  done

  if [[ -n "$pattern" ]]; then
    if [[ ${#files[@]} -gt 0 ]]; then
      rg "${rg_args[@]}" -- "$pattern" "${files[@]}"
    else
      rg "${rg_args[@]}" -- "$pattern"
    fi
  else
    # No pattern provided, let rg handle the error
    rg "${rg_args[@]}"
  fi
}

# v0_grep_quiet - Check if pattern matches (silent, exit code only)
# Usage: v0_grep_quiet pattern [file...]
# Returns: 0 on match, 1 on no match
v0_grep_quiet() {
  local pattern="$1"
  shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -q -- "$pattern" "$@"
  else
    grep -q -- "$pattern" "$@"
  fi
}

# v0_grep_extract - Extract matching portions of lines
# Usage: v0_grep_extract pattern [file...]
# Outputs: Only the matched text, not the full line
v0_grep_extract() {
  local pattern="$1"
  shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -o -- "$pattern" "$@"
  else
    grep -oE -- "$pattern" "$@"
  fi
}

# v0_grep_count - Count matching lines
# Usage: v0_grep_count pattern [file...]
# Outputs: Number of matching lines (0 if no matches)
v0_grep_count() {
  local pattern="$1"
  shift
  local count
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    # rg -c outputs nothing on no matches, so we need || echo "0"
    count=$(rg -c -- "$pattern" "$@" 2>/dev/null) || true
    echo "${count:-0}"
  else
    # grep -c always outputs a number, even on no matches (returns exit 1 but outputs "0")
    grep -c -- "$pattern" "$@" 2>/dev/null || true
  fi
}

# v0_grep_invert - Output lines that do NOT match
# Usage: v0_grep_invert pattern [file...]
v0_grep_invert() {
  local pattern="$1"
  shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -v -- "$pattern" "$@"
  else
    grep -v -- "$pattern" "$@"
  fi
}

# v0_grep_first - Find first match and stop (like grep -m1)
# Usage: v0_grep_first pattern [file...]
# Outputs: First matching line only
v0_grep_first() {
  local pattern="$1"
  shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -m 1 -- "$pattern" "$@"
  else
    grep -m1 -- "$pattern" "$@"
  fi
}

# v0_grep_fixed - Match literal string (no regex interpretation)
# Usage: v0_grep_fixed string [file...]
v0_grep_fixed() {
  local string="$1"
  shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -F -- "$string" "$@"
  else
    grep -F -- "$string" "$@"
  fi
}

# v0_grep_fixed_quiet - Fixed string quiet check (-qF)
# Usage: v0_grep_fixed_quiet string [file...]
# Returns: 0 if fixed string found, 1 otherwise
v0_grep_fixed_quiet() {
  local string="$1"
  shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -qF -- "$string" "$@"
  else
    grep -qF -- "$string" "$@"
  fi
}
