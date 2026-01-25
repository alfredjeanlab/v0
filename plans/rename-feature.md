# Plan: Rename "v0 feature" to "v0 build"

## Overview

Rename the primary command `v0 feature` to `v0 build` while maintaining full backward compatibility with the existing `feature` and `feat` aliases. Update all user-facing documentation (README, help text) to use "build" as the primary term, while the old command names continue to work silently.

## Project Structure

Files to modify:

```
bin/
├── v0                      # Main dispatcher: add "build" command, keep feature/feat as aliases
├── v0-feature → v0-build   # Rename primary script, create symlink for compatibility
└── v0-feature-worker → v0-build-worker  # Rename worker, create symlink

lib/
├── feature/ → build/       # Rename directory
│   ├── feature.sh → build.sh
│   └── ...other files
├── hooks/
│   └── stop-feature.sh → stop-build.sh  # Rename hook
├── templates/
│   └── claude.feature.m4 → claude.build.m4  # Rename template
└── prompts/
    └── feature.md → build.md  # Rename prompt template

docs/
├── README.md               # Update examples to use "build"
├── arch/commands/
│   └── v0-feature.md → v0-build.md  # Rename doc
└── debug/
    └── feature.md → build.md  # Rename debug guide
```

## Dependencies

No external dependencies needed. This is a renaming/aliasing task using existing bash tools.

## Implementation Phases

### Phase 1: Create bin/v0-build and update main dispatcher

**Goal:** Add "build" as the primary command name, keep "feature" as an alias.

1. Copy `bin/v0-feature` to `bin/v0-build`
2. Update usage text in `bin/v0-build` to say "v0 build" instead of "v0 feature"
3. Update `bin/v0` main dispatcher:
   - Add "build" to `PROJECT_COMMANDS` list
   - Add "build" to the dispatch case statement (line 210)
   - Move "feature" to aliases section (alongside feat)
   - Update help text to show `build` as primary, remove `feat[ure]` abbreviation

**Changes to bin/v0:**
```bash
# Line 19: Add build to project commands
PROJECT_COMMANDS="plan tree decompose merge mergeq status build feature resume fix attach cancel shutdown startup hold roadmap"

# Line 78: Update help text
  build         Full pipeline: plan -> decompose -> execute -> merge

# Lines 210: Add build to dispatch
  plan|tree|decompose|merge|mergeq|status|watch|build|fix|attach|cancel|shutdown|startup|prune|monitor|hold|roadmap)

# Lines 236-237: Keep feature/feat as aliases pointing to v0-build
  feat|feature)
    exec "${V0_DIR}/bin/v0-build" "$@"
    ;;
```

**Verification:** `v0 build --help` works, `v0 feature --help` still works

### Phase 2: Rename lib/feature/ to lib/build/ and update internal references

**Goal:** Rename the library directory while maintaining symlink compatibility.

1. Rename `lib/feature/` to `lib/build/`
2. Rename files inside:
   - `feature.sh` → `build.sh`
   - Update internal function names if needed (keep as `create_feature_*` for now to minimize changes)
3. Update source statements in `bin/v0-build`:
   ```bash
   # Change from:
   source "${V0_DIR}/lib/feature/feature.sh"
   # To:
   source "${V0_DIR}/lib/build/build.sh"
   ```
4. Create symlink `lib/feature` → `lib/build` for any external scripts

**Verification:** `make lint`, `v0 build auth "test" --dry-run` works

### Phase 3: Rename worker and hooks

**Goal:** Update the worker script and completion hook.

