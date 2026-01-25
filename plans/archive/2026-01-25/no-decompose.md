# Plan: Remove Decompose Phase

## Overview

Remove the 'decomposing' phase from the v0 pipeline. Instead of converting plans into multiple granular issues via an AI-powered decompose step, we will file a single "feature" issue after planning completes. The issue title will be `Plan: {basename}` and the description will be the full contents of the plan file. The build/implement phase will simply reference PLAN.md directly rather than working through a hierarchy of wk issues.

## Project Structure

Files to delete:
```
bin/v0-decompose                           # Main decompose command
packages/cli/lib/prompts/build.md          # Decompose prompt (misnamed)
packages/cli/lib/build/session-monitor.sh  # Contains monitor_decompose_session (keep monitor_plan_session)
docs/arch/commands/v0-decompose.md         # Docs for deleted command
tests/v0-decompose.bats                    # Tests for deleted command
```

Files to modify:
```
bin/v0-build                               # Remove Phase 2 (decompose), add issue filing
bin/v0-build-worker                        # Remove run_decompose_phase, add issue filing
bin/v0                                     # Remove decompose alias and help
packages/state/lib/rules.sh                # Update transition rules (planned → executing)
packages/cli/lib/templates/claude.build.m4 # Simplify to just reference PLAN.md
packages/cli/lib/build/session-monitor.sh  # Remove monitor_decompose_session function
docs/arch/operations/state.md              # Update state diagram
docs/arch/commands/v0-build.md             # Update workflow description
README.md                                  # Update workflow description
```

## Dependencies

No new external dependencies. Uses existing `wk new feature` command.

## Implementation Phases

### Phase 1: Update State Machine Rules

**Goal**: Allow direct transition from `planned` → `executing` (bypassing `queued`).

**Files**: `packages/state/lib/rules.sh`

**Changes**:
1. Update `sm_allowed_transitions()` for `planned` phase:
   ```bash
   planned)       echo "executing blocked failed" ;;  # was: queued blocked failed
   ```

2. Remove `queued` as an intermediate step for the plan workflow. The `queued` state is still used for operations that are waiting (e.g., blocked operations), but `planned` can now transition directly to `executing`.

**Verification**: Run `scripts/test state` to verify state machine tests still pass.

---

### Phase 2: Create Issue Filing Function

**Goal**: Add a helper function to file a single feature issue after planning.

**Files**: `packages/cli/lib/build/build.sh` (or new file `packages/cli/lib/build/issue.sh`)

**Implementation**:
```bash
# file_plan_issue <name> <plan_file>
# Creates a single feature issue for the plan
# Returns: issue ID on stdout, or empty string on failure
file_plan_issue() {
  local name="$1"
  local plan_file="$2"
  local title="Plan: ${name}"
  local description

  # Read plan file contents as description
  description=$(cat "${plan_file}")

  # Create feature issue with plan content as description
  local issue_id
  issue_id=$(wk new feature "${title}" --description "${description}" --output id 2>/dev/null) || return 1

  # Add label
  wk label "${issue_id}" "plan:${name}" 2>/dev/null || true

  echo "${issue_id}"
}
```

**Verification**: Manual test with `wk new feature "Plan: test" --description "..." --output id`.

---

### Phase 3: Update v0-build (Foreground Mode)

**Goal**: Remove Phase 2 (decompose) and integrate issue filing into plan completion.

**Files**: `bin/v0-build`

**Changes**:

1. **Remove Phase 2 block** (lines 736-862): Delete the entire decompose section.

2. **Update Phase 1 completion** (after line 732): Add issue filing after plan commits:
   ```bash
   # File single feature issue
   PLAN_FILE="${PLANS_DIR}/${NAME}.md"
   FEATURE_ID=$(file_plan_issue "${NAME}" "${PLAN_FILE}")
   if [[ -n "${FEATURE_ID}" ]]; then
     update_state "epic_id" "\"${FEATURE_ID}\""
     emit_event "issue:created" "Created feature ${FEATURE_ID}"
   else
     emit_event "issue:warning" "Failed to create feature issue"
   fi

   # Transition directly to queued (skipping decompose)
   sm_transition_to_queued "${NAME}" "${FEATURE_ID}"
   PHASE="queued"
   ```

