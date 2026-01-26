# Roadmap: Fix Bugs and Documentation Gaps

## Overview

Address bugs and documentation gaps identified in the `v0 roadmap` feature by comparing `docs/arch/roadmap/state.md` against the implementation in `bin/v0-roadmap`, `bin/v0-roadmap-worker`, and `packages/hooks/lib/stop-roadmap.sh`.

## Files to Modify

```
bin/v0-roadmap                              # Bug fixes
bin/v0-roadmap-worker                       # Bug fixes
packages/hooks/lib/stop-roadmap.sh          # Bug fix
packages/cli/lib/templates/claude.roadmap.m4 # Template fix
docs/arch/roadmap/state.md                  # Documentation gaps
```

## Bugs to Fix

### Bug 1: `--status` Shows All Phases (Should Filter)

**File:** `bin/v0-roadmap:88-104`

**Problem:** The `--status` flag shows all roadmaps regardless of phase, but docs say `completed`, `failed`, and `interrupted` should NOT be shown in status.

**Fix:** Filter out terminal states in the status display loop:

```bash
for state_file in "${ROADMAPS_DIR}"/*/state.json; do
    [[ ! -f "${state_file}" ]] && continue

    phase=$(jq -r '.phase' "${state_file}")
    # Skip terminal/error states per docs
    case "${phase}" in
      completed|failed|interrupted) continue ;;
    esac

    found=1
    # ... rest of display logic
done
```

**Verification:** Run `v0 roadmap --status` with roadmaps in various phases.

---

### Bug 2: Race Condition in `--attach` Mode

**File:** `bin/v0-roadmap:294-298`

**Problem:** Only 1 second sleep after nohup launch before `tail -f`. Worker may not have created log file yet.

**Fix:** Wait for log file to exist with timeout:

```bash
if [[ -n "${ATTACH}" ]]; then
    echo "Following worker log (Ctrl+C to detach)..."
    echo ""
    # Wait for log file to exist (up to 5 seconds)
    for i in {1..50}; do
        [[ -f "${WORKER_LOG}" ]] && break
        sleep 0.1
    done
    if [[ -f "${WORKER_LOG}" ]]; then
        tail -f "${WORKER_LOG}"
    else
        echo "Warning: Log file not created within timeout"
        exit 1
    fi
fi
```

**Verification:** Run `v0 roadmap test "desc" --attach` and verify no errors on slow systems.

---

### Bug 3: `V0_GIT_REMOTE` Not Exported to Stop Hook

**File:** `packages/hooks/lib/stop-roadmap.sh:57`

**Problem:** Stop hook references `${V0_GIT_REMOTE:-origin}` but this variable isn't in the hook's environment.

**Fix in `bin/v0-roadmap-worker:293`:** Add `V0_GIT_REMOTE` to the exported environment:

```bash
tmux new-session -d -s "${SESSION}" -c "${TREE_DIR}" \
    "V0_ROADMAP_NAME='${NAME}' V0_IDEA_ID='${IDEA_ID}' V0_ROOT='${V0_ROOT}' V0_WORKTREE='${WORKTREE}' V0_GIT_REMOTE='${V0_GIT_REMOTE}' claude ${CLAUDE_ARGS} ..."
```

**Verification:** Run roadmap with `V0_GIT_REMOTE=agent`, trigger stop hook, verify correct remote shown.

---

### Bug 4: Template Shows Literal `IDEA_ID` When None

**File:** `packages/cli/lib/templates/claude.roadmap.m4:13`

**Problem:** When no wk issue is created, `IDEA_ID` becomes "none" and the template shows `wk show none` which errors.

**Fix:** Use m4 conditional to hide the wk command when no idea:

```m4
changequote(`[[', `]]')dnl
## Your Mission

Orchestrate the roadmap: **ROADMAP_DESCRIPTION**

ifelse(IDEA_ID, [[none]], [[]], [[The roadmap idea is tracked as IDEA_ID.

]])dnl
## Finding Work

```bash
ifelse(IDEA_ID, [[none]], [[# No idea issue created]], [[# Check roadmap status
wk show IDEA_ID
]])
# List queued features for this roadmap
wk list --label roadmap:ROADMAP_NAME
```
```

**Verification:** Run `v0 roadmap` with wk unavailable, verify CLAUDE.md doesn't reference invalid ID.

---

## Documentation Gaps to Close

### Gap 1: Add `error` Field to State Schema

**File:** `docs/arch/roadmap/state.md:93-129`

**Add to schema:**

```json
{
  ...
  "error": "Orchestration completed without queueing any features",
  ...
}
```

**Add to field table:**

| Field | Description |
|-------|-------------|
| `error` | Error message when phase is `failed` (null otherwise) |

---

### Gap 2: Document `V0_IDEA_ID` Environment Variable

**File:** `docs/arch/roadmap/state.md:145-147`

**Update section:**

```markdown
Environment variables used by stop hook:
- `V0_ROADMAP_NAME`: Roadmap identifier
- `V0_WORKTREE`: Path to worktree for uncommitted changes check
- `V0_IDEA_ID`: Wok issue ID for the roadmap idea (may be "none")
- `V0_GIT_REMOTE`: Git remote name for push commands
```

---

### Gap 3: Document Unknown Phase Handling

**File:** `docs/arch/roadmap/state.md:149-163`

**Add note to Worker Lifecycle section:**

```markdown
### Unknown Phase Handling

If the worker encounters an unrecognized phase (e.g., from a corrupted state file or future schema changes), it treats it as `init` and runs orchestration from the beginning. This provides forward-compatible recovery.
```

---

### Gap 4: Clarify TREE_DIR vs WORKTREE

**File:** `docs/arch/commands/v0-roadmap.md`

**Add section:**

```markdown
## Worktree Structure

The `v0-tree` command returns two paths:
- `TREE_DIR`: Parent directory where the worktree is created
- `WORKTREE`: The actual git worktree directory (repo checkout)

Files like `CLAUDE.md`, `done`, and `incomplete` are placed in `TREE_DIR`.
The agent should `cd` into the repository subdirectory for git operations.

Example:
```
TREE_DIR=/Users/x/.local/state/v0/proj/tree/roadmap/rewrite/
WORKTREE=/Users/x/.local/state/v0/proj/tree/roadmap/rewrite/myrepo/
```
```

---

## Implementation Order

1. **Bug 3** (V0_GIT_REMOTE export) - Simple one-line fix
2. **Bug 4** (m4 template conditional) - Isolated template change
3. **Bug 1** (--status filtering) - Simple logic addition
4. **Bug 2** (attach race condition) - Replace sleep with proper wait
5. **Doc gaps** - Update all documentation together

## Verification Plan

1. Run `scripts/test v0-roadmap` to verify existing tests pass
2. Manual test each bug fix:
   - Create roadmaps in various phases, verify `--status` filtering
   - Test `--attach` mode on slow/fast systems
   - Test with `V0_GIT_REMOTE=agent` and trigger stop hook
   - Test with wk unavailable (mock failure)
3. Review docs for accuracy against updated code
4. Run `make check` for full validation
