# ANSI Help Colorization

## Overview

Add consistent color formatting to all CLI help output when running in a TTY. This improves readability by visually distinguishing section headers, commands/flags, and default values using a muted, pastel color palette.

## Project Structure

```
packages/cli/lib/
  v0-common.sh        # Add C_HELP_SECTION, C_HELP_COMMAND, C_HELP_DEFAULT constants
  help-colors.sh      # (new) Helper functions for help colorization

bin/
  v0                  # Update show_help() with colors
  v0-build            # Update usage() with colors
  v0-plan             # Update usage() with colors
  ... (33 commands total, ~29 with help functions)

packages/cli/tests/
  help-colors.bats    # (new) Unit tests for help color functions
```

## Dependencies

- No new external dependencies
- Uses existing ANSI escape code infrastructure in `v0-common.sh`

## Implementation Phases

### Phase 1: Define Help Color Constants

Add three new color constants to `packages/cli/lib/v0-common.sh` (lines 14-35):

```bash
# Help output colors (muted/pastel palette)
if [[ -t 1 ]]; then
    # ... existing colors ...
    C_HELP_SECTION='\033[38;5;74m'   # Pastel cyan/electric blue (256-color)
    C_HELP_COMMAND='\033[38;5;250m'  # Light grey
    C_HELP_DEFAULT='\033[38;5;243m'  # Muted/darker grey
else
    # ... existing empty fallbacks ...
    C_HELP_SECTION=''
    C_HELP_COMMAND=''
    C_HELP_DEFAULT=''
fi
```

**Color palette rationale:**
- `38;5;74` - Pastel cyan/steel blue: readable, professional, not overly bright
- `38;5;250` - Light grey: legible on dark terminals, subdued for command names
- `38;5;243` - Medium grey: clearly muted for defaults, still readable

**Verification:** Run `v0 --help` and confirm no colors appear (constants added but not yet used).

---

### Phase 2: Create Help Colorization Helper

Create `packages/cli/lib/help-colors.sh` with a helper function:

```bash
#!/bin/bash
# help-colors.sh - Helper functions for colorizing help output

# Format help text with consistent colors
# Reads from stdin, writes to stdout
# Colorizes:
#   - Section headers (lines ending with :)
#   - Commands and flags (words starting with - or after whitespace at line start)
#   - Defaults (text in parentheses containing "default")
v0_colorize_help() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Section headers: lines that end with ":" and start at column 0
        if [[ "$line" =~ ^[A-Z][a-zA-Z\ ]*:$ ]]; then
            printf '%b%s%b\n' "${C_HELP_SECTION}" "$line" "${C_RESET}"
        # Lines with commands/flags
        elif [[ "$line" =~ ^[\ ]{2,} ]]; then
            # Colorize defaults in parentheses
            line=$(echo "$line" | sed -E "s/\(([^)]*default[^)]*)\)/${C_HELP_DEFAULT//\\/\\\\}(\1)${C_RESET//\\/\\\\}/gi")
            # Colorize leading command/flag (first word after leading spaces)
            if [[ "$line" =~ ^([\ ]+)([a-zA-Z0-9_-]+|--?[a-zA-Z0-9_-]+)(.*) ]]; then
                local spaces="${BASH_REMATCH[1]}"
                local cmd="${BASH_REMATCH[2]}"
                local rest="${BASH_REMATCH[3]}"
                printf '%s%b%s%b%s\n' "$spaces" "${C_HELP_COMMAND}" "$cmd" "${C_RESET}" "$rest"
            else
                printf '%s\n' "$line"
            fi
        else
            printf '%s\n' "$line"
        fi
    done
}

# Wrapper to output help with colors
# Usage: v0_help <<'EOF' ... EOF
v0_help() {
    v0_colorize_help
}
```

Source this in `v0-common.sh` after color definitions.

**Verification:** Source the lib and test manually with `echo -e "Commands:\n  build   Build things" | v0_colorize_help`

---

### Phase 3: Update Main Entry Point (bin/v0)

Convert `bin/v0` show_help() to use colorized output:

```bash
show_help() {
  v0_help <<'EOF'
v0 - A tool to ease you in to multi-agent vibe coding.

Usage: v0 <command> [args]

Commands:
  init [path]   Initialize .v0.rc in current directory (or path)
                Options:
                  --develop <branch>  Target branch for merges (auto-detects 'develop', fallback 'main')
                  --remote <name>     Git remote name (default: origin)
  ...
EOF
}
```

The structure remains identical; only the wrapper function changes.

**Verification:**
- Run `v0 --help` in a TTY - should see colored output
- Run `v0 --help | cat` - should see plain text (no escape codes)

---

### Phase 4: Update All Worker Commands

Update help functions in the core worker commands (13 files):

