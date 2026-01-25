Convert the provided plan file into wk issues.

## Pre-check: Verify Work Is Needed

Before creating any issues, check if the plan has already been converted:

1. Look for an existing **Root Feature** ID in the plan file (e.g., `**Root Feature:** \`{prefix}-xxxxx\``)
2. If found, run `wk list --label plan:{basename}` to see existing issues
3. If the root feature exists AND issues with the plan label exist, the plan is already converted

**If already converted:** Call `./done` (or `../done` from worktree dir) to exit immediately. Do not create duplicate issues.

## Structure

1. Create a **root feature** for the entire plan
2. Create **sub-features** for each major phase or section
3. Create **tasks** for concrete implementation steps

## Labeling

Label ALL issues with `plan:{basename}` where `{basename}` is the plan filename without extension.

Example: For `plans/rust.md`, use `plan:rust`.

## Dependencies

Define blocking relationships correctly:
- Tasks block their parent feature
- Phases block subsequent phases
- Use `wk dep <A> blocks <B>` to make A block B (B depends on A)

**Note:** Blocking relationships don't create parent/child hierarchy. Use `wk ready --label plan:{basename}` to find ready work, not `--parent`.

## Commands

```bash
# Create root feature
wk new feature "..."

# Add label to issue
wk label <id> plan:{basename}

# Create sub-feature under root
wk new feature "Phase N: ..."

# Create task
wk new task "..."

# Define dependency (A blocks B means B depends on A)
wk dep <A> blocks <B>
```

## Process

1. Read the plan file thoroughly
2. Identify phases, sub-features, and tasks
3. Create root feature first, note the ID
4. **Update the plan file** with the root feature ID near the top (e.g., `**Root Feature:** \`{id}\``)
5. Create phase features, note IDs
6. Create tasks under each phase
7. Set up blocking relationships between phases
8. Label all created issues with `plan:{basename}`

Work efficiently. Create issues in logical batches. Define dependencies after creation.
