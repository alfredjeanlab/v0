# Hook Scripts Debug Guide

Stop hooks validate work completion before allowing Claude to exit. Failures here cause **lost work**.

## Hook Overview

| Hook | Blocks When | Risk if Broken |
|------|-------------|----------------|
| `stop-feature.sh` | Issues open OR uncommitted changes | Work exits incomplete |
| `stop-fix.sh` | Bugs `in_progress` | Partial fix abandoned |
| `stop-chore.sh` | Chores ready OR `in_progress` | Chore abandoned |
| `stop-merge.sh` | Conflicts OR rebase in progress | Broken merge state |
| `stop-uncommitted.sh` | Uncommitted changes exist | Changes lost |

## Lost Work Failure Modes

### 1. Hook Silently Approves Exit (CRITICAL)

All stop hooks swallow `wk` errors and default to approving exit:

```bash
# If wk fails, OPEN_COUNT=0, hook approves exit
OPEN_COUNT=$(wk list --label "$PLAN_LABEL" --status todo 2>/dev/null | wc -l)
```

**Causes:**
- `wk` binary not in PATH
- `wk` auth token expired
- Network failure to issue tracker
- Issue tracker API down

**Symptoms:**
- Agent exits cleanly despite open issues
- Work committed but never merged
- No error messages anywhere

**Diagnosis:**
```bash
# Test wk manually
wk list --label "plan:{name}" --status todo
echo $?  # non-zero = broken

# Check if wk works at all
which wk
wk whoami
```

**Recovery:**
```bash
# Find incomplete work by checking remote branches not in main
git branch -r --no-merged main | grep -E 'feature/|fix/|chore/'

# For each orphan, check worktree for uncommitted work
git -C BUILD_DIR/worktrees/feature/{name} log --oneline main..HEAD
git -C BUILD_DIR/worktrees/feature/{name} status
```

---

### 2. Missing Environment Variables

Hooks depend on env vars set by parent scripts:

| Hook | Required Vars |
|------|---------------|
| `stop-feature.sh` | `V0_PLAN_LABEL`, `V0_OP`, `V0_WORKTREE` |
| `stop-merge.sh` | `MERGE_WORKTREE` |
| `stop-uncommitted.sh` | `UNCOMMITTED_WORKTREE` |

If vars missing, hook approves exit unconditionally.

**Symptoms:**
- Hook never blocks despite incomplete work
- Works in some contexts but not others

**Diagnosis:**
```bash
# In tmux session, check env
tmux attach -t {session}
# Then: env | grep V0_
# Then: env | grep WORKTREE
```

---

### 3. Hook Blocks Forever → User Force-Kills

If hook blocks indefinitely, users kill tmux session, losing uncommitted work.

**Causes:**
- Issue tracker shows stale data (issue closed but cache not updated)
- `wk` hangs on network timeout
- Circular dependency in issue status

**Symptoms:**
- Agent stuck saying "X issues remain" but issues appear closed
- User runs `tmux kill-session` or Ctrl-C repeatedly
- Uncommitted/unpushed changes lost

**Diagnosis:**
```bash
# Compare hook's view vs actual
wk list --label "plan:{name}" --status todo    # what hook sees
wk list --label "plan:{name}"                   # all statuses

# Check for stale cache
wk sync  # if available
```

**Recovery:**
```bash
# If work was pushed before kill
git ls-remote origin feature/{name}
# Recreate worktree from remote if exists

# If work was committed but not pushed - check reflog in worktree
git -C BUILD_DIR/worktrees/feature/{name} reflog

# If worktree deleted, check git's worktree tracking
git worktree list
```

---

### 4. Partial Completion Script Failure

**Fix workers:** The `./fixed` script does multiple things:
1. `git push`
2. `v0-mergeq --enqueue`
3. `wk done {id}`

If script fails mid-way, work is partially complete.

**Feature workers:** The `./done` script only terminates Claude. Issue closing is handled by `on-complete.sh`, which runs after Claude exits and closes any remaining open issues as a safety net.

**Failure scenarios (fix workers):**

| Push | Enqueue | wk done | Result |
|------|---------|---------|--------|
| ✓ | ✗ | — | Branch on remote, never merged |
| ✓ | ✓ | ✗ | Merges but issue stays open |
| ✗ | — | — | Work only in local worktree |

**Diagnosis:**
```bash
# Check what succeeded
git ls-remote origin fix/{id}           # push succeeded?
v0 mergeq --list | grep {id}            # enqueue succeeded?
wk show {id} | grep status              # wk done succeeded?
```

**Recovery:**
```bash
# If pushed but not enqueued
v0 mergeq --enqueue fix/{id}

# If merged but issue open
wk done {id}

# If not pushed, find worktree and push
git -C BUILD_DIR/fix/{id}/worktree push -u origin HEAD
```

---

### 5. Race Condition: State Changes During Check

Hook checks issue status, then exits. Between check and exit, state can change.

**Scenario A:** Issue closed after check, hook blocks unnecessarily
- Low impact, just annoying

**Scenario B:** Issue created after check, work exits incomplete
- High impact if new issue was critical

**Mitigation:** Hooks are point-in-time checks; re-run feature with `--resume` if needed.

---

## Hook Behavior Differences

### stop-fix.sh vs stop-chore.sh

```bash
# stop-fix.sh: Only blocks on in_progress
IN_PROGRESS=$(wk list --type bug --status in_progress ...)

# stop-chore.sh: Blocks on ready OR in_progress
READY_CHORES=$(wk ready --type chore ...)
IN_PROGRESS=$(wk list --type chore --status in_progress ...)
```

**Implication:** Fix worker can exit with pending `todo` bugs (by design: one bug per session). Chore worker blocks if any chores are ready.

---

## Debugging Hook Execution

### Test hook manually

```bash
# Simulate hook input
echo '{"stop_hook_active": false}' | \
  V0_PLAN_LABEL="plan:myfeature" \
  V0_OP="myfeature" \
  V0_WORKTREE="/path/to/worktree" \
  ./lib/hooks/stop-feature.sh
```

### Check hook output format

Hooks must output valid JSON:
```json
{"decision": "approve"}
{"decision": "block", "reason": "..."}
```

If hook exits non-zero or outputs invalid JSON, behavior is undefined.

### Common hook failures

```bash
# jq not installed
which jq || echo "jq missing - hooks will fail"

# wk not authenticated
wk whoami || echo "wk auth broken"

# Worktree path invalid
[ -d "$V0_WORKTREE" ] || echo "worktree missing"
```

---

## Source Files

- `lib/hooks/stop-feature.sh` — Feature completion validation
- `lib/hooks/stop-fix.sh` — Fix completion validation
- `lib/hooks/stop-chore.sh` — Chore completion validation
- `lib/hooks/stop-merge.sh` — Merge conflict detection
- `lib/hooks/stop-uncommitted.sh` — Uncommitted changes detection
- `lib/hooks/notify-progress.sh` — Progress notifications (non-blocking)
