# Implementation Plan: v0 self debug

## Overview

Add a `v0 self debug` command that collects comprehensive debug reports when v0 operations fail. The command will gather logs, state files, git status, and context from various sources into a single markdown report with frontmatter-style sections. The command supports debugging specific operations by name or by type (plan, decompose, fix, chore, mergeq/merge, nudge).

## Project Structure

```
bin/
├── v0                      # Update: add 'self-debug' dispatch
└── v0-self-debug           # NEW: main debug report generator

lib/
├── v0-common.sh            # Update: add debug logging helpers
└── debug-common.sh         # NEW: shared debug collection utilities

tests/
└── unit/
    └── v0-self-debug.bats  # NEW: comprehensive unit tests

.v0/build/
└── debug/                  # NEW: debug report output directory
    └── {timestamp}-{name}.md
```

## Dependencies

- Existing: `jq`, `git`, `tmux`, bash 4+
- No new external dependencies required

## Implementation Phases

### Phase 1: Core Debug Collection Infrastructure

**Goal:** Create the foundational debug report generation with basic log collection.

**Files to create/modify:**
- `bin/v0-self-debug` - Main command implementation
- `lib/debug-common.sh` - Shared debug utilities
- Update `bin/v0` to route `self-debug` command

**Key functionality:**
```bash
# Command interface
v0 self debug <operation-name>   # Debug specific operation
v0 self debug plan               # Debug most recent plan operation
v0 self debug decompose          # Debug most recent decompose failure
v0 self debug fix                # Debug fix worker issues
v0 self debug chore              # Debug chore worker issues
v0 self debug mergeq             # Debug merge queue (includes 'merge')
v0 self debug nudge              # Debug nudge daemon

# Options
--output <path>                  # Custom output path (default: .v0/build/debug/)
--stdout                         # Print to stdout instead of file
--verbose                        # Include more verbose logs
```

**Report format:**
```markdown
---
v0-debug-report: true
operation: epic-05a-simulator-core
type: feature
phase: init
status: failed
machine: Wonderous-Sloop
generated_at: 2026-01-18T03:00:00Z
---

# Debug Report: epic-05a-simulator-core

## Summary
Brief description of the failure state...

---
<!-- section: operation-state -->
## Operation State

{contents of state.json formatted as YAML or JSON}

---
<!-- section: operation-logs -->
## Operation Logs

### Feature Log
```
{contents of .v0/build/operations/{name}/logs/feature.log}
```

### Events Log
```
{contents of .v0/build/operations/{name}/logs/events.log}
```

---
<!-- section: git-state -->
## Git State

### Main Repository
```
{git status output}
{git log --oneline -5}
{git branch output}
```

### Worktree (if exists)
```
{worktree git status}
{worktree git log}
```

---
<!-- section: merge-queue -->
## Merge Queue State
{queue.json contents if relevant}

---
<!-- section: related-operations -->
## Related Operations
{state of operations that this depends on via --after}
```

**Milestone:** Can generate basic debug reports for failed operations.

---

### Phase 2: Worker and Daemon Debug Collection

**Goal:** Add debug collection for background workers (fix, chore) and daemons (mergeq, nudge).

**Worker debug collection:**
```bash
# For fix/chore workers, collect:
# 1. Worker PID and status
# 2. Polling log (/tmp/v0-{project}-{type}-polling.log)
# 3. Worker log in worktree (claude-worker.log)
# 4. Worktree state
# 5. Current wk list output
# 6. Backoff state

v0 self debug fix    # Collects fix worker state
v0 self debug chore  # Collects chore worker state
```

**Daemon debug collection:**
```bash
# For mergeq daemon:
# 1. Daemon PID and status
# 2. queue.json state
# 3. daemon.log (tail last 100 lines)
# 4. Any operations in merge phase
# 5. Git state of branches being merged

# For nudge daemon:
# 1. Daemon PID and status
# 2. .nudge.log (tail last 100 lines)
# 3. Active tmux sessions
# 4. Claude session logs (last entries)

v0 self debug mergeq  # Also handles 'merge' alias
v0 self debug nudge
```

