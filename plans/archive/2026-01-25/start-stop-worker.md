# Implementation Plan: Start/Stop Worker Commands

## Overview

Add `v0 start` and `v0 stop` commands that accept an optional worker/operation name, providing a simpler interface for starting and stopping individual workers. These commands serve as convenient aliases that delegate to existing `v0 <worker> --start` and `v0 <worker> --stop` functionality.

**Examples:**
- `v0 start` - Start all workers (equivalent to `v0 startup`)
- `v0 start fix` - Start fix worker (equivalent to `v0 fix --start`)
- `v0 stop` - Stop all workers (equivalent to `v0 shutdown`)
- `v0 stop fix` - Stop fix worker (equivalent to `v0 fix --stop`)

## Project Structure

```
v0/
├── bin/
│   ├── v0              # Entry point (modify to add start/stop routing)
│   ├── v0-start        # NEW: Start command
│   └── v0-stop         # NEW: Stop command
└── tests/
    ├── v0-start.bats   # NEW: Start command tests
    └── v0-stop.bats    # NEW: Stop command tests
```

## Dependencies

No new external dependencies required. Uses existing:
- `v0-startup` for starting all workers
- `v0-shutdown` for stopping all workers
- `v0-fix`, `v0-chore`, `v0-mergeq` for individual worker control

## Implementation Phases

### Phase 1: Create v0-start Command

Create `bin/v0-start` that handles starting workers.

**File: `bin/v0-start`**

```bash
#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# v0-start - Start v0 workers
set -e

V0_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${V0_DIR}/packages/cli/lib/v0-common.sh"

# Valid worker types
VALID_WORKERS="fix chore mergeq"

usage() {
  v0_help <<'EOF'
Usage: v0 start [worker] [options]

Start v0 workers.

Workers:
  fix       Start the bug fix worker
  chore     Start the chore worker
  mergeq    Start the merge queue daemon

If no worker is specified, starts all workers (equivalent to 'v0 startup').

Options:
  --dry-run      Show what would be started without starting
  -h, --help     Show this help

Examples:
  v0 start              # Start all workers
  v0 start fix          # Start only the fix worker
  v0 start chore        # Start only the chore worker
  v0 start --dry-run    # Preview what would be started
EOF
  exit 0
}

DRY_RUN=""
WORKER=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    -h|--help)
      usage
      ;;
    fix|chore|mergeq)
      if [[ -n "${WORKER}" ]]; then
        echo "Error: Only one worker can be specified" >&2
        echo "To start multiple workers, run: v0 startup $WORKER $1" >&2
        exit 1
      fi
      WORKER="$1"
      shift
      ;;
    *)
      echo "Unknown option or worker: $1" >&2
      echo "Valid workers: ${VALID_WORKERS}" >&2
      echo "Run 'v0 start --help' for usage" >&2
      exit 1
      ;;
  esac
done

# Dispatch to appropriate command
if [[ -z "${WORKER}" ]]; then
  # No worker specified, start all
  exec "${V0_DIR}/bin/v0-startup" ${DRY_RUN}
else
  # Specific worker
  if [[ -n "${DRY_RUN}" ]]; then
    echo "Would run: v0 ${WORKER} --start"
  else
    exec "${V0_DIR}/bin/v0-${WORKER}" --start
  fi
fi
```

**Verification:**
- `v0 start --help` shows usage
- `v0 start` starts all workers (delegates to startup)
- `v0 start fix` starts fix worker
- `v0 start invalid` shows error

---

### Phase 2: Create v0-stop Command

Create `bin/v0-stop` that handles stopping workers.

**File: `bin/v0-stop`**

```bash
#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# v0-stop - Stop v0 workers
set -e

V0_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${V0_DIR}/packages/cli/lib/v0-common.sh"

# Valid worker types
VALID_WORKERS="fix chore mergeq"

usage() {
  v0_help <<'EOF'
Usage: v0 stop [worker] [options]

Stop v0 workers.

Workers:
  fix       Stop the bug fix worker
  chore     Stop the chore worker
  mergeq    Stop the merge queue daemon

If no worker is specified, performs full shutdown (equivalent to 'v0 shutdown').

Options:
  --force        Force stop (for full shutdown: delete branches with unmerged commits)
  --dry-run      Show what would be stopped without stopping
  -h, --help     Show this help

Examples:
  v0 stop               # Stop all workers (full shutdown)
  v0 stop fix           # Stop only the fix worker
  v0 stop chore         # Stop only the chore worker
  v0 stop --force       # Force stop all workers
  v0 stop --dry-run     # Preview what would be stopped
EOF
  exit 0
}

DRY_RUN=""
FORCE=""
WORKER=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    --force)
      FORCE="--force"
      shift
      ;;
    -h|--help)
      usage
      ;;
    fix|chore|mergeq)
      if [[ -n "${WORKER}" ]]; then
        echo "Error: Only one worker can be specified" >&2
        echo "To stop all workers, run: v0 shutdown" >&2
        exit 1
      fi
      WORKER="$1"
      shift
      ;;
    *)
      echo "Unknown option or worker: $1" >&2
      echo "Valid workers: ${VALID_WORKERS}" >&2
      echo "Run 'v0 stop --help' for usage" >&2
      exit 1
      ;;
  esac
done

# Dispatch to appropriate command
if [[ -z "${WORKER}" ]]; then
  # No worker specified, full shutdown
  exec "${V0_DIR}/bin/v0-shutdown" ${FORCE} ${DRY_RUN}
else
  # Specific worker
  if [[ -n "${DRY_RUN}" ]]; then
    echo "Would run: v0 ${WORKER} --stop"
  else
    if [[ -n "${FORCE}" ]]; then
      echo "Note: --force has no effect on individual worker stop" >&2
    fi
    exec "${V0_DIR}/bin/v0-${WORKER}" --stop
  fi
fi
```

