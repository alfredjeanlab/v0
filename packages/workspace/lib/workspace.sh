#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# workspace/workspace.sh - Main entry point for workspace package
#
# Provides functions for managing the dedicated workspace where merge
# operations happen. The workspace keeps V0_ROOT clean by performing
# all git checkout/merge operations in an isolated directory.
#
# Depends on: core
# PURE: path functions are pure; creation/validation functions have side effects

# Get the directory containing this script
_WS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source workspace modules
source "${_WS_LIB_DIR}/paths.sh"
source "${_WS_LIB_DIR}/create.sh"
source "${_WS_LIB_DIR}/validate.sh"
