# Implementation Plan: v0 pull / v0 push

**Root Feature:** `v0-9ee7`

## Overview

Add bidirectional sync commands between user branches and the agent development branch (`V0_DEVELOP_BRANCH`):

- **`v0 pull [branch]`**: Merge changes from the agent branch into the current branch (or specified branch). Supports fast-forward, merge commit, or foreground LLM conflict resolution.

- **`v0 push [branch]`**: Reset the agent branch to match the current branch (or specified branch). Requires `--force` if the agent branch has diverged.

This enables a workflow where users can sync agent work into their local branch, then push their branch state back to reset the agent's starting point.

## Project Structure

```
bin/
  v0-pull                    # New: Pull command CLI
  v0-push                    # New: Push command CLI

packages/
  pushpull/                  # New: Layer 2 package (depends on core)
    lib/
      pushpull.sh            # Entry point, sources modules
      pull.sh                # Pull logic: merge strategies, foreground resolve
      push.sh                # Push logic: divergence check, reset
    tests/
      pull.bats              # Unit tests for pull functions
      push.bats              # Unit tests for push functions
    package.sh               # Package manifest

  cli/
    lib/
      prompts/
        pull-resolve.md      # New: Foreground conflict resolution prompt

tests/
  v0-pull.bats               # Integration tests for v0 pull
  v0-push.bats               # Integration tests for v0 push
```

## Dependencies

- **Internal packages**: `core` (config, git-verify)
- **External tools**: git, claude (for --resolve mode)
- **No new external dependencies required**

## Implementation Phases

### Phase 1: Package Scaffold and Core Pull Logic

Create the new `pushpull` package with basic pull functionality (fast-forward and merge commit).

**Files to create:**

1. `packages/pushpull/package.sh`:
```bash
PKG_NAME="pushpull"
PKG_DEPS=(core)
PKG_EXPORTS=(lib/pushpull.sh)
```

2. `packages/pushpull/lib/pushpull.sh`:
```bash
#!/bin/bash
# Entry point - sources modules
source "${V0_DIR}/packages/pushpull/lib/pull.sh"
source "${V0_DIR}/packages/pushpull/lib/push.sh"
```

3. `packages/pushpull/lib/pull.sh` - Core functions:

```bash
# pp_get_agent_branch
# Returns the agent branch name (from V0_DEVELOP_BRANCH config)
pp_get_agent_branch() {
    echo "${V0_DEVELOP_BRANCH:-agent}"
}

# pp_resolve_target_branch [branch]
# Returns the target branch - specified branch or current branch
pp_resolve_target_branch() {
    local branch="${1:-}"
    if [[ -n "${branch}" ]]; then
        echo "${branch}"
    else
        git rev-parse --abbrev-ref HEAD
    fi
}

# pp_fetch_agent_branch
# Fetch latest from remote agent branch
pp_fetch_agent_branch() {
    local agent_branch
    agent_branch=$(pp_get_agent_branch)
    git fetch "${V0_GIT_REMOTE}" "${agent_branch}" 2>/dev/null
}

# pp_has_conflicts <source_branch>
# Check if merge would have conflicts (same as mg_has_conflicts)
pp_has_conflicts() {
    local source_branch="$1"
    ! git merge-tree --write-tree HEAD "${source_branch}" >/dev/null 2>&1
}

# pp_do_pull <agent_branch>
# Execute pull: fast-forward, then merge commit
# Returns 0 on success, 1 on failure (conflicts)
pp_do_pull() {
    local agent_branch="$1"
    local remote_ref="${V0_GIT_REMOTE}/${agent_branch}"

    # Try fast-forward first
    if git merge --ff-only "${remote_ref}" 2>/dev/null; then
        echo "Fast-forward merge successful"
        return 0
    fi

    # Try merge commit
    if git merge --no-edit "${remote_ref}" 2>/dev/null; then
        echo "Merge commit created"
        return 0
    fi

    # Merge failed (conflicts)
    git merge --abort 2>/dev/null || true
    return 1
}
```

4. `bin/v0-pull` - Initial version (no --resolve):

