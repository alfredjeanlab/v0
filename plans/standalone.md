# Standalone Mode Implementation Plan

**Root Feature:** `v0-c305`

## Overview

Enable `v0` to function outside of project directories (without a `.v0.rc` file) for running general-purpose chores. This adds a "standalone mode" where users can log and execute chores from anywhere on their system, with state persisted in a global user directory.

**Supported in standalone mode:**
- `v0 chore` - Log and work on standalone chores
- `v0 talk` / `v0 coffee` / `v0 help` / `v0 version` - No-state commands (already work)

**Requires project context:**
- `v0 plan`, `v0 feature`, `v0 fix`, `v0 decompose`, `v0 tree`
- `v0 merge`, `v0 mergeq`, `v0 status`, `v0 resume`
- `v0 attach`, `v0 cancel`, `v0 shutdown`, `v0 startup`, `v0 hold`

## Project Structure

```
lib/
  v0-common.sh          # Add v0_load_standalone_config(), modify v0_load_config()
  standalone.sh         # NEW: Standalone mode helpers
bin/
  v0                    # Modify command dispatch for standalone awareness
  v0-chore              # Modify to support standalone mode
~/.local/state/v0/
  standalone/           # NEW: Global state directory
    .wok/               # Standalone issue database
      config.toml
      issues.db
    build/              # Build state for standalone chores
      chore/{id}/
    logs/
```

## Dependencies

- No new external dependencies
- Uses existing `wk` CLI for issue database
- Follows XDG Base Directory specification (already used)

## Implementation Phases

### Phase 1: Define Global State Directory

**Goal:** Establish the standalone state directory structure and initialization.

**Files to modify:**
- `lib/v0-common.sh` - Add standalone directory constants

**Implementation:**

```bash
# lib/v0-common.sh - Add after line ~25

# Global standalone state directory (no project required)
V0_STANDALONE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/v0/standalone"

# Initialize standalone directory structure
v0_init_standalone() {
    mkdir -p "${V0_STANDALONE_DIR}/build/chore"
    mkdir -p "${V0_STANDALONE_DIR}/logs"

    # Initialize .wok if not present
    if [[ ! -f "${V0_STANDALONE_DIR}/.wok/config.toml" ]]; then
        (cd "${V0_STANDALONE_DIR}" && wk init --prefix "chore")
    fi
}
```

**Verification:**
- Run `v0_init_standalone` and verify directory structure created
- Verify `.wok/config.toml` exists with `prefix = "chore"`

---

### Phase 2: Create Standalone Config Loader

**Goal:** Add `v0_load_standalone_config()` for commands that work without `.v0.rc`.

**Files to modify:**
- `lib/v0-common.sh` - Add new function

**Implementation:**

```bash
# lib/v0-common.sh - Add new function

# Load standalone configuration (no .v0.rc required)
# Sets minimal variables needed for chore operations
v0_load_standalone_config() {
    v0_init_standalone

    # Set variables that chore command needs
    export V0_STANDALONE=1
    export V0_STATE_DIR="${V0_STANDALONE_DIR}"
    export BUILD_DIR="${V0_STANDALONE_DIR}/build"
    export PROJECT="standalone"
    export ISSUE_PREFIX="chore"

    # No V0_ROOT in standalone mode
    export V0_ROOT=""
    export V0_MAIN_BRANCH=""
}

# Check if we're in standalone mode
v0_is_standalone() {
    [[ "${V0_STANDALONE:-0}" == "1" ]]
}
```

**Verification:**
- Source lib and call `v0_load_standalone_config`
- Verify `V0_STANDALONE=1` and paths are set correctly

---

### Phase 3: Modify Command Dispatcher

**Goal:** Update `bin/v0` to recognize standalone-capable commands and provide clear error messages.

**Files to modify:**
- `bin/v0` - Modify command category handling

**Key changes to `bin/v0`:**

```bash
# bin/v0 - Modify command lists (around line 18-22)

# Commands that require a project (.v0.rc)
PROJECT_COMMANDS="plan tree decompose merge mergeq status feature resume fix attach cancel shutdown startup hold"

# Commands that work in standalone mode (no .v0.rc needed)
STANDALONE_COMMANDS="chore"

# Commands that never need config
NO_CONFIG_COMMANDS="init help version coffee talk"
```

**Add standalone dispatch logic (around line 95):**

```bash
# Check if running in standalone mode
v0_check_standalone_mode() {
    local cmd="$1"

    # Try to find project root
    if v0_find_project_root >/dev/null 2>&1; then
        return 1  # In a project, not standalone
    fi

    # Check if command supports standalone mode
    if [[ " ${STANDALONE_COMMANDS} " == *" ${cmd} "* ]]; then
        return 0  # Standalone mode for this command
    fi

    # Command requires project but we're not in one
    echo "Error: Not in a v0 project directory." >&2
    echo "" >&2
    echo "The command 'v0 ${cmd}' requires a project with a .v0.rc file." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  1. Navigate to a project directory, or" >&2
    echo "  2. Run 'v0 init' to create a new project here" >&2
    echo "" >&2
    echo "Available without a project:" >&2
    echo "  v0 chore    - Work on standalone chores" >&2
    echo "  v0 help     - Show help" >&2
    exit 1
}
```