3. **Update help text**: Remove references to decompose in usage message (lines 42-43, 50-51).

4. **Update resume phases**: Valid phases become `init`, `planned`, `queued` (remove decompose-specific handling).

5. **Remove decompose session monitoring**: Remove calls to `monitor_decompose_session`.

**Verification**: Run `v0 build test-plan "Test prompt" --dry-run` to verify flow.

---

### Phase 4: Update v0-build-worker (Background Mode)

**Goal**: Remove `run_decompose_phase()` and add issue filing to `run_plan_phase()`.

**Files**: `bin/v0-build-worker`

**Changes**:

1. **Delete `run_decompose_phase()` function** (lines 327-487).

2. **Update `run_plan_phase()` completion**: Add issue filing after plan commit:
   ```bash
   # File single feature issue
   PLAN_FILE="${PLANS_DIR}/${NAME}.md"
   FEATURE_ID=$(file_plan_issue "${NAME}" "${PLAN_FILE}")
   if [[ -n "${FEATURE_ID}" ]]; then
     update_state "epic_id" "\"${FEATURE_ID}\""
     emit_event "issue:created" "Created feature ${FEATURE_ID}"
   else
     emit_event "issue:warning" "Failed to create feature issue"
   fi

   # Transition directly to queued
   sm_transition_to_queued "${NAME}" "${FEATURE_ID}"
   log "Plan phase complete, issue filed"
   ```

3. **Update `main()` function**: Remove calls to `run_decompose_phase`:
   ```bash
   case "${PHASE}" in
     init)
       check_hold_before_phase || exit 0
       run_plan_phase || exit 1
       check_hold_before_phase || exit 0
       run_build_phase || exit 1
       ;;
     planned)
       # Plan exists but issue not filed yet - file it now
       file_plan_issue_if_needed
       check_hold_before_phase || exit 0
       run_build_phase || exit 1
       ;;
     queued)
       check_hold_before_phase || exit 0
       run_build_phase || exit 1
       ;;
     # ... rest unchanged
   esac
   ```

4. **Update recovery logic**: Remove `planned` → `run_decompose_phase` fallback.

**Verification**: Run full pipeline with `v0 build test "Test feature"` and verify no decompose session.

---

### Phase 5: Simplify Build Template

**Goal**: Remove wk issue references from CLAUDE.md template, keep git workflow.

**Files**: `packages/cli/lib/templates/claude.build.m4`