1. Copy `bin/v0-feature-worker` to `bin/v0-build-worker`
2. Update references inside to use `lib/build/`
3. Update `bin/v0` to remove `feature` from dispatch (it's now an alias)
4. Rename `lib/hooks/stop-feature.sh` to `lib/hooks/stop-build.sh`
5. Update hook registration in `bin/v0-build-worker` to reference new hook path
6. Create symlinks for backward compatibility:
   - `bin/v0-feature-worker` → `bin/v0-build-worker`
   - `lib/hooks/stop-feature.sh` → `lib/hooks/stop-build.sh`

**Verification:** `make lint`, worker script sources correctly

### Phase 4: Rename templates and prompts

**Goal:** Update template and prompt file names.

1. Rename `lib/templates/claude.feature.m4` to `lib/templates/claude.build.m4`
2. Update references in `bin/v0-build` to use new template name
3. Rename `lib/prompts/feature.md` to `lib/prompts/build.md`
4. Update references to use new prompt file
5. Create symlinks for backward compatibility if needed

**Verification:** `make lint`, template expansion works

### Phase 5: Update documentation

**Goal:** Update all user-facing documentation to use "build" terminology.

1. Update `README.md`:
   - Change all `v0 feature` examples to `v0 build`
   - Update "Features and Plans" section title to "Builds and Plans" or similar
   - Keep text clear that `feature` still works as an alias

2. Update `bin/v0` help text:
   - Show `build` as the primary command
   - Add note that `feature` is an alias (or omit since it's "silent")

3. Rename documentation files:
   - `docs/arch/commands/v0-feature.md` → `docs/arch/commands/v0-build.md`
   - `docs/debug/feature.md` → `docs/debug/build.md`
   - Update content inside to reference "build"

4. Update any other doc references

**Verification:** `grep -r "v0 feature" docs/` returns minimal results (only alias mentions)

### Phase 6: Update tests and verify

**Goal:** Ensure all tests pass with new naming.

1. Update test files that reference "feature" command:
   - `tests/unit/v0-feature-worker.bats` → consider renaming or updating
   - Update test expectations to use "build" where appropriate
   - Keep tests that verify backward compatibility (feature alias works)

2. Run full test suite: `make check`

3. Manual verification:
   - `v0 build auth "Test" --dry-run` works
   - `v0 feature auth "Test" --dry-run` still works
   - `v0 feat auth "Test" --dry-run` still works
   - `v0 --help` shows "build" as primary

**Verification:** `make check` passes

## Key Implementation Details

### Backward Compatibility Strategy

The approach uses symlinks and aliases to maintain full backward compatibility:

```
bin/v0-feature-worker → bin/v0-build-worker (symlink)
lib/feature → lib/build (symlink)
lib/hooks/stop-feature.sh → lib/hooks/stop-build.sh (symlink)
```

In `bin/v0`:
```bash
# feature and feat are aliases that call v0-build
feat|feature)
  exec "${V0_DIR}/bin/v0-build" "$@"
  ;;
```

### Internal vs External Naming

- **External (user-facing):** Use "build" everywhere in docs, help text, examples
- **Internal (code):** Function names can remain `create_feature_*` for now to minimize diff size
- **Configuration:** `V0_FEATURE_BRANCH` variable name unchanged (internal detail)

### What NOT to change (to minimize scope)

- State machine states (`planned`, `queued`, `executing`, etc.) - unchanged
- Operation type identifiers in state files - unchanged
- `V0_FEATURE_BRANCH` config variable - unchanged (internal)
- Internal function names - unchanged
- Git branch naming patterns - unchanged

## Verification Plan

### Per-Phase Verification

After each phase:
1. `make lint` - All files pass shellcheck
2. `make test` - All unit tests pass
3. Smoke test: `v0 build --help`, `v0 feature --help`

### Final Verification

1. **Full test suite:** `make check`
2. **Backward compatibility:**
   - `v0 feature auth "test" --dry-run` works
   - `v0 feat auth "test" --dry-run` works
   - `v0 resume` still works (calls v0-build --resume)
3. **New command:**
   - `v0 build auth "test" --dry-run` works
   - `v0 --help` shows "build" as primary
4. **Documentation:**
   - README shows "build" examples
   - `v0 build --help` shows "build" usage

### Test Commands

```bash
# Lint and test
make check

# Verify help text
v0 --help | grep build
v0 build --help

# Verify backward compat
v0 feature --help
v0 feat --help

# Dry run tests
v0 build test-rename "Test the rename" --dry-run
v0 feature test-rename "Test the rename" --dry-run
```