**Milestone:** Can debug all worker types and daemons.

---

### Phase 3: Smart Context Inclusion

**Goal:** Automatically include relevant cross-cutting context based on operation type.

**Cross-cutting concerns:**
- Feature operations should include merge queue state if `merge_queued: true`
- Failed operations should include state of dependent operations (`after` field)
- All operations should include recent v0.log entries (last 50 lines filtered to operation)
- Include Claude session log snippets if tmux session exists

**Implementation:**
```bash
# In debug-common.sh
collect_merge_context() {
    local op_name="$1"
    local state_file="${BUILD_DIR}/operations/${op_name}/state.json"

    if jq -e '.merge_queued == true' "$state_file" >/dev/null 2>&1; then
        include_mergeq_state
        include_merge_branch_git_state
    fi
}

collect_dependency_context() {
    local op_name="$1"
    local after=$(jq -r '.after // empty' "$state_file")

    if [[ -n "$after" ]]; then
        include_operation_summary "$after"
    fi
}
```

**Auto-detection logic:**
```bash
v0 self debug epic-05a-simulator-core
# Detects: this is a 'feature' operation
# Includes: operation state, feature log, git state, worktree state
# Also includes: merge queue (since merge_queued may be true)
# Also includes: Claude session log if tmux session exists
```

**Milestone:** Debug reports include all contextually relevant information.

---

### Phase 4: Enhanced Logging (Minimal Performance Impact)

**Goal:** Add strategic trace logging to key operations for better debugging, with minimal performance impact.

**Logging enhancements in `lib/v0-common.sh`:**
```bash
# Add trace logging function (only writes when enabled or when errors occur)
v0_trace() {
    local event="$1"
    local message="$2"
    local trace_file="${BUILD_DIR}/logs/trace.log"

    # Always log to trace file (cheap append)
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ${event}: ${message}" >> "${trace_file}"
}

# Add error context capture
v0_capture_error_context() {
    local context_file="${BUILD_DIR}/logs/error-context.log"
    {
        echo "=== Error Context $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
        echo "PWD: $(pwd)"
        echo "Git branch: $(git branch --show-current 2>/dev/null || echo 'N/A')"
        echo "Git status: $(git status --porcelain 2>/dev/null | head -10)"
    } >> "${context_file}"
}
```

**Strategic trace points (add to existing commands):**
- `v0-feature`: Before/after each phase transition
- `v0-decompose`: Issue creation events
- `v0-plan`: Plan file commit status
- `v0-merge`: Branch state before merge attempt
- `v0-mergeq`: Queue state changes
- Worker polling loops: Iteration counts, backoff state

**Performance considerations:**
- Use append-only file writes (no file locking)
- Keep trace messages short (< 200 chars)
- Rotate trace.log if > 1MB (background check)
- No subprocess spawning for trace logging

**Milestone:** Enhanced logging available without noticeable performance impact.

---

### Phase 5: Unit Tests

**Goal:** Comprehensive test coverage for `v0 self debug` command.

**Test file: `tests/unit/v0-self-debug.bats`**

