# Implementation Plan: v0 goal Command

**Root Feature:** `v0-41ed`

## Overview

Add a new `v0 goal` command that automatically orchestrates work to achieve a stated goal. The command launches an agent that:

1. Explores the project/codebase
2. Creates an outline of epics and milestones
3. Adds pre-checks and post-checks around milestones
4. Sequentially queues all work using `v0 feature --after`

Goals are logged as `wk idea` issues and only appear in `v0 status` during active planning.

## Project Structure

```
bin/
  v0-goal              # Main command entrypoint
  v0-goal-worker       # Background worker for goal orchestration
lib/
  prompts/
    goal.md            # Planning prompt for goal agent
  templates/
    claude.goal.m4     # CLAUDE.md template for goal agent
  hooks/
    stop-goal.sh       # Completion detection hook
tests/unit/
  v0-goal.bats         # Unit tests for goal command
```

## Dependencies

- Existing v0 infrastructure (v0-common.sh, state-machine.sh)
- tmux, jq, claude, m4, wk (standard v0 dependencies)
- No new external dependencies required

## Implementation Phases

### Phase 1: Core Infrastructure

Create the basic goal command structure and state management.

**Files to create:**
- `bin/v0-goal` - Command entrypoint with argument parsing
- `bin/v0-goal-worker` - Background worker

**Key implementation details:**

```bash
# bin/v0-goal usage pattern
v0 goal <name> "<goal description>"
v0 goal --status            # Show goal status
v0 goal <name> --resume     # Resume goal planning

# State stored in .v0/build/goals/<name>/state.json
# Different from operations to avoid cluttering status
```

State schema for goals:
```json
{
  "name": "project-rewrite",
  "type": "goal",
  "phase": "init|planning|orchestrating|completed|failed",
  "goal_description": "Rewrite the entire frontend in React",
  "idea_id": "PROJ-idea-123",  // wk idea issue ID
  "epics": [],
  "milestones": [],
  "features_queued": [],
  "created_at": "...",
  "planning_session": null
}
```

### Phase 2: Goal Planning Prompt & Template

Create the CLAUDE.md template and planning prompt that guides the agent through goal decomposition.

**Files to create:**
- `lib/prompts/goal.md` - Detailed instructions for goal decomposition
- `lib/templates/claude.goal.m4` - M4 template with GOAL_NAME, GOAL_DESCRIPTION macros

**Prompt structure (lib/prompts/goal.md):**

```markdown
# Goal: GOAL_NAME

## Description
GOAL_DESCRIPTION

## Your Mission

Decompose this goal into epics, milestones, and actionable features that can be queued for autonomous execution.

## Step 1: Explore the Codebase

Before creating any work items, thoroughly explore:
- Project structure and architecture
- Existing patterns and conventions
- Related code that will be affected
- Test infrastructure and coverage

## Step 2: Create Outline

Create an outline with:

### Epics (1 line each)
High-level areas of work. Format:
- `epic: <name> - <one-line description>`

### Milestones (with nested criteria)
Key checkpoints with verification criteria. Format:
```
milestone: <name>
  - [ ] criterion 1
  - [ ] criterion 2
```

## Step 3: Add Pre-checks and Post-checks

For each milestone, consider adding:

### Pre-check Formulas

**Refactor Formula** - Normal feature describing preparation work:
```bash
v0 feature <milestone>-precheck-<name> "<description of refactoring>"
```

**Bug Fix Loop** - Clear bugs before proceeding:
```bash
v0 feature <milestone>-pre-bugfix "Bug fix loop: create a plan to loop launching 'v0 fix' and using 'v0 status' to wait for results, until all bugs have been fixed. When decomposing, only create one feature issue (not BUG, not CHORE) with no dependents."
```

**Chore Loop** - Clean up technical debt:
```bash
v0 feature <milestone>-pre-chores "Chore loop: create a plan to loop launching 'v0 chore' and using 'v0 status' to wait for results, until all chores are complete. When decomposing, only create one feature issue with no dependents."
```

### Post-check Formulas

Common post-checks to consider:
- Ensure all tests are passing
- Ensure previously planned work is complete
- Finish deprecating old code and complete migration to new patterns
- Verify no regressions in existing functionality

### Examples of Pre/Post-checks

```bash
# Pre-check: Ensure clean slate
v0 feature auth-precheck-tests "Ensure all tests are passing before starting auth work" --after <previous>

# Pre-check: Bug fix loop
v0 feature auth-pre-bugfix "Bug fix loop: fix all existing bugs before proceeding" --after auth-precheck-tests

# Main milestone work
v0 feature auth-milestone "Implement JWT authentication" --after auth-pre-bugfix

# Post-check: Migration cleanup
v0 feature auth-postcheck-migrate "Complete migration from session auth to JWT" --after auth-milestone