**Verification:**
- `v0 stop --help` shows usage
- `v0 stop` performs full shutdown (delegates to shutdown)
- `v0 stop fix` stops fix worker
- `v0 stop --force` passes force flag to shutdown

---

### Phase 3: Update Main Entry Point

Modify `bin/v0` to route `start` and `stop` commands.

**Changes to `bin/v0`:**

1. Add `start` and `stop` to `PROJECT_COMMANDS` (line 19):
```bash
PROJECT_COMMANDS="plan tree merge mergeq status build feature resume fix attach cancel shutdown startup start stop hold roadmap pull push archive"
```

2. Add `start` and `stop` to the dispatch case (line 206):
```bash
  plan|tree|merge|mergeq|status|watch|build|fix|attach|cancel|shutdown|startup|start|stop|prune|monitor|hold|roadmap|pull|push|archive)
```

3. Update help text to include new commands (in `show_help` function):
```bash
  start         Start worker(s) - alias for startup/worker --start
  stop          Stop worker(s) - alias for shutdown/worker --stop
```

**Verification:**
- `v0 start` routes to `v0-start`
- `v0 stop` routes to `v0-stop`
- `v0 --help` shows new commands

---

### Phase 4: Add Integration Tests

Create test files for the new commands.

**File: `tests/v0-start.bats`**

```bash
#!/usr/bin/env bats
load '../packages/test-support/helpers/test_helper'

setup() {
    setup_test_repo
}

teardown() {
    teardown_test_repo
}

@test "start shows usage with --help" {
    run "${PROJECT_ROOT}/bin/v0-start" --help
    assert_success
    assert_output --partial "Usage: v0 start"
}

@test "start with invalid worker shows error" {
    run "${PROJECT_ROOT}/bin/v0-start" invalid
    assert_failure
    assert_output --partial "Unknown option or worker"
}

@test "start --dry-run shows what would happen" {
    run "${PROJECT_ROOT}/bin/v0-start" --dry-run
    assert_success
    assert_output --partial "Would start"
}

@test "start fix --dry-run shows single worker" {
    run "${PROJECT_ROOT}/bin/v0-start" fix --dry-run
    assert_success
    assert_output --partial "Would run: v0 fix --start"
}
```

**File: `tests/v0-stop.bats`**

```bash
#!/usr/bin/env bats
load '../packages/test-support/helpers/test_helper'

setup() {
    setup_test_repo
}

teardown() {
    teardown_test_repo
}

@test "stop shows usage with --help" {
    run "${PROJECT_ROOT}/bin/v0-stop" --help
    assert_success
    assert_output --partial "Usage: v0 stop"
}

@test "stop with invalid worker shows error" {
    run "${PROJECT_ROOT}/bin/v0-stop" invalid
    assert_failure
    assert_output --partial "Unknown option or worker"
}

@test "stop --dry-run shows what would happen" {
    run "${PROJECT_ROOT}/bin/v0-stop" --dry-run
    assert_success
}

@test "stop fix --dry-run shows single worker" {
    run "${PROJECT_ROOT}/bin/v0-stop" fix --dry-run
    assert_success
    assert_output --partial "Would run: v0 fix --stop"
}
```

**Verification:**
- `scripts/test v0-start` passes
- `scripts/test v0-stop` passes

---

### Phase 5: Documentation and Polish

1. Update help text in existing files if needed
2. Ensure consistent error messages
3. Run full test suite

**Verification:**
- `make check` passes
- `v0 --help` displays new commands correctly

## Key Implementation Details

### Command Delegation Pattern

The new commands delegate to existing functionality rather than reimplementing:

```
v0 start        -> v0 startup (all workers + coffee + nudge)
v0 start fix    -> v0 fix --start (single worker)
v0 stop         -> v0 shutdown (full cleanup)
v0 stop fix     -> v0 fix --stop (single worker)
```

This ensures:
- Consistent behavior with existing commands
- No duplication of start/stop logic
- Automatic benefit from future improvements to startup/shutdown

### Error Handling

- Invalid worker names show helpful error with list of valid workers
- Multiple workers in single command rejected with suggestion to use `startup`
- `--force` flag only applicable to full shutdown, warning shown for individual workers

### Argument Order Flexibility

Both commands accept arguments in any order:
```bash
v0 start fix --dry-run
v0 start --dry-run fix
v0 stop --force fix
v0 stop fix --force
```

## Verification Plan

### Unit Tests
Each phase has specific verification steps listed above.

### Integration Testing
1. Start a fresh project with `v0 init`
2. Test command routing:
   - `v0 start --help`
   - `v0 stop --help`
3. Test worker control (with `--dry-run` first):
   - `v0 start fix --dry-run`
   - `v0 stop fix --dry-run`
4. Test full start/stop cycle (manual):
   - `v0 start fix`
   - `v0 attach fix` (verify running)
   - `v0 stop fix`
   - `v0 start` (all workers)
   - `v0 stop`

### Full Test Suite
```bash
make check        # Run all lints and tests
scripts/test v0-start v0-stop  # Run specific tests
```