```bash
#!/usr/bin/env bats

load '../helpers/test_helper'

setup() {
    setup_test_environment
    create_mock_operation "test-feature" "feature" "failed"
    create_mock_worker_state "fix"
    create_mock_mergeq_state
}

teardown() {
    teardown_test_environment
}

# Basic functionality tests
@test "self debug shows help with no arguments" {
    run v0 self debug --help
    assert_success
    assert_output --partial "Usage:"
}

@test "self debug generates report for failed operation" {
    run v0 self debug test-feature
    assert_success
    assert_output --partial "Debug report generated"
    assert [ -f "${BUILD_DIR}/debug/"*"-test-feature.md" ]
}

@test "self debug report contains operation state" {
    run v0 self debug test-feature --stdout
    assert_success
    assert_output --partial "## Operation State"
    assert_output --partial '"phase":'
}

@test "self debug report contains git state" {
    run v0 self debug test-feature --stdout
    assert_success
    assert_output --partial "## Git State"
}

# Type-based collection tests
@test "self debug fix collects worker state" {
    run v0 self debug fix --stdout
    assert_success
    assert_output --partial "## Fix Worker"
    assert_output --partial "polling"
}

@test "self debug mergeq collects queue state" {
    run v0 self debug mergeq --stdout
    assert_success
    assert_output --partial "## Merge Queue"
    assert_output --partial "queue.json"
}

@test "self debug merge is alias for mergeq" {
    run v0 self debug merge --stdout
    assert_success
    assert_output --partial "## Merge Queue"
}

# Cross-cutting context tests
@test "self debug includes merge context for queued operations" {
    create_mock_operation "queued-op" "feature" "building"
    update_operation_state "queued-op" '.merge_queued = true'

    run v0 self debug queued-op --stdout
    assert_success
    assert_output --partial "## Merge Queue State"
}

@test "self debug includes dependency context" {
    create_mock_operation "dep-op" "feature" "blocked"
    update_operation_state "dep-op" '.after = "auth"'
    create_mock_operation "auth" "feature" "building"

    run v0 self debug dep-op --stdout
    assert_success
    assert_output --partial "## Related Operations"
    assert_output --partial "auth"
}

# Output options tests
@test "self debug --output writes to custom path" {
    run v0 self debug test-feature --output /tmp/debug.md
    assert_success
    assert [ -f "/tmp/debug.md" ]
}

@test "self debug --stdout prints to stdout" {
    run v0 self debug test-feature --stdout
    assert_success
    assert_output --partial "---"
    assert_output --partial "v0-debug-report: true"
}

@test "self debug --verbose includes more logs" {
    run v0 self debug test-feature --verbose --stdout
    assert_success
    assert_output --partial "## Verbose Logs"
}

# Error handling tests
@test "self debug fails gracefully for unknown operation" {
    run v0 self debug nonexistent
    assert_failure
    assert_output --partial "Operation not found"
}

@test "self debug handles missing log files gracefully" {
    rm -rf "${BUILD_DIR}/operations/test-feature/logs"
    run v0 self debug test-feature --stdout
    assert_success
    assert_output --partial "No logs found"
}

# Most recent operation tests
@test "self debug plan debugs most recent plan operation" {
    create_mock_operation "old-plan" "plan" "completed"
    sleep 0.1
    create_mock_operation "new-plan" "plan" "failed"

    run v0 self debug plan --stdout
    assert_success
    assert_output --partial "new-plan"
}

@test "self debug decompose debugs most recent decompose failure" {
    create_mock_operation "decompose-fail" "feature" "failed"
    update_operation_state "decompose-fail" '.phase = "decomposing"'

    run v0 self debug decompose --stdout
    assert_success
    assert_output --partial "decompose-fail"
}
```

**Test helpers to add in `tests/helpers/test_helper.bash`:**
```bash
create_mock_operation() {
    local name="$1" type="$2" status="$3"
    local op_dir="${BUILD_DIR}/operations/${name}"
    mkdir -p "${op_dir}/logs"

    cat > "${op_dir}/state.json" << EOF
{
    "name": "${name}",
    "type": "${type}",
    "phase": "init",
    "status": "${status}",
    "machine": "test-machine",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
    echo "Test log entry" > "${op_dir}/logs/events.log"
}

create_mock_worker_state() {
    local type="$1"
    local worker_dir="${STATE_ROOT}/tree/v0-${type}-worker"
    mkdir -p "${worker_dir}"
    echo "12345" > "${worker_dir}/.worker-pid"
    echo "Polling iteration 5" > "/tmp/v0-${PROJECT}-${type}-polling.log"
}

create_mock_mergeq_state() {
    mkdir -p "${BUILD_DIR}/mergeq/logs"
    cat > "${BUILD_DIR}/mergeq/queue.json" << 'EOF'
{"entries": []}
EOF
    echo "Queue daemon started" > "${BUILD_DIR}/mergeq/logs/daemon.log"
}

update_operation_state() {
    local name="$1" jq_expr="$2"
    local state_file="${BUILD_DIR}/operations/${name}/state.json"
    local tmp=$(mktemp)
    jq "${jq_expr}" "${state_file}" > "${tmp}" && mv "${tmp}" "${state_file}"
}
```