```bash
#!/bin/bash
set -e

V0_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${V0_DIR}/packages/cli/lib/v0-common.sh"
v0_load_config

source "${V0_DIR}/packages/pushpull/lib/pushpull.sh"

usage() {
    cat <<EOF
Usage: v0 pull [branch] [--resolve]

Pull changes from the agent branch (${V0_DEVELOP_BRANCH}) into the current
branch or [branch] if specified.

Options:
  --resolve    If conflicts exist, run claude to resolve them (foreground)

Examples:
  v0 pull                  # Pull into current branch
  v0 pull main             # Pull into main branch
  v0 pull --resolve        # Pull with LLM conflict resolution
EOF
    exit 1
}

# Parse arguments
TARGET_BRANCH=""
RESOLVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resolve) RESOLVE=true; shift ;;
        --help|-h) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "${TARGET_BRANCH}" ]]; then
                TARGET_BRANCH="$1"
            fi
            shift
            ;;
    esac
done

# Resolve target branch
TARGET_BRANCH=$(pp_resolve_target_branch "${TARGET_BRANCH}")
AGENT_BRANCH=$(pp_get_agent_branch)

echo "Pulling ${V0_GIT_REMOTE}/${AGENT_BRANCH} into ${TARGET_BRANCH}..."

# Checkout target branch if not current
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "${TARGET_BRANCH}" != "${CURRENT_BRANCH}" ]]; then
    git checkout "${TARGET_BRANCH}"
fi

# Fetch latest
pp_fetch_agent_branch

# Attempt pull
if pp_do_pull "${AGENT_BRANCH}"; then
    echo "Pull complete."
else
    echo "Error: Merge would have conflicts."
    echo "To resolve with agent assistance:"
    echo "  v0 pull --resolve"
    exit 1
fi
```

**Milestone**: `v0 pull` works for fast-forward and merge commits (no conflicts).

---

### Phase 2: Foreground LLM Conflict Resolution

Add `--resolve` support that runs claude in the foreground (not tmux).

**Key implementation:**

1. `packages/cli/lib/prompts/pull-resolve.md`:
```markdown
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
```

2. Add to `packages/pushpull/lib/pull.sh`:

```bash
# pp_run_foreground_resolve <agent_branch> <target_branch>
# Run claude in foreground to resolve conflicts
# Returns 0 on success, 1 on failure
pp_run_foreground_resolve() {
    local agent_branch="$1"
    local target_branch="$2"
    local remote_ref="${V0_GIT_REMOTE}/${agent_branch}"

    # Start the merge (which will stop at conflicts)
    git merge --no-commit "${remote_ref}" 2>/dev/null || true

    # Check we have conflicts to resolve
    if ! git status --porcelain | grep -q '^UU\|^AA\|^DD'; then
        echo "No conflicts detected"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    # Get context for prompt
    local base merge_commits branch_commits
    base=$(git merge-base HEAD "${remote_ref}")
    merge_commits=$(git log --oneline "${base}..${remote_ref}")
    branch_commits=$(git log --oneline "${base}..HEAD")

    # Create done script in current directory
    cat > ./done <<'DONE_SCRIPT'
#!/bin/bash
find_claude() {
  local pid=$1
  while [[ -n "${pid}" ]] && [[ "${pid}" != "1" ]]; do
    local cmd
    cmd=$(ps -o comm= -p "${pid}" 2>/dev/null)
    if [[ "${cmd}" == *"claude"* ]]; then
      echo "${pid}"
      return
    fi
    pid=$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')
  done
}
CLAUDE_PID=$(find_claude $$)
if [[ -n "${CLAUDE_PID}" ]]; then
  kill -TERM "${CLAUDE_PID}" 2>/dev/null || true
fi
exit 0
DONE_SCRIPT
    chmod +x ./done
    trap 'rm -f ./done' EXIT

    # Build prompt
    local prompt
    prompt="$(cat "${V0_DIR}/packages/cli/lib/prompts/pull-resolve.md")

Resolve the merge conflicts.

Commits from agent branch (${agent_branch}):
${merge_commits}

Commits on your branch (${target_branch}):
${branch_commits}

Run: git status"

    echo ""
    echo "=== Starting foreground conflict resolution ==="
    echo ""

    # Run claude in foreground (blocking)
    if ! claude --model opus --dangerously-skip-permissions \
         --allow-dangerously-skip-permissions "${prompt}"; then
        echo "Claude exited with error"
        rm -f ./done
        git merge --abort 2>/dev/null || true
        return 1
    fi

    rm -f ./done

    # Verify resolution
    if git status --porcelain | grep -q '^UU\|^AA\|^DD'; then
        echo "Error: Conflicts still exist after resolution"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    return 0
}
```

