# Packages

Modular shell library packages with explicit dependencies.

## Package Layers

Packages are organized in dependency layers.
A package may only source from packages in lower layers.

```
Layer 0: core              # Foundation (no dependencies)
Layer 1: state, mergeq     # State machine, merge queue
Layer 2: merge, worker     # Operations that use state/mergeq
Layer 3: feature, hooks, status  # High-level features
Layer 4: cli               # Entry point, sources all
```

## Sourcing Invariants

1. **No circular dependencies** - Packages cannot source from packages that depend on them
2. **Explicit dependencies** - Each package.sh declares PKG_DEPS
3. **Single entry point** - cli/lib/v0-common.sh is the main entry point for bin/ scripts
4. **Relative paths** - Use `${V0_INSTALL_DIR}/packages/*/lib/` for cross-package sourcing

## Package Structure

```
packages/<name>/
  lib/           # Shell library files (.sh)
  tests/         # Unit tests (.bats)
  package.sh     # Manifest: PKG_NAME, PKG_DEPS, PKG_EXPORTS
```

## Unit Tests

Unit tests live in `packages/<name>/tests/` and test the package's lib functions in isolation.

- Load test helper: `load '../packages/test-support/helpers/test_helper'`
- Source libs via helper: `source_lib "state-machine.sh"`
- Mock external commands, don't call real bin/ scripts
- Tests are cached per-package; changing any lib/ file invalidates the package cache

## Adding a Package

1. Create `packages/<name>/package.sh`:
   ```bash
   PKG_NAME="mypackage"
   PKG_DEPS=(core state)  # Lower-layer dependencies
   PKG_EXPORTS=(lib/main.sh)
   ```
2. Add lib files to `packages/<name>/lib/`
3. Add tests to `packages/<name>/tests/`
4. Update dependent packages if needed
