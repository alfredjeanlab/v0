# Implementation Plan: v0 prime

**Root Feature:** `v0-99e9`

## Overview

Add a new `v0 prime` command that outputs a minimal, focused quick-start guide for v0. This is analogous to `wk prime` vs `wk help` - it shows core use cases with concise examples and references where to get more information, rather than the full help text.

## Project Structure

```
bin/
  v0           # Update: add prime to NO_CONFIG_COMMANDS and dispatch
  v0-prime     # New: prime command implementation
tests/unit/
  v0-prime.bats  # New: tests for prime command
```

**Files to create:**
- `bin/v0-prime` - The prime command script

**Files to modify:**
- `bin/v0` - Add prime to command routing

**Files to create for testing:**
- `tests/unit/v0-prime.bats` - Unit tests

## Dependencies

None - uses only shell builtins.

## Implementation Phases

### Phase 1: Create v0-prime command

Create `bin/v0-prime` following the pattern of other simple commands like `v0-talk`.

**Key design decisions:**
- NO_CONFIG command (works without `.v0.rc`)
- Simple heredoc output, similar to `wk prime`
- Focus on 3-4 core workflows with examples
- Reference `v0 --help` and documentation for more info

```bash
#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# v0-prime - Quick-start guide for v0

cat <<'EOF'
# v0 Quick Start

> **Context Recovery**: Run `v0 prime` after compaction, clear, or new session

## Core Workflows

**Fix a bug:**
```bash
v0 fix "Description of the bug"    # Submit bug to fix worker
v0 attach fix                       # Watch progress
```

**Run a feature pipeline:**
```bash
v0 feature auth "Add JWT auth"      # Full pipeline: plan → decompose → execute → merge
v0 status                           # Check progress
v0 attach feature/auth              # Watch specific feature
```

**Just create a plan:**
```bash
v0 plan api "Build REST API"        # Create plan only
v0 decompose api                    # Then decompose to issues
```

**Process chores:**
```bash
v0 chore "Update dependencies"      # Submit chore (works without project)
v0 attach chore                     # Watch progress
```

## Essential Commands
- `v0 status` - Show all operations
- `v0 watch` - Continuous status monitoring
- `v0 attach <type>` - Attach to worker tmux session
- `v0 cancel <name>` - Cancel a running operation

## Getting Started
```bash
v0 init                             # Initialize project (creates .v0.rc)
v0 startup                          # Start background workers
```

## More Info
- `v0 --help` - Full command reference
- `v0 <command> --help` - Command-specific help
EOF
```

### Phase 2: Update v0 dispatcher

Modify `bin/v0` to route the prime command:

1. Add `prime` to `NO_CONFIG_COMMANDS` (line 25):
```bash
NO_CONFIG_COMMANDS="init help version coffee talk prime"
```

2. Add prime to the dispatch case statement (around line 224-226):
```bash
  # No-config commands
  talk|coffee|prime)
    exec "${V0_DIR}/bin/v0-${CMD}" "$@"
    ;;
```

3. Add prime to the help text in `show_help()` (around line 91-93, after coffee):
```
  prime         Quick-start guide (run after context loss)
```

### Phase 3: Add tests

Create `tests/unit/v0-prime.bats`:

```bash
#!/usr/bin/env bats
# Tests for v0-prime - Quick-start guide
load '../helpers/test_helper'

@test "v0 prime shows quick-start guide" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 Quick Start"
}

@test "v0 prime shows core workflows" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "Fix a bug"
    assert_output --partial "Run a feature pipeline"
    assert_output --partial "Process chores"
}

@test "v0 prime shows essential commands" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 status"
    assert_output --partial "v0 attach"
}

@test "v0 prime references full help" {
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 --help"
}

@test "v0 prime works without project config" {
    # Run outside any project directory
    cd /tmp
    run "${PROJECT_ROOT}/bin/v0" prime
    assert_success
    assert_output --partial "v0 Quick Start"
}

@test "v0-prime can be called directly" {
    run "${PROJECT_ROOT}/bin/v0-prime"
    assert_success
    assert_output --partial "v0 Quick Start"
}

@test "v0 help shows prime command" {
    run "${PROJECT_ROOT}/bin/v0" --help
    assert_success
    assert_output --partial "prime"
    assert_output --partial "Quick-start guide"
}
```

## Key Implementation Details

### Content Design (following wk prime pattern)

The `wk prime` output follows this pattern:
1. **Header** - Title with context recovery hint
2. **Core Rules** - When to use the tool
3. **Finding Work** - Common read operations
4. **Creating & Updating** - Common write operations
5. **Common Workflows** - Concrete examples with code blocks

For `v0 prime`, adapt this to:
1. **Header** - Title with context recovery hint
2. **Core Workflows** - 3-4 primary use cases with examples
3. **Essential Commands** - Quick reference to common commands
4. **Getting Started** - Initialization commands
5. **More Info** - Reference to full help

### Help Text Placement

In the main help (`bin/v0`), place prime in a logical location:
- After `coffee` in the misc/utility section
- Or create a new "Quick Reference" section

Current relevant section (lines 91-93):
```
  talk          Open claude with haiku model for quick conversations
  coffee        Keep computer awake
  issue         Alias for 'wk' issue tracker (see 'wk --help')
```

Add prime before `talk`:
```
  prime         Quick-start guide (run after context loss)
  talk          Open claude with haiku model for quick conversations
```

## Verification Plan

### Manual Testing
1. Run `v0 prime` and verify output is readable and useful
2. Run `v0 prime` outside a project directory (should work)
3. Run `v0 --help` and verify prime appears in the command list
4. Verify the context recovery hint is visible

### Automated Testing
```bash
make lint                                    # Check for shell issues
make test-file FILE=tests/unit/v0-prime.bats # Run prime tests
make test                                    # Run all tests
```

### Test Checklist
- [ ] `v0 prime` outputs the quick-start guide
- [ ] Works without `.v0.rc` (NO_CONFIG command)
- [ ] `v0 --help` lists the prime command
- [ ] All new tests pass
- [ ] Lint passes with no warnings
