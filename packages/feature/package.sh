# Package: feature
# SPDX-License-Identifier: MIT
#
# Feature workflows - initialization, session monitoring, completion handling.
# Orchestrates feature development lifecycle.

PKG_NAME="feature"
PKG_DEPS=(core state worker)
PKG_EXPORTS=(lib/feature.sh)
PKG_TEST_ONLY=false
