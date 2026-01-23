# Set Terminal Name in v0 watch

**Root Feature:** `v0-822e`

## Overview

Set the terminal/window title to "Watch: dirbasename/" when running `v0 watch` in supported environments. This helps users identify v0 watch sessions in their terminal tabs, tmux panes, or window managers. The title will be set when the watch loop starts and optionally restored when exiting.

## Project Structure

```
bin/v0-watch                   # Main file to modify - add terminal title setting
lib/v0-common.sh               # Add shared terminal title utility functions
tests/unit/v0-watch.bats       # Add tests for terminal title behavior
```

## Dependencies

- No new external dependencies
- Uses standard OSC (Operating System Command) escape sequences supported by most modern terminals

## Implementation Phases

### Phase 1: Add Terminal Title Utility Functions to v0-common.sh

**Goal**: Create reusable functions for setting terminal titles that handle environment detection.

**Key functions**:

```bash
# Check if terminal supports title setting
# Returns 0 if supported, 1 if not
v0_terminal_supports_title() {
    # Must be a TTY
    [[ -t 1 ]] || return 1

    # Check for known unsupported terminals
    case "${TERM:-}" in
        dumb|"") return 1 ;;
    esac

    return 0
}

# Set terminal window/tab title
# Usage: v0_set_terminal_title "My Title"
v0_set_terminal_title() {
    local title="$1"
    v0_terminal_supports_title || return 0

    # OSC 0 sets both icon name and window title (most compatible)
    # Format: ESC ] 0 ; <title> BEL
    printf '\033]0;%s\007' "$title"
}

# Save current title and restore on exit (optional enhancement)
# Sets trap to restore title on script exit
v0_save_terminal_title() {
    # Note: Most terminals don't support querying the current title
    # So we'll use a sensible default for restoration
    :
}
```

**Environment compatibility**:
- Standard terminals (xterm, iTerm2, Terminal.app, GNOME Terminal, etc.): OSC 0 works
- tmux: OSC sequences pass through to outer terminal
- screen: OSC sequences pass through
- dumb terminals: Gracefully skipped

**Verification**:
- Run `source lib/v0-common.sh && v0_set_terminal_title "Test"` and verify title changes
- Run with `TERM=dumb` and verify no escape sequences are emitted

---

### Phase 2: Integrate Terminal Title into v0-watch

**Goal**: Set terminal title at watch loop start to "Watch: dirbasename/".

**Implementation in bin/v0-watch**:

1. Add title setting before the main loop:

```bash
# Set terminal title for easy identification
# Format: "Watch: projectdir/"
project_name=$(basename "$(pwd)")
v0_set_terminal_title "Watch: ${project_name}/"
```

2. Location: After argument parsing, before the `while true` loop (around line 126)

3. Optional: Add `--no-title` flag to disable title setting for users who don't want it

**Verification**:
- Run `v0 watch --max-iterations 1` and verify terminal title changes
- Check title shows "Watch: projectdir/"

---

### Phase 3: Add Unit Tests

**Goal**: Verify terminal title behavior in tests.

**Test cases to add in tests/unit/v0-watch.bats**:

```bash
@test "watch sets terminal title with project name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Capture output including escape sequences
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT TERM=xterm bash -c '
        cd "'"$project_dir"'"
        # Capture raw output to see escape sequences
        "'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 | cat -v
    '
    # Should contain OSC title escape sequence
    # ^[]0;Watch: project/^G (cat -v representation)
    assert_output --partial "Watch: project/"
}

@test "watch skips terminal title with dumb TERM" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT TERM=dumb bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 | cat -v
    '
    # Should NOT contain escape sequences
    refute_output --partial "^["
}
```

**Verification**: Run `make test-file FILE=tests/unit/v0-watch.bats`

---

### Phase 4: Documentation and Edge Cases

**Goal**: Handle edge cases and document behavior.

**Edge cases to handle**:
1. Non-TTY output (piped to file): Skip title setting
2. Unknown TERM type: Attempt title setting (most support it)
3. Very long directory names: Consider truncation (optional)

**Documentation**: Update help text if `--no-title` flag is added:

```
Options:
  ...
  --no-title            Don't set terminal window title
```

**Verification**:
- Test with stdout redirected to file
- Test in tmux and verify title appears

---

## Key Implementation Details

### OSC Escape Sequence Format

Terminal titles use OSC (Operating System Command) escape sequences:

```
ESC ] 0 ; <title> BEL
\033 ] 0 ; <title> \007
```

- `ESC ]` (0x1B 0x5D): Introduces OSC sequence
- `0`: Parameter meaning "set icon name and window title"
- `;`: Separator
- `<title>`: The title text
- `BEL` (0x07): Terminates the sequence

Alternative terminator `ST` (String Terminator = `ESC \`) can be used but `BEL` is more widely supported.

### TTY Detection

The check `[[ -t 1 ]]` verifies stdout (file descriptor 1) is connected to a terminal. This is already used in v0-common.sh for color support and follows the same pattern.

### Title Restoration

Many terminals don't support querying the current title, so restoration is impractical. Options:
1. Don't restore (simplest, chosen approach)
2. Restore to shell name (e.g., "bash") on exit
3. Let user configure default title to restore

## Verification Plan

1. **Manual testing**:
   - Run `v0 watch` in a terminal and verify title shows "Watch: dirname/"
   - Run in tmux and verify title appears in pane
   - Run with `TERM=dumb` and verify no visible escape sequences

2. **Automated testing**:
   - Run `make test-file FILE=tests/unit/v0-watch.bats`
   - Verify new tests pass

3. **Integration testing**:
   - Run `make lint` to check shell script quality
   - Run `make test` to verify no regressions

4. **Edge case testing**:
   - Pipe output to file: `v0 watch --max-iterations 1 > /tmp/out`
   - Verify no escape sequences in output file (unless TTY detection is bypassed)
