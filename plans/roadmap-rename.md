# Implementation Plan: Rename 'goal' Command to 'roadmap'

## Overview

Rename the `v0 goal` command and all associated components to `v0 roadmap`. This includes updating scripts, templates, prompts, hooks, tests, and ensuring the prompt refers to the "outline" as a "roadmap outline".

## Project Structure

Files to be renamed:
```
bin/v0-goal                    → bin/v0-roadmap
bin/v0-goal-worker             → bin/v0-roadmap-worker
lib/prompts/goal.md            → lib/prompts/roadmap.md
lib/templates/claude.goal.m4   → lib/templates/claude.roadmap.m4
lib/hooks/stop-goal.sh         → lib/hooks/stop-roadmap.sh
tests/unit/v0-goal.bats        → tests/unit/v0-roadmap.bats
```

Files requiring internal updates:
```
bin/v0                         # CLI dispatcher
bin/v0-status                  # Status display (goal references)
bin/v0-attach                  # Attach to sessions
```

## Dependencies

No external dependencies required. All changes are internal renaming operations.

## Implementation Phases

### Phase 1: Rename Core Scripts

Rename and update the main command scripts.

**Files:**
- `bin/v0-goal` → `bin/v0-roadmap`
- `bin/v0-goal-worker` → `bin/v0-roadmap-worker`

**Changes in v0-roadmap:**
- Usage text: `v0 goal` → `v0 roadmap`
- State directory: `goals/` → `roadmaps/`
- Example commands: update all `v0 goal` references
- Function `create_idea_issue`: label `goal:${NAME}` → `roadmap:${NAME}`
- All user-facing messages: "goal" → "roadmap"

**Changes in v0-roadmap-worker:**
- Comments: "goal orchestration" → "roadmap orchestration"
- Branch pattern: `goal/${NAME}` → `roadmap/${NAME}`
- Session naming: `"goal"` type → `"roadmap"` type
- Environment variables: `V0_GOAL_NAME` → `V0_ROADMAP_NAME`
- Labels: `goal:${NAME}` → `roadmap:${NAME}`
- Template path: `claude.goal.m4` → `claude.roadmap.m4`
- Prompt path: `prompts/goal.md` → `prompts/roadmap.md` (copy to `ROADMAP.md`)
- Hook path: `stop-goal.sh` → `stop-roadmap.sh`
- User messages: "Goal orchestration" → "Roadmap orchestration"

**Verification:**
- Script files exist with correct names
- No references to "v0-goal" in the renamed scripts

---

### Phase 2: Update Prompt and Template

Rename and update the agent instructions and M4 template.

**Files:**
- `lib/prompts/goal.md` → `lib/prompts/roadmap.md`
- `lib/templates/claude.goal.m4` → `lib/templates/claude.roadmap.m4`

**Changes in roadmap.md (prompt):**
- Title: "# Goal Orchestration" → "# Roadmap Orchestration"
- Step 2 heading: "Create Outline" → "Create Roadmap Outline"
- Text references: "outline" → "roadmap outline" where contextually appropriate
- All `goal:` labels → `roadmap:`
- Variable references: `<goal-name>` → `<roadmap-name>`

**Key text replacements in roadmap.md:**
```
"# Goal Orchestration" → "# Roadmap Orchestration"
"Create an outline with:" → "Create a roadmap outline with:"
"--label goal:<goal-name>" → "--label roadmap:<roadmap-name>"
"Decompose this goal" → "Decompose this roadmap"
```

**Changes in claude.roadmap.m4:**
- `GOAL_DESCRIPTION` → `ROADMAP_DESCRIPTION`
- `GOAL_NAME` → `ROADMAP_NAME`
- `goal:GOAL_NAME` → `roadmap:ROADMAP_NAME`
- Text: "Orchestrate the goal" → "Orchestrate the roadmap"
- Section: "## Goal Orchestration" → "## Roadmap Orchestration"
- File reference: `GOAL.md` → `ROADMAP.md`

**Verification:**
- Files exist with new names
- Search for remaining "goal" references (should be zero or intentional)

---

### Phase 3: Update Hook Script

Rename and update the stop hook.

**File:** `lib/hooks/stop-goal.sh` → `lib/hooks/stop-roadmap.sh`

**Changes:**
- Comment: "Stop hook for v0 goal operations" → "Stop hook for v0 roadmap operations"
- Environment variable: `V0_GOAL_NAME` → `V0_ROADMAP_NAME`
- Labels: `goal:${GOAL_NAME}` → `roadmap:${ROADMAP_NAME}` (variable rename too)
- Error message: reference roadmap instead of goal

**Verification:**
- Hook file exists with new name
- Environment variable name updated correctly

---

### Phase 4: Update CLI Dispatcher and Related Commands

Update files that reference the goal command.

**Files:**
- `bin/v0`
- `bin/v0-status`
- `bin/v0-attach`

**Changes in bin/v0:**
```bash
# Line 19: PROJECT_COMMANDS list
"goal" → "roadmap"

# Line 79: Help text
"goal          Orchestrate autonomous work to achieve a stated goal"
→ "roadmap       Orchestrate autonomous work using a roadmap"

# Line 210: Command dispatcher case
"goal" → "roadmap"
```