**New template content**:
```m4
changequote(`[[', `]]')dnl
ifdef([[AGENT_ROLE]], [[You are the **AGENT_ROLE**.
]])dnl

## Your Mission

Implement PLAN.md.

## Git Worktree

You are working in a git worktree, NOT the main repo.
The worktree is in the directory named after the repository (relative to this CLAUDE.md).
All created files must be inside the worktree.

**CRITICAL**: Switch to the worktree directory before any git operations:

```bash
cd <repo-name>
git status
git add . && git commit -m "..."
git push V0_GIT_REMOTE
```

## Session Close

When work is complete, run this checklist then exit:

```bash
# 1. Switch to worktree and push
cd <repo-name>
git status
git add <files>
git commit -m "..."
git push V0_GIT_REMOTE

# 2. Exit the session
./done  # or ../done from repo dir
```

**IMPORTANT**: Call `./done` to signal completion. This exits the session.

If you cannot complete the work (blocked, need help, etc.), use `./incomplete` instead:

```bash
./incomplete  # Generates debug report and exits
```
```

**Removed**:
- wk show/ready/start/done commands
- Context management with wk issues
- References to EPIC_ID and PLAN_LABEL

**Verification**: Generate template and inspect: `m4 -D HAS_PLAN=1 -D V0_GIT_REMOTE=origin packages/cli/lib/templates/claude.build.m4`

---

### Phase 6: Cleanup and Delete Files

**Goal**: Remove decompose-specific code and files.

**Files to delete**:
- `bin/v0-decompose`
- `packages/cli/lib/prompts/build.md`
- `docs/arch/commands/v0-decompose.md`
- `tests/v0-decompose.bats`

**Files to modify**:

1. **`bin/v0`**: Remove decompose from help and aliases:
   ```bash
   # Remove from PROJECT_COMMANDS
   PROJECT_COMMANDS="plan tree merge mergeq status build feature resume fix attach cancel shutdown startup hold roadmap pull push archive"

   # Remove from help output
   # Delete line: decomp[ose]   Convert plan to issues

   # Remove alias handling in case statement
   ```

2. **`packages/cli/lib/build/session-monitor.sh`**: Remove `monitor_decompose_session()` function (keep `monitor_plan_session`).

**Verification**: `grep -r decompose bin/ packages/` returns no matches.

---

### Phase 7: Update Documentation

**Goal**: Update docs to reflect new workflow.

**Files**:

1. **`docs/arch/operations/state.md`**: Update state diagram:
   ```
   planned -->|execute| queued
   ```
   Remove decompose references.

2. **`docs/arch/commands/v0-build.md`**: Update workflow description to show plan → execute flow.

3. **`README.md`**: Update workflow description, remove decompose step.

4. **`CHANGELOG.md`**: Add entry for this change.

**Verification**: Review docs for consistency.

---

### Phase 8: Update Tests

**Goal**: Update integration tests, remove decompose tests.

**Files**:

1. **Delete**: `tests/v0-decompose.bats`

2. **Update `tests/v0-build.bats`** (if exists):
   - Remove tests expecting decompose phase
   - Add test for issue filing after plan

3. **Update `tests/v0.bats`**:
   - Remove decompose alias test
   - Update help output tests

4. **Update `packages/state/tests/`**:
   - Update transition tests for new `planned` → `executing` path

**Verification**: `scripts/test` passes all tests.

## Key Implementation Details

### Issue Filing Strategy

The single feature issue replaces the entire decomposition hierarchy:

```bash
# Old: Multiple issues created by Claude during decompose
wk new feature "Root: Implement X"
wk new feature "Phase 1: Setup"
wk new task "Task 1.1"
wk dep task-1.1 blocks phase-1
# ... many more

# New: Single issue filed programmatically
wk new feature "Plan: X" --description "$(cat plans/X.md)"
wk label plan-xxx "plan:X"
```

### State Transitions

```
Before: init → planned → (decompose) → queued → executing → completed → merged
After:  init → planned → queued → executing → completed → merged
```

The `planned` → `queued` transition now happens automatically with issue filing, not via a separate decompose command.

### Backward Compatibility

Operations already in `queued` or later phases continue normally. Operations in `planned` phase will have an issue filed on resume.

### Template Variables

The simplified template removes these M4 variables:
- `EPIC_ID` - no longer needed
- `PLAN_LABEL` - no longer needed (still used in state but not template)

Retained:
- `V0_GIT_REMOTE` - still used for git push
- `HAS_PLAN` - still checked to include PLAN.md reference
- `AGENT_ROLE` - still used for role customization

## Verification Plan

### Unit Tests
```bash
scripts/test state          # State machine transitions
scripts/test cli            # CLI utilities
```

### Integration Tests
```bash
scripts/test v0-build       # Build pipeline
scripts/test v0             # Main command
```

### Manual Verification

1. **New feature flow**:
   ```bash
   v0 build test-feature "Add a new test feature"
   # Verify: plan created, single issue filed, build starts
   wk list --label plan:test-feature  # Should show 1 issue
   ```

2. **Resume from planned**:
   ```bash
   v0 plan test2 "Another feature"
   v0 build test2 --resume
   # Verify: issue filed, build starts
   ```

3. **Existing plan file**:
   ```bash
   v0 build existing --plan plans/existing.md
   # Verify: issue filed with plan contents, build starts
   ```

### Lint Check
```bash
make lint   # ShellCheck passes
make check  # Full test suite passes
```
