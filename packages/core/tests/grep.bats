#!/usr/bin/env bats
# Tests for grep.sh - Grep wrapper functions

load '../../test-support/helpers/test_helper'

# ============================================================================
# Setup/Teardown
# ============================================================================

setup() {
    _base_setup
    source_lib "grep.sh"
}

# ============================================================================
# _v0_init_grep() tests
# ============================================================================

@test "_v0_init_grep sets rg when available" {
    # Re-initialize to test detection
    _v0_init_grep

    # If rg is installed, should use rg; otherwise grep
    if command -v rg >/dev/null 2>&1; then
        [[ "$_V0_GREP_CMD" == "rg" ]]
    else
        [[ "$_V0_GREP_CMD" == "grep" ]]
    fi
}

@test "_v0_init_grep falls back to grep when rg unavailable" {
    # Create a temporary directory with only grep (no rg)
    local fake_bin
    fake_bin=$(mktemp -d)
    ln -s "$(command -v grep)" "${fake_bin}/grep"

    # Use only our fake bin directory
    local saved_path="$PATH"
    PATH="${fake_bin}"

    _v0_init_grep
    [[ "$_V0_GREP_CMD" == "grep" ]]

    PATH="$saved_path"
    rm -rf "${fake_bin}"
}

# ============================================================================
# v0_grep_quiet() tests
# ============================================================================

@test "v0_grep_quiet returns 0 on match" {
    echo "hello world" | v0_grep_quiet "hello"
}

@test "v0_grep_quiet returns 1 on no match" {
    run v0_grep_quiet "goodbye" <<< "hello"
    [[ "$status" -eq 1 ]]
}

@test "v0_grep_quiet works with files" {
    echo "test content" > "$TEST_TEMP_DIR/file.txt"

    v0_grep_quiet "content" "$TEST_TEMP_DIR/file.txt"
    run v0_grep_quiet "missing" "$TEST_TEMP_DIR/file.txt"
    [[ "$status" -eq 1 ]]
}

# ============================================================================
# v0_grep_extract() tests
# ============================================================================

@test "v0_grep_extract extracts pattern from input" {
    result=$(echo "issue-abc123" | v0_grep_extract '[a-z]+-[a-z0-9]+')
    [[ "$result" == "issue-abc123" ]]
}

@test "v0_grep_extract extracts multiple matches" {
    result=$(printf "foo-123\nbar-456\n" | v0_grep_extract '[a-z]+-[0-9]+')
    [[ $(echo "$result" | wc -l) -eq 2 ]]
}

@test "v0_grep_extract works with files" {
    echo "version: 1.2.3" > "$TEST_TEMP_DIR/file.txt"

    result=$(v0_grep_extract '[0-9]+\.[0-9]+\.[0-9]+' "$TEST_TEMP_DIR/file.txt")
    [[ "$result" == "1.2.3" ]]
}

@test "v0_grep_extract returns nothing on no match" {
    result=$(echo "no match here" | v0_grep_extract '[0-9]{10}' || true)
    [[ -z "$result" ]]
}

# ============================================================================
# v0_grep_count() tests
# ============================================================================

@test "v0_grep_count counts matches" {
    result=$(printf "a\na\nb\n" | v0_grep_count "a")
    [[ "$result" == "2" ]]
}

@test "v0_grep_count returns 0 for no matches" {
    result=$(echo "hello" | v0_grep_count "goodbye")
    [[ "$result" == "0" ]]
}

@test "v0_grep_count works with files" {
    printf "line1\nline2\nline3\n" > "$TEST_TEMP_DIR/file.txt"

    result=$(v0_grep_count "line" "$TEST_TEMP_DIR/file.txt")
    [[ "$result" == "3" ]]
}

# ============================================================================
# v0_grep_invert() tests
# ============================================================================

@test "v0_grep_invert returns non-matching lines" {
    result=$(printf "apple\nbanana\napricot\n" | v0_grep_invert "banana")
    [[ "$result" == $'apple\napricot' ]]
}

@test "v0_grep_invert works with files" {
    printf "keep\nremove\nkeep\n" > "$TEST_TEMP_DIR/file.txt"

    result=$(v0_grep_invert "remove" "$TEST_TEMP_DIR/file.txt")
    [[ $(echo "$result" | wc -l) -eq 2 ]]
}

@test "v0_grep_invert excludes empty lines" {
    result=$(printf "a\n\nb\n" | v0_grep_invert '^$')
    [[ $(echo "$result" | wc -l | tr -d ' ') -eq 2 ]]
}

# ============================================================================
# v0_grep_first() tests
# ============================================================================

@test "v0_grep_first returns only first match" {
    result=$(printf "match1\nmatch2\nmatch3\n" | v0_grep_first "match")
    [[ "$result" == "match1" ]]
}

@test "v0_grep_first works with files" {
    printf "first\nsecond\nthird\n" > "$TEST_TEMP_DIR/file.txt"

    result=$(v0_grep_first "." "$TEST_TEMP_DIR/file.txt")
    [[ "$result" == "first" ]]
}