**Verification:**
- Run `v0 feature` outside project → see clear error message
- Run `v0 chore` outside project → command proceeds
- Run `v0 feature` inside project → works normally

---

### Phase 4: Modify Chore Command for Standalone

**Goal:** Update `v0-chore` to work in both project and standalone modes.

**Files to modify:**
- `bin/v0-chore` - Add standalone mode support

**Key changes:**

```bash
# bin/v0-chore - Near the top, replace v0_load_config call

# Determine if we're in standalone or project mode
if v0_find_project_root >/dev/null 2>&1; then
    v0_load_config
else
    v0_load_standalone_config
fi
```

**Standalone-specific behavior:**
- Use `${V0_STANDALONE_DIR}/.wok` for issue database
- Use `${V0_STANDALONE_DIR}/build/chore/{id}` for worker state
- Skip git worktree creation (work in current directory or temp)
- Use simpler tmux session naming: `v0-chore-{id}`

**Verification:**
- `v0 chore "test task"` outside project creates issue in standalone .wok
- `wk list` in standalone dir shows the chore
- Tmux session starts correctly

---

### Phase 5: Update Worker Template for Standalone

**Goal:** Ensure chore workers function correctly without project context.

**Files to modify:**
- `lib/templates/claude.chore.md` - Add standalone awareness
- `lib/worker-common.sh` - Handle standalone mode in worker functions

**Key considerations:**
- Standalone chores have no git repository context
- Workers should operate in current directory or a temp workspace
- No merge queue integration in standalone mode

**Template additions:**

```markdown
{{#STANDALONE}}
## Standalone Mode

You are running in standalone mode without a project context.
- No git repository is available
- Work in the current directory: {{CWD}}
- Focus on the task without project-specific constraints
{{/STANDALONE}}
```

**Verification:**
- Start a standalone chore and verify CLAUDE.md has correct context
- Worker can execute tasks without git errors

---

### Phase 6: Add Tests and Documentation

**Goal:** Ensure standalone mode is well-tested and documented.

**Files to create/modify:**
- `tests/unit/standalone.bats` - New test file
- `bin/v0-help` - Update help text

**Test cases:**

```bash
# tests/unit/standalone.bats

@test "standalone: v0_init_standalone creates directory structure" {
    # Verify directories and .wok created
}

@test "standalone: v0 chore works without .v0.rc" {
    # Run chore in temp dir without .v0.rc
}

@test "standalone: v0 feature shows error without .v0.rc" {
    # Verify error message is shown
}

@test "standalone: project commands work normally in project" {
    # Verify no regression
}
```

**Verification:**
- `make test` passes all new tests
- `v0 help` shows standalone mode documentation

## Key Implementation Details

### State Directory Location

Following XDG Base Directory specification:
```bash
V0_STANDALONE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/v0/standalone"
```

This creates:
- `~/.local/state/v0/standalone/` (default)
- `$XDG_STATE_HOME/v0/standalone/` (if XDG_STATE_HOME set)

### Issue Database Initialization

The standalone `.wok` database uses prefix `chore`:
```bash
wk init --prefix "chore"
```

Issues will be numbered `chore-1`, `chore-2`, etc.

### Mode Detection Logic

```
v0 <command>
    │
    ├─ Is command in NO_CONFIG_COMMANDS?
    │   └─ Yes → Execute directly (no config needed)
    │
    ├─ Can find .v0.rc?
    │   └─ Yes → Load project config, execute normally
    │
    ├─ Is command in STANDALONE_COMMANDS?
    │   └─ Yes → Load standalone config, execute
    │
    └─ No → Show "not in project" error with guidance
```

### Git Behavior in Standalone Mode

Standalone chores do not use git worktrees:
- If current directory is a git repo, work there
- If not, work in current directory (no git operations)
- Worker CLAUDE.md indicates standalone context

### Tmux Session Naming

- Project mode: `v0-{PROJECT}-chore-{id}`
- Standalone mode: `v0-standalone-chore-{id}`

## Verification Plan

### Manual Testing

1. **Outside any project:**
   ```bash
   cd /tmp
   v0 chore "Test standalone chore"    # Should work
   v0 feature "Test feature"            # Should show error
   v0 plan new-plan                     # Should show error
   ```

2. **Verify state directory:**
   ```bash
   ls ~/.local/state/v0/standalone/
   # Should show: .wok/ build/ logs/

   cat ~/.local/state/v0/standalone/.wok/config.toml
   # Should show: prefix = "chore"
   ```

3. **Inside a project:**
   ```bash
   cd ~/my-project  # Has .v0.rc
   v0 chore "Project chore"    # Uses project .wok
   v0 feature "New feature"    # Works normally
   ```

### Automated Testing

```bash
make test FILE=tests/unit/standalone.bats
make lint
make check
```

### Edge Cases to Test

- Running from `/` (root directory)
- Running with `XDG_STATE_HOME` set
- Running chore in a git repo vs non-git directory
- Concurrent standalone chores
- Interrupting and resuming standalone chores