3. Update `bin/v0-pull` to use `--resolve`:

```bash
# ... (after pp_do_pull fails) ...

if pp_do_pull "${AGENT_BRANCH}"; then
    echo "Pull complete."
elif [[ "${RESOLVE}" = true ]]; then
    echo "Conflicts detected. Starting foreground resolution..."
    if pp_run_foreground_resolve "${AGENT_BRANCH}" "${TARGET_BRANCH}"; then
        echo "Pull complete (after resolution)."
    else
        echo "Error: Conflict resolution failed"
        exit 1
    fi
else
    echo "Error: Merge would have conflicts."
    echo "To resolve with agent assistance:"
    echo "  v0 pull --resolve"
    exit 1
fi
```

**Milestone**: `v0 pull --resolve` runs claude in foreground to resolve conflicts.

---

### Phase 3: Push Command with Divergence Detection

Implement `v0 push` to reset the agent branch to the current branch state.

**Key implementation:**

1. `packages/pushpull/lib/push.sh`:

```bash
# pp_get_last_push_commit
# Get the commit hash from last v0 push (stored in .v0/last-push)
pp_get_last_push_commit() {
    local marker_file="${V0_ROOT}/.v0/last-push"
    if [[ -f "${marker_file}" ]]; then
        cat "${marker_file}"
    fi
}

# pp_set_last_push_commit <commit>
# Record the commit hash of current push
pp_set_last_push_commit() {
    local commit="$1"
    mkdir -p "${V0_ROOT}/.v0"
    echo "${commit}" > "${V0_ROOT}/.v0/last-push"
}

# pp_agent_has_diverged
# Check if agent branch has commits since last push
# Returns 0 if diverged (has new commits), 1 if not
pp_agent_has_diverged() {
    local agent_branch remote_ref last_push current_agent
    agent_branch=$(pp_get_agent_branch)
    remote_ref="${V0_GIT_REMOTE}/${agent_branch}"

    # Fetch latest state
    git fetch "${V0_GIT_REMOTE}" "${agent_branch}" 2>/dev/null || true

    last_push=$(pp_get_last_push_commit)
    if [[ -z "${last_push}" ]]; then
        # No record of last push - check if agent has any commits not on current branch
        current_agent=$(git rev-parse "${remote_ref}" 2>/dev/null)
        current_head=$(git rev-parse HEAD)

        # If agent is ancestor of HEAD, no divergence
        if git merge-base --is-ancestor "${remote_ref}" HEAD 2>/dev/null; then
            return 1  # Not diverged
        fi
        return 0  # Diverged (agent has commits not in HEAD)
    fi

    current_agent=$(git rev-parse "${remote_ref}" 2>/dev/null || echo "")
    if [[ "${current_agent}" == "${last_push}" ]]; then
        return 1  # Not diverged
    fi

    # Agent has moved - check if it's just our previous push that was FF'd
    if git merge-base --is-ancestor "${last_push}" "${remote_ref}" 2>/dev/null; then
        # Check if there are commits on agent since our last push
        local new_commits
        new_commits=$(git log --oneline "${last_push}..${remote_ref}" 2>/dev/null | wc -l)
        if [[ "${new_commits}" -gt 0 ]]; then
            return 0  # Diverged
        fi
    fi

    return 1  # Not diverged
}

# pp_show_divergence
# Show commits on agent branch since last push
pp_show_divergence() {
    local agent_branch remote_ref last_push
    agent_branch=$(pp_get_agent_branch)
    remote_ref="${V0_GIT_REMOTE}/${agent_branch}"
    last_push=$(pp_get_last_push_commit)

    if [[ -n "${last_push}" ]]; then
        echo "Commits on agent since last push:"
        git log --oneline "${last_push}..${remote_ref}"
    else
        echo "Commits on agent not in current branch:"
        git log --oneline "HEAD..${remote_ref}"
    fi
}

# pp_do_push <source_branch>
# Reset agent branch to source_branch
pp_do_push() {
    local source_branch="$1"
    local agent_branch source_commit
    agent_branch=$(pp_get_agent_branch)
    source_commit=$(git rev-parse "${source_branch}")

    # Push with force to reset agent branch
    if git push "${V0_GIT_REMOTE}" "${source_branch}:${agent_branch}" --force; then
        pp_set_last_push_commit "${source_commit}"
        echo "Agent branch ${agent_branch} reset to ${source_branch}"
        return 0
    fi

    echo "Error: Push failed"
    return 1
}
```