# ============================================================================
# v0_grep_fixed() tests
# ============================================================================

@test "v0_grep_fixed matches literal strings" {
    result=$(echo "hello.world" | v0_grep_fixed ".")
    [[ "$result" == "hello.world" ]]
}

@test "v0_grep_fixed does not interpret regex" {
    # ".*" as regex would match everything, but as fixed string it shouldn't match "hello"
    run v0_grep_fixed ".*" <<< "hello"
    [[ "$status" -eq 1 ]]
}

@test "v0_grep_fixed works with files" {
    echo "test[123]end" > "$TEST_TEMP_DIR/file.txt"

    result=$(v0_grep_fixed "[123]" "$TEST_TEMP_DIR/file.txt")
    [[ "$result" == "test[123]end" ]]
}

# ============================================================================
# v0_grep_fixed_quiet() tests
# ============================================================================

@test "v0_grep_fixed_quiet matches literal strings" {
    echo "test.file" | v0_grep_fixed_quiet "test.file"
}

@test "v0_grep_fixed_quiet does not interpret regex" {
    # The . in regex would match any char, but -F should match literally
    run bash -c "source '$PROJECT_ROOT/packages/core/lib/grep.sh' && echo 'testXfile' | v0_grep_fixed_quiet 'test.file'"
    [[ "$status" -eq 1 ]]
}

# ============================================================================
# v0_grep() general tests
# ============================================================================

@test "v0_grep basic pattern matching" {
    result=$(echo "hello world" | v0_grep "world")
    [[ "$result" == "hello world" ]]
}

@test "v0_grep with -q option" {
    v0_grep -q "test" <<< "test"
    run v0_grep -q "missing" <<< "test"
    [[ "$status" -eq 1 ]]
}

@test "v0_grep with -v option" {
    result=$(printf "a\nb\nc\n" | v0_grep -v "b")
    [[ "$result" == $'a\nc' ]]
}

@test "v0_grep with -c option" {
    result=$(printf "x\nx\ny\n" | v0_grep -c "x")
    [[ "$result" == "2" ]]
}

@test "v0_grep with -o option" {
    result=$(echo "abc123def" | v0_grep -o "[0-9]+")
    [[ "$result" == "123" ]]
}

@test "v0_grep with -oE combined option" {
    result=$(echo "hello123world" | v0_grep -oE '[0-9]+')
    [[ "$result" == "123" ]]
}

@test "v0_grep with -qE combined option" {
    echo "hello123" | v0_grep -qE '[0-9]+'
}

@test "v0_grep with -qF combined option" {
    echo "test.txt" | v0_grep -qF "test.txt"
}

@test "v0_grep with -m1 option" {
    result=$(printf "a\na\na\n" | v0_grep -m1 "a")
    [[ "$result" == "a" ]]
    [[ $(echo "$result" | wc -l | tr -d ' ') -eq 1 ]]
}

@test "v0_grep with file argument" {
    echo "test line" > "$TEST_TEMP_DIR/file.txt"

    result=$(v0_grep "test" "$TEST_TEMP_DIR/file.txt")
    [[ "$result" == "test line" ]]
}

# ============================================================================
# Edge Cases
# ============================================================================

@test "v0_grep handles empty input" {
    result=$(echo "" | v0_grep "pattern" || true)
    [[ -z "$result" ]]
}

@test "v0_grep handles special characters in pattern" {
    echo "test^$pattern" | v0_grep -F "test^$pattern"
}

# ============================================================================
# Consistency tests (rg vs grep produce same results)
# ============================================================================

@test "wrapper functions work regardless of backend" {
    # These tests verify the wrappers produce consistent results
    # regardless of whether rg or grep is used

    echo "line one" > "$TEST_TEMP_DIR/test.txt"
    echo "line two" >> "$TEST_TEMP_DIR/test.txt"
    echo "other" >> "$TEST_TEMP_DIR/test.txt"

    # Count test
    local count
    count=$(v0_grep_count "line" "$TEST_TEMP_DIR/test.txt")
    [[ "$count" == "2" ]]

    # Quiet test
    v0_grep_quiet "line" "$TEST_TEMP_DIR/test.txt"
    run v0_grep_quiet "missing" "$TEST_TEMP_DIR/test.txt"
    [[ "$status" -eq 1 ]]

    # Invert test
    local inverted
    inverted=$(v0_grep_invert "line" "$TEST_TEMP_DIR/test.txt")
    [[ "$inverted" == "other" ]]
}

@test "v0_grep with piped input produces same results as grep" {
    input="line1
line2
line3"
    grep_result=$(echo "$input" | grep "line" | wc -l | tr -d ' ')
    v0_result=$(echo "$input" | v0_grep "line" | wc -l | tr -d ' ')
    [[ "$grep_result" == "$v0_result" ]]
}
