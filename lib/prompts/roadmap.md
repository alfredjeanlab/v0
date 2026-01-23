# Roadmap Orchestration

Decompose this roadmap into epics, milestones, and actionable features that can be queued for autonomous execution.

## Step 1: Explore the Codebase

Before creating any work items, thoroughly explore:
- Project structure and architecture
- Existing patterns and conventions
- Related code that will be affected
- Test infrastructure and coverage

Use `ls`, `find`, `grep`, and file reads to understand the codebase. This exploration informs your planning.

## Step 2: Create Roadmap Outline

Create a roadmap outline with:

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

For each milestone, consider adding appropriate checks:

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
# First feature starts immediately
v0 feature <first-epic> "<description>"

# All subsequent features depend on the previous (--after blocks until dependency merges)
v0 feature <epic-2> "<description>" --after <first-epic>
v0 feature <milestone-1-precheck> "<description>" --after <epic-2>
v0 feature <milestone-1> "<description>" --after <milestone-1-precheck>
v0 feature <milestone-1-postcheck> "<description>" --after <milestone-1>
# ... continue the chain
```

**Important:**
- Add `--label roadmap:<roadmap-name>` to all features (use the roadmap name from CLAUDE.md)
- Chain all features with `--after` to ensure sequential execution (each waits for its dependency to merge)

## Completion

When all features are queued:
1. Log the complete plan using `wk note <idea-id> "Plan complete: N features queued"`
2. Run `./done` to exit

## Context Recovery

On session start or after compaction, `v0 prime` will be injected to recover context.