# Post-check: Verify no regressions
v0 feature auth-postcheck-verify "Run full test suite and fix any regressions" --after auth-postcheck-migrate
```

## Step 4: Queue Features

Queue all features sequentially using `--after`:

```bash
# First feature has no --after
v0 feature <first-epic> "<description>" --enqueue

# All subsequent features depend on the previous
v0 feature <epic-2> "<description>" --after <first-epic> --enqueue
v0 feature <milestone-1-precheck> "<description>" --after <epic-2> --enqueue
v0 feature <milestone-1> "<description>" --after <milestone-1-precheck> --enqueue
v0 feature <milestone-1-postcheck> "<description>" --after <milestone-1> --enqueue
# ... continue the chain
```

## Completion

When all features are queued:
1. Log the complete plan using `wk note <goal-idea-id> "Plan complete: N features queued"`
2. Run `./done` to exit

## Context Recovery

On session start or after compaction, `v0 prime` will be injected to recover context.
```

**CLAUDE.md template (lib/templates/claude.goal.m4):**

```m4
changequote(`[[', `]]')dnl
## Your Mission

Orchestrate the goal: **GOAL_DESCRIPTION**

The goal idea is tracked as IDEA_ID.

## Finding Work

```bash
# Check goal status
wk show IDEA_ID

# List queued features for this goal
wk list --label goal:GOAL_NAME
```

## Goal Orchestration

Follow the instructions in GOAL.md to:
1. Explore the codebase
2. Create an outline of epics and milestones
3. Add pre-checks and post-checks
4. Queue all features with `v0 feature --after`

## Session Close

When orchestration is complete:
```bash
./done  # Signals completion
```

If you cannot complete:
```bash
./incomplete  # Preserves state for resume
```
```

### Phase 3: Hook Integration

Create the stop hook and integrate v0 prime injection.

**Files to create:**
- `lib/hooks/stop-goal.sh` - Prevents premature session termination

**Hook implementation:**

```bash
#!/bin/bash
# stop-goal.sh - Block stop if goal work is incomplete

# Read JSON from stdin
INPUT=$(cat)
SESSION_ID=$(echo "${INPUT}" | jq -r '.session_id // empty')
REASON=$(echo "${INPUT}" | jq -r '.reason // empty')
STOP_HOOK_ACTIVE=$(echo "${INPUT}" | jq -r '.stop_hook_active // false')

# Allow if already in stop hook (prevent infinite loop)
[[ "${STOP_HOOK_ACTIVE}" = "true" ]] && { echo '{"decision": "approve"}'; exit 0; }

# Allow system-initiated stops
case "${REASON}" in
  auth_*|billing_*|context_limit|user_interrupt)
    echo '{"decision": "approve"}'
    exit 0
    ;;
esac

# Check if all features have been queued
# Goal is complete when the outline is fully queued
# This is determined by checking if state.json has all planned features

STATE_FILE="${V0_BUILD_DIR}/goals/${V0_GOAL_NAME}/state.json"
if [[ -f "${STATE_FILE}" ]]; then
  PLANNED=$(jq -r '.milestones | length' "${STATE_FILE}")
  QUEUED=$(jq -r '.features_queued | length' "${STATE_FILE}")

  if [[ "${QUEUED}" -lt "${PLANNED}" ]]; then
    echo '{"decision": "block", "reason": "Goal orchestration incomplete: '"${QUEUED}/${PLANNED}"' features queued"}'
    exit 0
  fi
fi

echo '{"decision": "approve"}'
```

**v0 prime injection via settings.local.json:**

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "stop-goal.sh" }] }],
    "PreCompact": [{ "matcher": "", "hooks": [{ "type": "command", "command": "v0 prime" }] }],
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "v0 prime" }] }]
  }
}
```

### Phase 4: Status Integration

Modify v0-status to show goals only during active planning, and add goal ID to operation output.

**Files to modify:**
- `bin/v0-status` - Add goal display logic
- `lib/state-machine.sh` - Add goal_id field handling

**Status display logic:**

```bash
# Show goals only when actively planning
show_goals() {
  local goal_dir="${BUILD_DIR}/goals"
  [[ ! -d "${goal_dir}" ]] && return

  local active_goals=()
  for state_file in "${goal_dir}"/*/state.json; do
    [[ ! -f "${state_file}" ]] && continue
    local phase=$(jq -r '.phase' "${state_file}")
    # Only show during planning/orchestrating phases
    if [[ "${phase}" = "planning" ]] || [[ "${phase}" = "orchestrating" ]]; then
      local name=$(jq -r '.name' "${state_file}")
      local desc=$(jq -r '.goal_description' "${state_file}")
      active_goals+=("${name}|${phase}|${desc}")
    fi
  done

  if [[ ${#active_goals[@]} -gt 0 ]]; then
    echo ""
    echo "Goals:"
    for goal in "${active_goals[@]}"; do
      IFS='|' read -r name phase desc <<< "${goal}"
      printf "  %-20s %s  %s\n" "${name}:" "${phase}" "(${desc:0:40}...)"
    done
  fi
}
```

