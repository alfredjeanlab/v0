# Plan: Add --no-verify to automated git commits

## Overview

Add `--no-verify` flag to all automated `git commit` calls in v0 scripts to bypass git hooks during scripted operations. This prevents pre-commit hooks from interfering with automated workflows while maintaining hook enforcement for agent-driven commits (which go through the normal git flow).

## Project Structure

Files requiring modification:
```
bin/v0-archive                               # 2 git commit calls
packages/mergeq/lib/resolution.sh            # 1 git commit call
packages/test-support/fixtures/create-git-fixture.sh  # 1 git commit call (optional)
```

Files that MUST NOT be modified (agent instructions/templates):
```
packages/cli/lib/templates/claude.build.m4   # Agent instructions
packages/cli/lib/templates/claude.roadmap.m4 # Agent instructions
packages/cli/lib/templates/claude.chore.md   # Agent template
packages/cli/lib/templates/claude.fix.md     # Agent template
packages/cli/lib/prompts/*.md                # Agent prompts
packages/hooks/lib/stop-*.sh                 # Hook messages (suggestions to agents)
```

## Dependencies

None - this is a flag addition to existing git commands.

## Implementation Phases

### Phase 1: Core script updates

Update the two production scripts that perform automated commits.

**bin/v0-archive** (lines 183 and 194):
```bash
# Before:
git commit -m "Archive ${archived} plan(s) to icebox" \

# After:
git commit --no-verify -m "Archive ${archived} plan(s) to icebox" \
```

```bash
# Before:
git commit -m "Move ${archived} archived plan(s) to icebox" \

# After:
git commit --no-verify -m "Move ${archived} archived plan(s) to icebox" \
```

**packages/mergeq/lib/resolution.sh** (line 66):
```bash
# Before:
git commit --no-edit || true

# After:
git commit --no-verify --no-edit || true
```

### Phase 2: Test fixture update (optional)

Update the test fixture script for consistency:

**packages/test-support/fixtures/create-git-fixture.sh** (line 30):
```bash
# Before:
git commit --quiet -m "Initial commit"

# After:
git commit --no-verify --quiet -m "Initial commit"
```

### Phase 3: Verification

Run the test suite to ensure no regressions:
```bash
make check
```

## Key Implementation Details

### Why --no-verify?

The `--no-verify` flag skips pre-commit and commit-msg hooks. This is appropriate for:

1. **Automated archive commits** (v0-archive): These are housekeeping operations moving plans to the icebox. No code changes that need linting/testing.

2. **Merge conflict resolution commits** (resolution.sh): These commits are automated after Claude resolves conflicts. The merge itself is the critical operation.

3. **Test fixtures**: Speed up test execution and avoid hook failures in isolated test environments.

### What NOT to modify

Agent templates and prompts intentionally show `git commit` without `--no-verify` because:

1. Agents should go through normal git workflows including hooks
2. Pre-commit hooks help catch issues before agents push
3. The instructions are examples for human-like behavior

The hook messages in `stop-build.sh` and `stop-roadmap.sh` are suggestions to agents, not commands executed by scripts.

## Verification Plan

1. **Static analysis**: Run ShellCheck on modified files
   ```bash
   make lint
   ```

2. **Unit tests**: Run package tests for affected packages
   ```bash
   scripts/test mergeq test-support
   ```

3. **Integration tests**: Run archive-related tests
   ```bash
   scripts/test v0-archive
   ```

4. **Full check**: Run complete validation
   ```bash
   make check
   ```

5. **Manual verification**: Confirm no templates/prompts were modified
   ```bash
   git diff packages/cli/lib/templates/ packages/cli/lib/prompts/ packages/hooks/lib/stop-*.sh
   # Should show no changes
   ```