**Milestone:** Full test coverage for all debug collection scenarios.

---

### Phase 6: Polish and Integration

**Goal:** Final integration, documentation, and edge case handling.

**Tasks:**
1. Update `bin/v0` dispatcher to route `self-debug` and `self debug` commands
2. Add `--help` documentation
3. Handle edge cases:
   - No operations exist
   - Operation directory missing
   - Partial state (some files missing)
   - Very large log files (truncate with warning)
4. Add log rotation for trace.log in v0-common.sh
5. Run full test suite and fix any failures

**bin/v0 update:**
```bash
# Add to command dispatch
self-debug|self\ debug)
    shift
    exec "${V0_DIR}/bin/v0-self-debug" "$@"
    ;;
```

**Milestone:** Complete, tested, documented command ready for use.

---

## Key Implementation Details

### Report Generation Pattern

```bash
generate_debug_report() {
    local op_name="$1"
    local output_file="$2"

    {
        generate_frontmatter "$op_name"
        echo ""
        generate_summary "$op_name"
        echo ""
        echo "---"
        echo "<!-- section: operation-state -->"
        generate_operation_state "$op_name"
        echo ""
        echo "---"
        echo "<!-- section: operation-logs -->"
        generate_operation_logs "$op_name"
        echo ""
        echo "---"
        echo "<!-- section: git-state -->"
        generate_git_state "$op_name"

        # Conditional sections
        if should_include_merge_context "$op_name"; then
            echo ""
            echo "---"
            echo "<!-- section: merge-queue -->"
            generate_merge_queue_state
        fi

        if has_dependencies "$op_name"; then
            echo ""
            echo "---"
            echo "<!-- section: related-operations -->"
            generate_dependency_context "$op_name"
        fi
    } > "$output_file"
}
```

### Type Detection for Operations

```bash
detect_operation_type() {
    local name="$1"
    local state_file="${BUILD_DIR}/operations/${name}/state.json"

    if [[ -f "$state_file" ]]; then
        jq -r '.type // "unknown"' "$state_file"
    elif [[ "$name" == "fix" || "$name" == "chore" || "$name" == "nudge" ]]; then
        echo "worker"
    elif [[ "$name" == "mergeq" || "$name" == "merge" ]]; then
        echo "daemon"
    elif [[ "$name" == "plan" || "$name" == "decompose" ]]; then
        echo "phase"
    else
        echo "unknown"
    fi
}
```

### Finding Most Recent Operation by Type/Phase

```bash
find_most_recent_by_type() {
    local type="$1"
    local ops_dir="${BUILD_DIR}/operations"

    find "$ops_dir" -name "state.json" -type f -exec \
        sh -c 'jq -r "select(.type == \"$1\") | .name" "$2"' _ "$type" {} \; |
        while read -r name; do
            local created=$(jq -r '.created_at' "${ops_dir}/${name}/state.json")
            echo "${created} ${name}"
        done | sort -r | head -1 | cut -d' ' -f2
}

find_most_recent_by_phase() {
    local phase="$1"
    local ops_dir="${BUILD_DIR}/operations"

    find "$ops_dir" -name "state.json" -type f -exec \
        sh -c 'jq -r "select(.phase == \"$1\" or .blocked_phase == \"$1\") | .name" "$2"' _ "$phase" {} \; |
        while read -r name; do
            local created=$(jq -r '.created_at' "${ops_dir}/${name}/state.json")
            echo "${created} ${name}"
        done | sort -r | head -1 | cut -d' ' -f2
}
```

