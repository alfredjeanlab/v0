# Integration Tests

Command-level tests that exercise bin/ scripts end-to-end.

## Structure

Each `.bats` file tests a corresponding bin/ command:
- `v0-cancel.bats` tests `bin/v0-cancel`
- `v0-merge.bats` tests `bin/v0-merge`
- etc.

## Writing Tests

```bash
#!/usr/bin/env bats
load '../packages/test-support/helpers/test_helper'

setup() {
    _base_setup
    setup_v0_env
}

@test "v0-foo does something" {
    run "$PROJECT_ROOT/bin/v0-foo" --arg
    assert_success
    assert_output --partial "expected"
}
```

## Test Isolation

All tests MUST:
- Use `$TEST_TEMP_DIR` for all file operations
- Set `V0_TEST_MODE=1` to suppress notifications
- Clean up in teardown
- Not modify the real project directory

## Caching

Integration tests are cached individually:
- Hash includes: test file + matching bin/ script + all package libs
- Changing a bin/ script invalidates only that test's cache
- Changing any package lib invalidates all integration tests

## Running Tests

```bash
scripts/test v0-cancel          # Run single test
scripts/test v0-cancel v0-merge # Run multiple tests
scripts/test                    # Run all (packages + integration)
scripts/test --bust v0-cancel   # Clear cache for specific test
```