**Changes in bin/v0-status:**
- Function name: `show_active_goals()` → `show_active_roadmaps()`
- Variable: `goal_dir` → `roadmap_dir`
- Directory: `goals/` → `roadmaps/`
- Variable: `active_goals` → `active_roadmaps`
- JSON field: `goal_description` → `roadmap_description`
- Comment updates: "goals" → "roadmaps"
- Function call: `show_active_goals` → `show_active_roadmaps`

**Changes in bin/v0-attach:**
- Usage text: `goal <name>` → `roadmap <name>`
- Case handler: `goal)` → `roadmap)`
- Directory: `goals/` → `roadmaps/`
- Session type: `"goal"` → `"roadmap"`
- Error messages: "goal" → "roadmap"
- Variable: `GOAL_STATE_FILE` → `ROADMAP_STATE_FILE`

**Verification:**
- `grep -r "goal" bin/` shows no unintended references
- `v0 --help` shows roadmap command

---

### Phase 5: Rename and Update Tests

Rename test file and update all test content.

**File:** `tests/unit/v0-goal.bats` → `tests/unit/v0-roadmap.bats`

**Changes:**
- Header comment: "v0-goal.bats" → "v0-roadmap.bats"
- Variable: `V0_GOAL` → `V0_ROADMAP`
- Path: `bin/v0-goal` → `bin/v0-roadmap`
- Directories: `goals/` → `roadmaps/`
- Test names: all `v0-goal:` prefixes → `v0-roadmap:`
- Output assertions: `"Usage: v0 goal"` → `"Usage: v0 roadmap"`
- State field: `goal_description` → `roadmap_description`
- Mock wk calls: `goal:` labels → `roadmap:` labels
- All user-facing strings: "goal" → "roadmap"

**Example test name changes:**
```bash
@test "v0-goal: --help shows usage" → @test "v0-roadmap: --help shows usage"
@test "v0-goal: rejects duplicate goal name" → @test "v0-roadmap: rejects duplicate roadmap name"
```

**Verification:**
- `make test-file FILE=tests/unit/v0-roadmap.bats` passes
- All test names updated

---

### Phase 6: Final Verification and Cleanup

Run full test suite and linter, verify no stray references.

**Tasks:**
1. Run linter: `make lint`
2. Run all tests: `make test`
3. Search for stray references:
   ```bash
   grep -r "v0-goal" bin/ lib/ tests/
   grep -r "goals/" bin/ lib/ tests/
   grep -r "V0_GOAL" bin/ lib/ tests/
   grep -r '"goal"' bin/ lib/  # quoted goal as command name
   ```
4. Verify removed files don't exist:
   - `bin/v0-goal`
   - `bin/v0-goal-worker`
   - `lib/prompts/goal.md`
   - `lib/templates/claude.goal.m4`
   - `lib/hooks/stop-goal.sh`
   - `tests/unit/v0-goal.bats`

**Verification:**
- `make check` passes (lint + tests)
- No stray "goal" references except intentional ones

## Key Implementation Details

### State Directory Migration

The state directory changes from `.v0/build/goals/` to `.v0/build/roadmaps/`. Existing goals will not be automatically migrated - this is a clean rename assuming no active goals exist.

### Label Format

All labels change format:
- Old: `goal:<name>` (e.g., `goal:auth-rewrite`)
- New: `roadmap:<name>` (e.g., `roadmap:auth-rewrite`)

### Environment Variables

| Old | New |
|-----|-----|
| `V0_GOAL_NAME` | `V0_ROADMAP_NAME` |
| `V0_IDEA_ID` | `V0_IDEA_ID` (unchanged) |

### Session Naming

Session type parameter changes from `"goal"` to `"roadmap"`:
```bash
# Old
SESSION=$(v0_session_name "${NAME}" "goal")

# New
SESSION=$(v0_session_name "${NAME}" "roadmap")
```

### Prompt "Outline" Terminology

The prompt `lib/prompts/roadmap.md` should refer to the planning artifact as a "roadmap outline" rather than just "outline":

```markdown
# Before (in goal.md)
## Step 2: Create Outline
Create an outline with:

# After (in roadmap.md)
## Step 2: Create Roadmap Outline
Create a roadmap outline with:
```

## Verification Plan

1. **Unit Tests:** Run `make test-file FILE=tests/unit/v0-roadmap.bats` after each phase
2. **Linter:** Run `make lint` to check shell syntax
3. **Full Suite:** Run `make check` after Phase 6
4. **Manual Verification:**
   - `v0 roadmap --help` shows correct usage
   - `v0 roadmap test "Test description" --dry-run` creates state in `.v0/build/roadmaps/`
   - `v0 roadmap --status` shows roadmaps (not goals)
   - `v0 attach roadmap test` works (after creating test roadmap)
5. **Grep Verification:**
   ```bash
   # Should return no results (except this plan file)
   grep -r "v0-goal" bin/ lib/ tests/
   grep -rE "goals/|/goals" bin/ lib/ tests/
   ```