### Safe Log Inclusion (Handle Large Files)

```bash
include_log_file() {
    local log_file="$1"
    local max_lines="${2:-500}"
    local label="${3:-Log}"

    if [[ ! -f "$log_file" ]]; then
        echo "*No ${label} found*"
        return
    fi

    local line_count=$(wc -l < "$log_file")

    echo '```'
    if (( line_count > max_lines )); then
        echo "# [Truncated: showing last ${max_lines} of ${line_count} lines]"
        tail -n "$max_lines" "$log_file"
    else
        cat "$log_file"
    fi
    echo '```'
}
```

### Trace Logging (Minimal Impact)

```bash
# In lib/v0-common.sh
V0_TRACE_ENABLED="${V0_TRACE_ENABLED:-0}"
V0_TRACE_FILE="${BUILD_DIR}/logs/trace.log"

v0_trace() {
    # Always write to trace file - very cheap operation
    local event="$1"
    shift
    printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$*" >> "${V0_TRACE_FILE}" 2>/dev/null || true
}

# Rotate trace log if too large (called periodically, not on every trace)
v0_trace_rotate() {
    if [[ -f "${V0_TRACE_FILE}" ]]; then
        local size=$(stat -f%z "${V0_TRACE_FILE}" 2>/dev/null || stat -c%s "${V0_TRACE_FILE}" 2>/dev/null || echo 0)
        if (( size > 1048576 )); then  # 1MB
            mv "${V0_TRACE_FILE}" "${V0_TRACE_FILE}.old"
        fi
    fi
}
```

---

## Verification Plan

### Unit Tests
```bash
# Run full test suite
make test

# Run only self-debug tests
bats tests/unit/v0-self-debug.bats
```

### Manual Verification Checklist

1. **Basic operation debug:**
   ```bash
   # Create a failing operation
   v0 feature test-fail "Test failure" --enqueue
   # Manually fail it by corrupting state

   # Generate debug report
   v0 self debug test-fail
   # Verify report contains: state, logs, git state
   ```

2. **Worker debug:**
   ```bash
   v0 fix --start
   v0 self debug fix
   # Verify report contains: PID, polling log, worker state
   ```

3. **Merge queue debug:**
   ```bash
   v0 mergeq --start
   v0 self debug mergeq
   # Verify report contains: queue.json, daemon log

   v0 self debug merge  # Should be alias
   ```

4. **Cross-cutting context:**
   ```bash
   # Create operation with merge queued
   v0 self debug <op-with-merge-queued>
   # Verify includes merge queue section
   ```

5. **Output options:**
   ```bash
   v0 self debug test-fail --stdout | head -20
   v0 self debug test-fail --output /tmp/custom.md
   cat /tmp/custom.md
   ```

6. **Error handling:**
   ```bash
   v0 self debug nonexistent  # Should fail gracefully
   v0 self debug  # Should show help or list operations
   ```

### Performance Verification

```bash
# Verify trace logging doesn't impact performance
time v0 feature perf-test "Test" --enqueue
# Compare with trace logging disabled
V0_TRACE_ENABLED=0 time v0 feature perf-test2 "Test" --enqueue
# Difference should be negligible (<1% overhead)
```

### Integration Test (Match Example Scenario)

Reproduce the failure scenario from the instructions:
```bash
# Simulate the epic-05a-simulator-core failure
v0 self debug epic-05a-simulator-core

# Verify the report would have caught the issue:
# - Plan file not committed in worktree
# - State shows phase: init
# - Git state shows worktree has untracked plan file
```

The debug report should make it obvious that the plan file was committed in main but not in the worktree, which is the root cause of the "Plan file is not committed" error.