2. `bin/v0-push`:

```bash
#!/bin/bash
set -e

V0_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${V0_DIR}/packages/cli/lib/v0-common.sh"
v0_load_config

source "${V0_DIR}/packages/pushpull/lib/pushpull.sh"

usage() {
    cat <<EOF
Usage: v0 push [branch] [-f|--force]

Reset the agent branch (${V0_DEVELOP_BRANCH}) to match the current branch
or [branch] if specified.

Options:
  -f, --force    Force push even if agent has new commits

Examples:
  v0 push                  # Push current branch to agent
  v0 push main             # Push main to agent
  v0 push --force          # Force push (overwrites agent commits)
EOF
    exit 1
}

# Parse arguments
SOURCE_BRANCH=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force) FORCE=true; shift ;;
        --help|-h) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "${SOURCE_BRANCH}" ]]; then
                SOURCE_BRANCH="$1"
            fi
            shift
            ;;
    esac
done

# Resolve source branch
SOURCE_BRANCH=$(pp_resolve_target_branch "${SOURCE_BRANCH}")
AGENT_BRANCH=$(pp_get_agent_branch)

echo "Pushing ${SOURCE_BRANCH} to ${V0_GIT_REMOTE}/${AGENT_BRANCH}..."

# Check for divergence
if pp_agent_has_diverged; then
    echo ""
    pp_show_divergence
    echo ""

    if [[ "${FORCE}" = true ]]; then
        echo -e "${C_YELLOW}Warning:${C_RESET} Force pushing will overwrite agent commits."
    else
        echo -e "${C_RED}Error:${C_RESET} Agent branch has new commits since last push."
        echo ""
        echo "To see what would be lost:"
        echo "  git log HEAD..${V0_GIT_REMOTE}/${AGENT_BRANCH}"
        echo ""
        echo "To force push (overwrites agent work):"
        echo "  v0 push --force"
        exit 1
    fi
fi

if pp_do_push "${SOURCE_BRANCH}"; then
    echo "Push complete."
else
    exit 1
fi
```

**Milestone**: `v0 push` works with divergence detection and `--force` flag.

---

### Phase 4: CLI Integration and Dispatcher

Add commands to main `v0` dispatcher.

**Update `bin/v0`:**

Find the case statement and add:
```bash
  pull|push)
    # Check if we're in a project
    if ! v0_find_project_root >/dev/null 2>&1; then
        v0_check_standalone_mode "${CMD}"
    fi
    exec "${V0_DIR}/bin/v0-${CMD}" "$@"
    ;;
```

**Milestone**: `v0 pull` and `v0 push` work from main dispatcher.

---

### Phase 5: Unit Tests

Create unit tests for the pushpull package.

1. `packages/pushpull/tests/pull.bats`:
```bash
#!/usr/bin/env bats
load '../../test-support/helpers/test_helper'

setup() {
    setup_test_repo
    source_lib "pushpull.sh"
}

teardown() {
    teardown_test_repo
}

@test "pp_get_agent_branch returns V0_DEVELOP_BRANCH" {
    V0_DEVELOP_BRANCH="agent"
    run pp_get_agent_branch
    assert_success
    assert_output "agent"
}

@test "pp_resolve_target_branch uses current branch when none specified" {
    run pp_resolve_target_branch ""
    assert_success
    # Should return current branch name
}

@test "pp_resolve_target_branch uses specified branch" {
    run pp_resolve_target_branch "feature-x"
    assert_success
    assert_output "feature-x"
}

@test "pp_has_conflicts returns 1 when no conflicts" {
    # Setup clean merge scenario
    run pp_has_conflicts "origin/agent"
    assert_failure  # 1 = no conflicts
}
```

2. `packages/pushpull/tests/push.bats`:
```bash
#!/usr/bin/env bats
load '../../test-support/helpers/test_helper'

setup() {
    setup_test_repo
    source_lib "pushpull.sh"
}

teardown() {
    teardown_test_repo
}

@test "pp_get_last_push_commit returns empty when no marker" {
    run pp_get_last_push_commit
    assert_success
    assert_output ""
}

@test "pp_set_last_push_commit creates marker file" {
    pp_set_last_push_commit "abc123"
    run pp_get_last_push_commit
    assert_success
    assert_output "abc123"
}

@test "pp_agent_has_diverged returns 1 when not diverged" {
    # Setup non-diverged state
    run pp_agent_has_diverged
    assert_failure  # 1 = not diverged
}
```

