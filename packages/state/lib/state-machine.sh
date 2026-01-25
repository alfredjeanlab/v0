#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# state-machine.sh - Compatibility shim
#
# This file exists for backward compatibility.
# All functionality is now in lib/operations/*.sh

_SM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SM_LIB_DIR}/state.sh"
