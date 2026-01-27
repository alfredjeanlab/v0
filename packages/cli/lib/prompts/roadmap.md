# Roadmap Orchestration

Decompose this roadmap into epics, milestones, and actionable features that can be queued for autonomous execution.

## Step 1: Explore the Codebase

Before creating any work items, thoroughly explore:
- Project structure and architecture
- Existing patterns and conventions
- Related code that will be affected
- Test infrastructure and coverage
- Benchmarking setup (if any)

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

## Step 3: Size and Structure Features

Each feature should be **medium-sized** (~500-1500 lines of code). If a feature seems larger, split it further:
- One logical unit per feature (e.g., one endpoint, one component, one module)
- Break complex units into variants, modes, or options as separate features
- Split large refactors into incremental steps

Structure your work with three types of features:

### Implementation Features
The actual functionality being built. Keep them focused and independently testable.

### Review Features (after each implementation)
After each implementation feature, add a review feature:
```
"Review <previous>: verify completeness, close any gaps or incomplete work, refactor to DRY up the code, ensure tests use parameterization, add missing tests, fix design defects."
```

### Consolidation Features (after batches of similar work)
After completing 3-5 related implementation features, add a consolidation feature:
```
"Consolidate <epic-name>: refactor shared patterns, extract common utilities, clean up tech debt, improve test coverage, update documentation."
```

### Audit Features (occasional)
At major milestones, consider adding audit features:
```
"Security audit: review for OWASP top 10, input validation, auth/authz gaps."
"Performance audit: profile hot paths, optimize database queries, review caching."
```
These should be rare (1-2 per roadmap) and placed at significant boundaries.

## Step 4: Queue Features

Queue all features sequentially using `--after`:

```bash
# Library setup before implementation batch
v0 feature auth-lib-setup "Set up authentication library structure and interfaces" --label roadmap:<roadmap-name>

# Implementation + Review pairs
v0 feature auth-jwt-tokens "Implement JWT token generation and validation" --after auth-lib-setup --label roadmap:<roadmap-name>
v0 feature auth-jwt-review "Review auth-jwt-tokens: verify completeness, close gaps, DRY up code, add tests" --after auth-jwt-tokens --label roadmap:<roadmap-name>

v0 feature auth-middleware "Implement authentication middleware" --after auth-jwt-review --label roadmap:<roadmap-name>
v0 feature auth-middleware-review "Review auth-middleware: verify completeness, close gaps, add tests" --after auth-middleware --label roadmap:<roadmap-name>

v0 feature auth-session "Implement session management" --after auth-middleware-review --label roadmap:<roadmap-name>
v0 feature auth-session-review "Review auth-session: verify completeness, close gaps, add tests" --after auth-session --label roadmap:<roadmap-name>

# Consolidation after batch
v0 feature auth-consolidate "Consolidate auth epic: extract shared patterns, clean tech debt, improve coverage" --after auth-session-review --label roadmap:<roadmap-name>

# Continue with next epic...
# Occasional audit at milestone boundary
v0 feature milestone-1-security "Security audit: review auth implementation for vulnerabilities" --after <last-feature> --label roadmap:<roadmap-name>
```

**Required flags:**
- `--label roadmap:<roadmap-name>` - Tracks which features belong to this roadmap (use the name from CLAUDE.md)
- `--after <previous>` - Chains features so each waits for its dependency to merge

**Feature naming:**
- Use short, descriptive names (e.g., `auth-setup`, `db-schema`, `api-endpoints`)
- Suffix review features with `-review`
- Suffix consolidation features with `-consolidate`

## Completion

When all features are queued:
1. Log the complete plan using `wk note <idea-id> "Plan complete: N features queued"`
2. Run `./done` to exit

## Context Recovery

On session start or after compaction, `v0 prime` will be injected to recover context.