**Goal ID in operation output:**

When operations are created by a goal, store `goal_id` in state.json. Display in status:

```bash
# In operation status line, show (Goal: <id>) if present
goal_id=$(jq -r '.goal_id // empty' "${STATE_FILE}")
if [[ -n "${goal_id}" ]]; then
  goal_indicator=" ${C_DIM}(Goal: ${goal_id})${C_RESET}"
fi
```

### Phase 5: wk idea Integration

Log goals as wk idea issues and link operations to them.

**Implementation in v0-goal:**

```bash
# Create idea issue for the goal
IDEA_ID=$(wk new idea "${GOAL_DESCRIPTION}" --label "goal:${NAME}" 2>/dev/null | grep -oE '[A-Z]+-[a-z0-9]+')
if [[ -z "${IDEA_ID}" ]]; then
  echo "Error: Failed to create goal idea issue"
  exit 1
fi

# Store in state
update_state "idea_id" "\"${IDEA_ID}\""

# When queuing features, include goal_id
v0 feature "${FEATURE_NAME}" "${FEATURE_DESC}" --after "${PREV}" --label "goal:${NAME}"
```

### Phase 6: Testing & Documentation

**Files to create:**
- `tests/unit/v0-goal.bats` - Comprehensive unit tests

**Test cases:**

```bash
# tests/unit/v0-goal.bats

@test "v0-goal creates state directory" {
  run v0 goal test-goal "Test goal description" --dry-run
  assert_success
}

@test "v0-goal creates wk idea issue" {
  run v0 goal test-goal "Test goal" --dry-run
  assert_output --partial "idea"
}

@test "v0-goal rejects invalid names" {
  run v0 goal "invalid name" "Description"
  assert_failure
  assert_output --partial "must start with a letter"
}

@test "v0-goal shows in status during planning" {
  # Setup: Create goal in planning phase
  # Assert: v0 status shows goal
}

@test "v0-goal hides from status after completion" {
  # Setup: Create completed goal
  # Assert: v0 status does not show goal
}

@test "v0-goal queues features with --after chain" {
  # Assert: Features are created with correct dependencies
}
```

## Key Implementation Details

### Feature Queuing Chain

All features are queued in sequence using `--after`:

```
[first-epic] → [epic-2] → [milestone-1-precheck] → [milestone-1] → [milestone-1-postcheck] → ...
```

This ensures:
- Work proceeds in planned order
- Pre-checks complete before milestone work
- Post-checks verify milestone completion
- Entire goal progresses atomically

### Pre/Post-check Formulas

Three formula types for checks:

1. **Refactor Formula**: Standard `v0 feature` with specific refactoring instructions
2. **Bug Fix Loop**: Creates a feature that loops `v0 fix` until no bugs remain
3. **Chore Loop**: Creates a feature that loops `v0 chore` until no chores remain

Loop features are special - they only create a single feature issue (not BUG or CHORE) to avoid circular dependencies.

### Status Display Rules

- Goals appear in `v0 status` only when `phase` is `planning` or `orchestrating`
- Completed goals disappear to save space
- Operations show `(Goal: <id>)` suffix when created by a goal

### Context Recovery

The agent receives `v0 prime` output on:
- SessionStart hook (new session)
- PreCompact hook (before context compaction)

This ensures the agent can resume work after context limits.

## Verification Plan

### Unit Tests

```bash
make test-file FILE=tests/unit/v0-goal.bats
```

### Integration Testing

1. **Basic goal creation:**
   ```bash
   v0 goal test "Add a simple hello world feature"
   v0 status  # Should show goal in planning
   ```

2. **Feature chain verification:**
   ```bash
   # After goal completes planning
   v0 status --blocked  # Should show feature chain
   ```

3. **Status hiding after completion:**
   ```bash
   # Manually complete a goal
   jq '.phase = "completed"' state.json > tmp && mv tmp state.json
   v0 status  # Goal should not appear
   ```

4. **Goal ID in operations:**
   ```bash
   # After goal queues features
   v0 status <feature-name> --json | jq '.goal_id'
   ```

### Manual Testing Checklist

- [ ] Goal creates wk idea issue
- [ ] Agent receives v0 prime on session start
- [ ] Agent explores codebase before planning
- [ ] Agent creates epics outline
- [ ] Agent creates milestones with criteria
- [ ] Agent adds appropriate pre/post-checks
- [ ] Features are queued with correct --after chain
- [ ] Goal disappears from status after completion
- [ ] Operations show (Goal: <id>) suffix
- [ ] Resume works correctly after interruption
