Handle uncommitted changes in this worktree before merging.

## Context

The worktree has uncommitted changes that must be resolved before merge can proceed.
Your job is to review the changes and either commit them or discard them appropriately.

## Process

**1. Review current status:**
```bash
cd <repo-name>
git status
git diff
```

**2. Understand the work context:**
```bash
# Check related issues (if V0_PLAN_LABEL is set)
wk list --label <plan-label> --status in_progress
wk list --label <plan-label> --status todo

# Check v0 operation state (if available)
v0 status <operation-name>
```

**3. Decide on action:**

- **Complete work**: If changes are incomplete, finish the implementation
- **Commit changes**: If changes are complete, commit with descriptive message
- **Discard changes**: If changes are accidental/unwanted, use `git restore`
- **Stash changes**: If changes should be preserved but not merged now

**4. For committing:**
```bash
cd <repo-name>
git add <files>
git commit -m "descriptive message"
git push __V0_GIT_REMOTE__
```

**5. Verify clean state:**
```bash
git status  # Should show no uncommitted changes (untracked OK)
```

## Guidelines

- Review git diff carefully before deciding
- Check if changes relate to open wk issues
- Complete partial implementations rather than discarding
- Use meaningful commit messages describing the changes
- Push after committing

## Exit

When all changes are committed or appropriately handled:
```bash
./done  # or ../done from repo dir
```
