Resolve merge conflicts in this worktree.

## Context

You are in a worktree that has conflicts when merging to main. Your job is to resolve them.

## Process

**1. Check conflict status:**
```bash
git status
```

**2. For each conflicted file:**
```bash
# See conflict markers
git diff <file>
```

**3. Resolve conflicts:**
- Read both versions carefully
- Consider the intent of each change
- Edit the file to combine changes correctly
- Remove conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)

**4. After resolving each file:**
```bash
git add <file>
```

**5. When all conflicts resolved:**
```bash
git rebase --continue
# or if merging:
git commit
```

**6. Verify:**
```bash
git status          # Should be clean
git log --oneline -5
```

## Guidelines

- Preserve functionality from both sides when possible
- If changes are independent, include both
- If changes conflict logically, use judgment based on context
- Run tests if available to verify resolution

## Handling Untracked Files

If `git status` shows untracked files (`??`):
1. **Identify purpose**: Are they generated, accidental, or intentional?
2. **Generated files** (build artifacts, logs): Add to `.gitignore` or delete
3. **Accidental files**: Delete if not needed
4. **Intentional files**: Stage and commit them as part of the merge
5. **Uncertain**: Leave them - untracked files don't block merges

## Exit

When all conflicts are resolved and the working tree is clean, run:
```bash
./done  # or ../done from repo dir
```
