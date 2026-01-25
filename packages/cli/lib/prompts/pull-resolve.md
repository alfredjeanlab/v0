Resolve merge conflicts in the current repository.

## Context

You are resolving conflicts from pulling the agent branch into your working branch.
This is running in the foreground - there is no worktree, and you are in the main repo.

## Process

**1. Check conflict status:**
```bash
git status
```

**2. For each conflicted file:**
```bash
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
git commit
```

**6. Verify:**
```bash
git status          # Should be clean
git log --oneline -5
```

## Exit

When conflicts are resolved and committed, run:
```bash
./done
```
