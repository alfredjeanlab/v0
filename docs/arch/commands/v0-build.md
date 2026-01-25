# v0-build

**Purpose:** Full autonomous build pipeline.

See [operations/state.md](../operations/state.md) for state machine, phases, and state file schema.

## Usage

```bash
v0 build auth "Add JWT authentication"       # Full pipeline
v0 build auth --plan plans/auth.md           # With existing plan
v0 build auth "Add JWT auth" --enqueue       # Plan + decompose only
v0 build auth --resume                       # Resume from current phase
v0 build auth "Add JWT auth" --foreground    # Run blocking
v0 build api "Build API" --after auth        # Chain operations
```

## Options

| Flag | Description |
|------|-------------|
| `--plan <file>` | Use existing plan file |
| `--enqueue` | Plan + decompose only, don't execute |
| `--resume` | Continue from current phase |
| `--foreground` | Run blocking instead of background |
| `--after <name>` | Wait for another operation to complete first |
| `--eager` | With `--after`: plan immediately, execute after |

## Hooks

- **Stop**: Completion detection (`stop-build.sh`)
- **PostToolUse (Bash)**: Progress notification
- **PreCompact/SessionStart**: Run `v0 prime`

## Logs (v0-build-worker)

- `.v0/build/operations/<name>/logs/worker.log`
- `.v0/build/operations/<name>/logs/events.log`
- `.v0/build/operations/<name>/logs/build.log`
