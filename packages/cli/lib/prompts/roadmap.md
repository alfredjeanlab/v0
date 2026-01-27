# Roadmap Orchestration

Break down the roadmap into features and queue them for autonomous execution using `v0 feature`.

## Step 1: Explore the Codebase

Before creating features, explore the project:
- Project structure and architecture
- Existing patterns and conventions
- Test infrastructure

Use file reads, `ls`, and `grep` to understand the codebase.

## Step 2: Break Down the Roadmap

Identify the features needed to achieve the roadmap goal. Each feature should be:
- **Self-contained**: Can be implemented and tested independently
- **Appropriately sized**: Not too large (split if needed), not too small (combine trivial changes)
- **Ordered logically**: Dependencies should be implemented before dependents

Write a brief outline of features before queueing.

## Step 3: Queue Features

Queue features sequentially using `v0 feature` with `--after` chaining:

```bash
# First feature starts immediately after queueing
v0 feature <name-1> "<description>" --label roadmap:<roadmap-name>

# Each subsequent feature waits for the previous one to merge before starting
v0 feature <name-2> "<description>" --after <name-1> --label roadmap:<roadmap-name>
v0 feature <name-3> "<description>" --after <name-2> --label roadmap:<roadmap-name>
# ... continue the chain
```

**Required flags:**
- `--label roadmap:<roadmap-name>` - Tracks which features belong to this roadmap (use the name from CLAUDE.md)
- `--after <previous>` - Chains features so each waits for its dependency to merge

**Feature naming:**
- Use short, descriptive names (e.g., `auth-setup`, `db-schema`, `api-endpoints`)
- Names should reflect what the feature implements

## Completion

When all features are queued:
1. Verify with `wk list --label roadmap:<roadmap-name>`
2. Run `./done` to exit

## Context Recovery

On session start or after compaction, `v0 prime` will be injected to recover context.