| File | Function |
|------|----------|
| `bin/v0-build` | `usage()` |
| `bin/v0-plan` | `usage()` |
| `bin/v0-fix` | `usage()` |
| `bin/v0-chore` | `usage()` |
| `bin/v0-merge` | `usage()` |
| `bin/v0-mergeq` | `usage()` |
| `bin/v0-status` | `usage()` |
| `bin/v0-attach` | `usage()` |
| `bin/v0-cancel` | `usage()` |
| `bin/v0-startup` | `usage()` |
| `bin/v0-shutdown` | `usage()` |
| `bin/v0-hold` | `usage()` |
| `bin/v0-roadmap` | `usage()` |

Pattern for each:
```bash
usage() {
  v0_help <<'EOF'
Usage: v0 command ...
...existing help text unchanged...
EOF
  exit 1
}
```

**Verification:** Run `v0 build --help`, `v0 fix --help`, etc. and confirm colored output.

---

### Phase 5: Update Remaining Commands

Update help functions in utility and self-management commands (16 files):

| File | Function |
|------|----------|
| `bin/v0-pull` | `usage()` |
| `bin/v0-push` | `usage()` |
| `bin/v0-watch` | `usage()` |
| `bin/v0-prune` | `usage()` |
| `bin/v0-archive` | `usage()` |
| `bin/v0-tree` | `usage()` |
| `bin/v0-coffee` | `usage()` |
| `bin/v0-talk` | `usage()` |
| `bin/v0-prime` | `usage()` |
| `bin/v0-self` | `show_help()` |
| `bin/v0-self-update` | `usage()` |
| `bin/v0-self-debug` | `usage()` |
| `bin/v0-self-version` | (none, skip) |
| `bin/v0-nudge` | `usage()` |
| `bin/v0-monitor` | `usage()` |
| `bin/v0-plan-exec` | `usage()` |

**Verification:** Spot-check `v0 self --help`, `v0 pull --help`, `v0 coffee --help`.

---

### Phase 6: Add Unit Tests

Create `packages/cli/tests/help-colors.bats`:

```bash
#!/usr/bin/env bats

load '../packages/test-support/helpers/test_helper'

setup() {
    source_lib "v0-common.sh"
}

@test "v0_colorize_help colorizes section headers" {
    result=$(echo "Commands:" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;74m'* ]]  # Contains section color
    [[ "$result" == *"Commands:"* ]]
}

@test "v0_colorize_help colorizes command names" {
    result=$(echo "  build   Build things" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;250m'* ]]  # Contains command color
    [[ "$result" == *"build"* ]]
}

@test "v0_colorize_help colorizes defaults" {
    result=$(echo "  --foo   Option (default: bar)" | v0_colorize_help)
    [[ "$result" == *$'\033[38;5;243m'* ]]  # Contains default color
    [[ "$result" == *"default: bar"* ]]
}

@test "v0_colorize_help preserves plain text when not TTY" {
    # Unset colors to simulate non-TTY
    C_HELP_SECTION='' C_HELP_COMMAND='' C_HELP_DEFAULT='' C_RESET=''
    result=$(echo -e "Commands:\n  build   Build" | v0_colorize_help)
    [[ "$result" != *$'\033['* ]]  # No escape codes
}
```

**Verification:** Run `scripts/test cli` to execute the new tests.

---

## Key Implementation Details

### Color Palette Selection

Using 256-color mode (`38;5;N`) for more precise color control:

| Constant | Code | Color | Purpose |
|----------|------|-------|---------|
| `C_HELP_SECTION` | `38;5;74` | Pastel cyan/steel blue | Section headers stand out without being harsh |
| `C_HELP_COMMAND` | `38;5;250` | Light grey | Commands visible but not distracting |
| `C_HELP_DEFAULT` | `38;5;243` | Medium grey | Clearly secondary/metadata |

### TTY Detection

The existing pattern in `v0-common.sh` (`[[ -t 1 ]]`) handles TTY detection. When piped or redirected, color variables are empty strings, so `v0_colorize_help` outputs clean text.

### Heredoc Considerations

Using single-quoted heredocs (`<<'EOF'`) preserves the help text exactly. The colorization happens at output time via the pipe to `v0_colorize_help`, not at parse time.

### Performance

The `v0_colorize_help` function processes line-by-line. Help text is typically <100 lines, so performance impact is negligible.

## Verification Plan

1. **Visual verification:**
   - Run `v0 --help` in terminal - confirm colors display
   - Run `v0 --help | cat` - confirm no escape codes in output
   - Test on light and dark terminal themes

2. **Unit tests:**
   - Run `scripts/test cli` to execute help-colors.bats
   - Tests verify each color type is applied correctly
   - Tests verify non-TTY mode produces clean output

3. **Integration verification:**
   - Run `make lint` - ShellCheck passes on new code
   - Run `make check` - All existing tests still pass

4. **Manual spot-check commands:**
   ```bash
   v0 --help
   v0 build --help
   v0 fix --help
   v0 self --help
   v0 status --help
   ```

5. **Accessibility check:**
   - Verify colors have sufficient contrast
   - Confirm text remains readable without colors