**Milestone**: Unit tests pass for core functions.

---

### Phase 6: Integration Tests

Create integration tests that test the full commands.

1. `tests/v0-pull.bats`:
```bash
#!/usr/bin/env bats

load 'helpers/integration_helper'

setup() {
    setup_integration_test
    create_agent_branch_with_commits
}

teardown() {
    teardown_integration_test
}

@test "v0 pull fast-forwards when possible" {
    # Agent has commits ahead of current branch
    run v0 pull
    assert_success
    assert_output --partial "Fast-forward merge successful"
}

@test "v0 pull creates merge commit when needed" {
    # Both branches have diverged
    make_local_commit
    run v0 pull
    assert_success
    assert_output --partial "Merge commit created"
}

@test "v0 pull fails on conflicts without --resolve" {
    create_conflicting_changes
    run v0 pull
    assert_failure
    assert_output --partial "Merge would have conflicts"
}

@test "v0 pull --resolve handles conflicts" {
    # bats test_tags=todo:implement
    skip "Requires claude mock"
}
```

2. `tests/v0-push.bats`:
```bash
#!/usr/bin/env bats

load 'helpers/integration_helper'

setup() {
    setup_integration_test
}

teardown() {
    teardown_integration_test
}

@test "v0 push resets agent branch" {
    make_local_commit
    run v0 push
    assert_success
    assert_output --partial "Push complete"
}

@test "v0 push fails when agent has diverged" {
    v0 push  # Initial push
    make_agent_commit  # Simulate agent work
    make_local_commit
    run v0 push
    assert_failure
    assert_output --partial "Agent branch has new commits"
}

@test "v0 push --force overwrites diverged agent" {
    v0 push  # Initial push
    make_agent_commit  # Simulate agent work
    make_local_commit
    run v0 push --force
    assert_success
    assert_output --partial "Warning"
    assert_output --partial "Push complete"
}
```

**Milestone**: Integration tests pass, full functionality verified.

---

## Key Implementation Details

### Foreground vs Background Resolution

The key difference from existing `v0 merge --resolve`:

| Aspect | v0 merge --resolve | v0 pull --resolve |
|--------|-------------------|-------------------|
| Environment | Worktree | Current directory |
| Execution | tmux session (background) | Foreground (blocking) |
| Hook | Stop hook in .claude/settings.local.json | Simple ./done script |
| Use case | Agent-driven merge queue | User-initiated sync |

### Divergence Detection Strategy

The push command tracks the last pushed commit in `.v0/last-push`. Divergence is detected when:

1. The agent branch has commits not in the source branch
2. The agent branch has moved since the last recorded push

This allows the workflow:
```
v0 pull          # Get agent changes
# ... work ...
v0 push          # Reset agent to my state (safe if agent hasn't done more work)
```

### Git Operations Flow

**Pull:**
```
git fetch origin agent
git merge --ff-only origin/agent || git merge --no-edit origin/agent || resolve
```

**Push:**
```
git fetch origin agent
# Check divergence
git push origin current:agent --force
# Record push marker
```

## Verification Plan

### Manual Testing Checklist

1. **Fast-forward pull**:
   - Create commits on agent branch
   - Run `v0 pull` from behind branch
   - Verify FF merge succeeds

2. **Merge commit pull**:
   - Create commits on both branches
   - Run `v0 pull`
   - Verify merge commit created

3. **Conflict resolution**:
   - Create conflicting changes
   - Run `v0 pull --resolve`
   - Verify claude resolves conflicts

4. **Basic push**:
   - Make local commits
   - Run `v0 push`
   - Verify agent branch updated

5. **Divergence detection**:
   - Push, then make agent commits
   - Run `v0 push`
   - Verify error message

6. **Force push**:
   - Same as above, but use `--force`
   - Verify warning and success

### Automated Tests

```bash
scripts/test pushpull      # Package unit tests
scripts/test v0-pull       # Pull integration tests
scripts/test v0-push       # Push integration tests
make check                 # Full lint + test suite
```
