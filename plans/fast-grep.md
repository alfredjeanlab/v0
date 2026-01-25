# fast-grep: Prefer ripgrep over grep

## Overview

Replace direct `grep` calls throughout the codebase with a wrapper function that prefers `rg` (ripgrep) when available and falls back to `grep`. This improves performance for large codebases while maintaining compatibility on systems without ripgrep installed.

## Project Structure

```
packages/core/lib/
  grep.sh           # NEW: Wrapper functions for grep operations

bin/                # Update grep calls to use wrapper
packages/           # Update grep calls to use wrapper

README.md           # Add ripgrep as optional dependency
~/Developer/homebrew-tap/Formula/v0.rb  # Add ripgrep dependency
```

## Dependencies

- **ripgrep** (`rg`) - Optional but recommended for performance
  - Homebrew: `brew install ripgrep`
  - Ubuntu: `apt install ripgrep`

## Implementation Phases

### Phase 1: Create Core Wrapper Functions

Create `packages/core/lib/grep.sh` with wrapper functions that detect and use `rg` when available.

**Key functions to implement:**

```bash
# Initialize grep command (call once at script start)
_v0_init_grep() {
  if command -v rg >/dev/null 2>&1; then
    _V0_GREP_CMD="rg"
  else
    _V0_GREP_CMD="grep"
  fi
}

# Basic grep replacement
# v0_grep [options] pattern [file...]
v0_grep() {
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    # Translate grep options to rg equivalents
    _v0_grep_rg "$@"
  else
    grep "$@"
  fi
}

# Quiet mode check (-q)
v0_grep_quiet() {
  local pattern="$1"; shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -q "$pattern" "$@"
  else
    grep -q "$pattern" "$@"
  fi
}

# Extract matches (-o)
v0_grep_extract() {
  local pattern="$1"; shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -o "$pattern" "$@"
  else
    grep -oE "$pattern" "$@"
  fi
}

# Count matches (-c)
v0_grep_count() {
  local pattern="$1"; shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -c "$pattern" "$@" 2>/dev/null || echo "0"
  else
    grep -c "$pattern" "$@"
  fi
}

# Invert match (-v)
v0_grep_invert() {
  local pattern="$1"; shift
  if [[ "$_V0_GREP_CMD" == "rg" ]]; then
    rg -v "$pattern" "$@"
  else
    grep -v "$pattern" "$@"
  fi
}
```

**Option mapping table:**

| grep option | rg equivalent | Notes |
|-------------|---------------|-------|
| `-q` | `-q` | Quiet mode (same) |
| `-o` | `-o` | Only matching (same) |
| `-E` | (default) | Extended regex (rg default) |
| `-c` | `-c` | Count (same) |
| `-v` | `-v` | Invert (same) |
| `-F` | `-F` | Fixed strings (same) |
| `-m1` | `-m 1` | Max count (space required) |
| `-n` | `-n` | Line numbers (same) |

### Phase 2: Update Core Package Files

Update files in `packages/core/` and `packages/mergeq/` to use the wrapper:

**Files to update:**
- `packages/core/lib/config.sh` (6 grep calls)
- `packages/core/lib/pruning.sh` (2 grep calls)
- `packages/mergeq/lib/locking.sh` (1 grep call)
- `packages/mergeq/lib/readiness.sh` (2 grep calls)
- `packages/mergeq/lib/resolution.sh` (1 grep call)

**Pattern:** Source the grep wrapper at the top of each file:
```bash
source "${V0_LIB_DIR}/core/lib/grep.sh"
```

### Phase 3: Update Worker and Hooks Packages

Update files in `packages/worker/`, `packages/hooks/`, `packages/merge/`:

**Files to update:**
- `packages/hooks/lib/stop-uncommitted.sh` (1 call)
- `packages/hooks/lib/stop-roadmap.sh` (1 call)
- `packages/hooks/lib/stop-merge.sh` (1 call)
- `packages/hooks/lib/stop-build.sh` (3 calls)
- `packages/hooks/lib/stop-fix.sh` (1 call)
- `packages/hooks/lib/notify-progress.sh` (2 calls)
- `packages/worker/lib/worker-common.sh` (1 grep call, keep pgrep)
- `packages/worker/lib/nudge-common.sh` (2 grep calls, keep pgrep)
- `packages/merge/lib/conflict.sh` (2 calls)

**Note:** Keep `pgrep` calls as-is. `pgrep` is a separate utility for process matching and should not be wrapped.

### Phase 4: Update CLI and Status Packages

Update files in `packages/cli/` and `packages/status/`:

**Files to update:**
- `packages/cli/lib/v0-common.sh`
- `packages/cli/lib/build/on-complete.sh` (2 calls)
- `packages/cli/lib/build/session-monitor.sh` (2 calls)
- `packages/cli/lib/debug-common.sh` (1 call)
- `packages/status/lib/worker-status.sh` (2 grep calls, keep pgrep)

### Phase 5: Update Bin Scripts

Update bin scripts that use grep directly:

**Files to update:**
- `bin/v0-shutdown` (1 call)
- `bin/v0-status` (4 grep calls)
- `bin/v0-fix` (4 calls)
- `bin/v0-chore` (4 calls)
- `bin/v0-roadmap` (1 call)
- `bin/v0-build-worker` (4 calls)
- `bin/v0-decompose` (1 call)
- `bin/v0-attach` (2 calls)
- `bin/v0-roadmap-worker` (2 calls)
- `bin/v0-build` (3 calls)
- `bin/v0-self-debug` (3 calls)

### Phase 6: Update Documentation and Dependencies

**README.md updates:**
1. Add ripgrep to optional dependencies section
2. Update installation commands

```markdown
### Requirements

- [wok](https://github.com/alfredjeanlab/wok) - Issue tracking
- [claude](https://claude.ai/claude-code) - Claude Code CLI
- git, tmux, jq, flock
- ripgrep (optional, recommended for performance)
```

**Homebrew formula update (`~/Developer/homebrew-tap/Formula/v0.rb`):**
```ruby
depends_on "ripgrep" => :recommended
```

**Manual installation docs:**
```bash
# macOS
brew install flock tmux jq ripgrep

# Ubuntu
sudo apt install flock tmux jq ripgrep
```

## Key Implementation Details

### Detection Strategy

Use command existence check rather than version detection:
```bash
command -v rg >/dev/null 2>&1
```

This is faster than `which` and more portable.

### Option Translation

Most common grep options map directly to rg:
- `-q`, `-o`, `-c`, `-v`, `-F`, `-n` work identically
- `-E` (extended regex) is rg's default, so it can be omitted
- `-m1` becomes `-m 1` (rg requires space)

### Edge Cases

1. **Piped input:** Both grep and rg handle stdin identically
2. **Exit codes:** Both return 0 on match, 1 on no match, 2 on error
3. **Empty pattern:** Handle specially to avoid rg errors
4. **Binary files:** rg has better defaults for binary detection

### What NOT to Change

- `pgrep` calls - process grep is unrelated to text grep
- grep usage in documentation examples (docs/debug/*.md)
- grep in test assertions (tests/*.bats) - these verify specific behavior

## Verification Plan

### Unit Tests

Create `packages/core/tests/grep.bats`:

```bash
@test "v0_grep_quiet returns 0 on match" {
  echo "hello world" | v0_grep_quiet "hello"
}

@test "v0_grep_quiet returns 1 on no match" {
  run bash -c 'echo "hello" | v0_grep_quiet "goodbye"'
  [[ "$status" -eq 1 ]]
}

@test "v0_grep_extract extracts pattern" {
  result=$(echo "issue-abc123" | v0_grep_extract '[a-z]+-[a-z0-9]+')
  [[ "$result" == "issue-abc123" ]]
}

@test "v0_grep_count counts matches" {
  result=$(printf "a\na\nb\n" | v0_grep_count "a")
  [[ "$result" == "2" ]]
}

@test "v0_grep falls back to grep when rg unavailable" {
  # Mock rg absence
  PATH="/usr/bin" _v0_init_grep
  [[ "$_V0_GREP_CMD" == "grep" ]]
}
```

### Integration Testing

1. Run full test suite with ripgrep installed: `make check`
2. Run full test suite with ripgrep uninstalled (PATH manipulation)
3. Verify all existing tests pass in both modes

### Manual Verification

```bash
# Test with rg available
scripts/test

# Test fallback (temporarily hide rg)
PATH=$(echo "$PATH" | sed 's|/opt/homebrew/bin:||') scripts/test
```

## Rollout Checklist

- [ ] Create `packages/core/lib/grep.sh` with wrapper functions
- [ ] Add unit tests for grep wrapper
- [ ] Update packages/core files
- [ ] Update packages/mergeq files
- [ ] Update packages/merge files
- [ ] Update packages/hooks files
- [ ] Update packages/worker files (keep pgrep)
- [ ] Update packages/cli files
- [ ] Update packages/status files
- [ ] Update bin scripts
- [ ] Update README.md dependencies
- [ ] Update homebrew formula
- [ ] Run `make check` to verify
- [ ] Test with rg unavailable to verify fallback
