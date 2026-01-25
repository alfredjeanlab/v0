#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# Feature module aggregator
# Source this file to get all feature utilities

_FEATURE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all feature modules
source "${_FEATURE_LIB_DIR}/init.sh"
source "${_FEATURE_LIB_DIR}/session-monitor.sh"
source "${_FEATURE_LIB_DIR}/on-complete.sh"
