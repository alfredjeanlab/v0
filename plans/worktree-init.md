# Worktree Init Hook Implementation Plan

**Root Feature:** `v0-296e`

## Overview

Add a user-configurable worktree initialization hook that runs a custom script/command after `v0 tree` creates a new git worktree. This enables users to set up worktree-specific resources (like copying cached dependencies) without manual intervention. The hook runs in the new worktree directory and receives environment variables with paths to both the main checkout and the new tree.

## Project Structure

Files to modify:
```
bin/v0-tree              # Add hook execution after worktree creation
lib/v0-common.sh         # Add V0_WORKTREE_INIT to defaults and config loading
.v0.rc                   # Add example/documentation for the hook
README.md                # Document the feature in Configuration section
tests/unit/v0-tree.bats  # Add tests for the hook functionality
```

## Dependencies

No new external dependencies. Uses existing shell infrastructure.

## Implementation Phases

### Phase 1: Configuration Support

Add the `V0_WORKTREE_INIT` variable to the configuration system.

**lib/v0-common.sh** - Add to defaults (around line 105):
```bash
V0_WORKTREE_INIT="${V0_WORKTREE_INIT:-}"  # Optional worktree init hook
```

**lib/v0-common.sh** - Export the variable (around line 138):
```bash
export V0_WORKTREE_INIT
```

**.v0.rc** - Add documented example:
```bash
# Worktree initialization hook (optional)
# Runs after 'v0 tree' creates a new worktree. Executed in the worktree directory.
# Environment variables available:
#   V0_CHECKOUT_DIR - Path to the main project checkout (V0_ROOT)
#   V0_WORKTREE_DIR - Path to the new worktree directory
# Example: Copy cached test framework to avoid reinstalling per-worktree
# V0_WORKTREE_INIT='cp -r "${V0_CHECKOUT_DIR}/lib/bats" "${V0_WORKTREE_DIR}/lib/"'
```

**Milestone:** Configuration variable is recognized and exported.

---

### Phase 2: Hook Execution in v0-tree

Implement the hook execution logic in `bin/v0-tree` after worktree creation.

**bin/v0-tree** - Add after settings sync (around line 159, after the `.claude/settings.json` copy):
```bash
# Run worktree init hook if configured
if [[ -n "${V0_WORKTREE_INIT:-}" ]]; then
  (
    export V0_CHECKOUT_DIR="${V0_ROOT}"
    export V0_WORKTREE_DIR="${WORKTREE}"
    cd "${WORKTREE}" || exit 1
    eval "${V0_WORKTREE_INIT}"
  ) || v0_warn "Worktree init hook failed (exit code: $?)"
fi
```

Key design decisions:
- **Subshell execution**: Prevents hook from polluting parent environment
- **Non-fatal failure**: Warns but doesn't fail worktree creation
- **eval for flexibility**: Allows variable expansion in the hook command
- **cd into worktree**: Hook runs in the new worktree directory as documented

**Milestone:** Hook executes after `v0 tree` creates a worktree.

---

### Phase 3: Help Text Updates

Add help text for the configuration option.

**bin/v0-tree** - Update usage/help section:
```bash
# In the help text section, add:
#   V0_WORKTREE_INIT    Optional shell command to run after worktree creation.
#                       Runs in the worktree directory with V0_CHECKOUT_DIR and
#                       V0_WORKTREE_DIR environment variables set.
```

**bin/v0** - If there's a `v0 config` or help command, document the option there too.

**Milestone:** `v0 tree --help` documents the hook.

---

### Phase 4: README Documentation

Update README.md Configuration section.

**README.md** - Add to Configuration section:
```markdown
### Worktree Initialization Hook

The `V0_WORKTREE_INIT` setting lets you run a custom command after each worktree
is created. This is useful for copying cached dependencies or setting up
worktree-specific resources.

The command runs in the new worktree directory with these environment variables:
- `V0_CHECKOUT_DIR` - Path to the main project checkout
- `V0_WORKTREE_DIR` - Path to the new worktree

Example in `.v0.rc`:
```bash
# Copy bats test framework to avoid reinstalling per-worktree
V0_WORKTREE_INIT='cp -r "${V0_CHECKOUT_DIR}/lib/bats" "${V0_WORKTREE_DIR}/lib/"'
```
```

**Milestone:** User documentation is complete.

---

### Phase 5: Test Coverage

Add tests for the worktree init hook functionality.

**tests/unit/v0-tree.bats** - Add test cases:

```bash
@test "v0 tree runs V0_WORKTREE_INIT hook after creation" {
  # Setup: Create a marker file to verify hook execution
  export V0_WORKTREE_INIT='touch "${V0_WORKTREE_DIR}/.init-hook-ran"'

  run v0 tree test-init
  assert_success

  # Extract worktree path from output
  worktree_dir=$(echo "$output" | grep -A1 "^TREE_DIR" | tail -1)

  # Verify hook ran
  assert [ -f "${worktree_dir}/.init-hook-ran" ]
}

@test "v0 tree continues if V0_WORKTREE_INIT hook fails" {
  export V0_WORKTREE_INIT='exit 1'

  run v0 tree test-init-fail
  assert_success  # Should still succeed
  assert_output --partial "Worktree init hook failed"
}

@test "v0 tree hook receives correct environment variables" {
  export V0_WORKTREE_INIT='echo "CHECKOUT=${V0_CHECKOUT_DIR}" > "${V0_WORKTREE_DIR}/.hook-env"'

  run v0 tree test-init-env
  assert_success

  worktree_dir=$(echo "$output" | grep -A1 "^TREE_DIR" | tail -1)

  # Verify V0_CHECKOUT_DIR was set correctly
  run cat "${worktree_dir}/.hook-env"
  assert_output --partial "CHECKOUT=${V0_ROOT}"
}

@test "v0 tree skips hook when V0_WORKTREE_INIT is empty" {
  unset V0_WORKTREE_INIT

  run v0 tree test-no-hook
  assert_success
  refute_output --partial "init hook"
}
```

**Milestone:** All tests pass, hook behavior is verified.

---

### Phase 6: v0 Development Use Case

Configure v0's own `.v0.rc` for the bats-copying use case.

**.v0.rc** - Add the actual hook for v0 development:
```bash
# Copy bats installation to worktrees (avoids reinstall per-worktree)
V0_WORKTREE_INIT='[[ -d "${V0_CHECKOUT_DIR}/lib/bats" ]] && cp -r "${V0_CHECKOUT_DIR}/lib/bats" "${V0_WORKTREE_DIR}/lib/" || true'
```

Note: The `|| true` ensures the hook doesn't fail if bats isn't installed yet in the main checkout.

**Milestone:** v0's worktrees automatically get the bats installation.

## Key Implementation Details

### Environment Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `V0_CHECKOUT_DIR` | Main project root (where `.v0.rc` lives) | `/Users/dev/myproject` |
| `V0_WORKTREE_DIR` | New worktree path | `~/.local/state/v0/myproject/tree/feat-x/myproject` |

### Hook Execution Context

- **Working directory**: The new worktree (`V0_WORKTREE_DIR`)
- **Shell**: Bash (via eval)
- **Failure handling**: Warning logged, worktree creation continues
- **Variable expansion**: Deferred (use single quotes in `.v0.rc`, variables expand at runtime)

### Security Considerations

The hook runs arbitrary shell commands from `.v0.rc`. This is acceptable because:
1. `.v0.rc` is already sourced (trusted user configuration)
2. Users explicitly configure the hook
3. Runs with user's permissions (no escalation)

### Error Handling Pattern

```bash
if [[ -n "${V0_WORKTREE_INIT:-}" ]]; then
  (
    # Subshell isolates failures and env changes
    export V0_CHECKOUT_DIR="${V0_ROOT}"
    export V0_WORKTREE_DIR="${WORKTREE}"
    cd "${WORKTREE}" || exit 1
    eval "${V0_WORKTREE_INIT}"
  ) || v0_warn "Worktree init hook failed (exit code: $?)"
fi
```

- Subshell prevents `cd` or `exit` from affecting parent
- Non-fatal: worktree is still usable even if hook fails
- Exit code captured for debugging

## Verification Plan

### Manual Testing

1. **Basic functionality**:
   ```bash
   # In .v0.rc
   V0_WORKTREE_INIT='echo "Hook ran at $(pwd)" > /tmp/hook-test.log'

   v0 tree test-manual
   cat /tmp/hook-test.log  # Should show worktree path
   ```

2. **Variable expansion**:
   ```bash
   V0_WORKTREE_INIT='echo "${V0_CHECKOUT_DIR} -> ${V0_WORKTREE_DIR}"'
   v0 tree test-vars  # Should print both paths
   ```

3. **Failure handling**:
   ```bash
   V0_WORKTREE_INIT='exit 42'
   v0 tree test-fail  # Should warn but succeed
   ```

4. **Real use case (bats copy)**:
   ```bash
   V0_WORKTREE_INIT='cp -r "${V0_CHECKOUT_DIR}/lib/bats" "${V0_WORKTREE_DIR}/lib/"'
   v0 tree test-bats
   ls ~/.local/state/v0/v0/tree/test-bats/v0/lib/bats  # Should exist
   ```

### Automated Testing

```bash
make test-file FILE=tests/unit/v0-tree.bats
```

All new tests in Phase 5 must pass.

### Linting

```bash
make lint
```

All modified shell scripts must pass ShellCheck.

### Integration Verification

After implementation, verify end-to-end:
```bash
# Clean state
v0 tree test-e2e 2>/dev/null && git worktree remove --force ~/.local/state/v0/v0/tree/test-e2e/v0

# Run with real hook
V0_WORKTREE_INIT='mkdir -p "${V0_WORKTREE_DIR}/.cache" && echo "initialized" > "${V0_WORKTREE_DIR}/.cache/status"'
v0 tree test-e2e

# Verify
cat ~/.local/state/v0/v0/tree/test-e2e/v0/.cache/status  # Should print "initialized"
```
