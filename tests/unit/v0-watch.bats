#!/usr/bin/env bats
# Tests for v0-watch - Continuously watch v0 status output
load '../helpers/test_helper'

# Helper to create an isolated project directory
setup_isolated_project() {
    local isolated_dir="$TEST_TEMP_DIR/isolated"
    mkdir -p "$isolated_dir/project/.v0/build/operations"
    cat > "$isolated_dir/project/.v0.rc" <<EOF
PROJECT="myproject"
ISSUE_PREFIX="mp"
EOF
    echo "$isolated_dir/project"
}

# ============================================================================
# Usage and help tests
# ============================================================================

@test "watch shows usage with --help" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --help
    '
    assert_success
    assert_output --partial "Usage: v0 watch"
    assert_output --partial "--interval"
}

@test "watch shows usage with -h" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" -h
    '
    assert_success
    assert_output --partial "Usage: v0 watch"
}

@test "watch help shows operation argument" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --help
    '
    assert_success
    assert_output --partial "OPERATION"
    assert_output --partial "Watch a specific operation by name"
}

@test "watch help shows filter options" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --help
    '
    assert_success
    assert_output --partial "--fix"
    assert_output --partial "--chore"
    assert_output --partial "--merge"
}

# ============================================================================
# Interval validation tests
# ============================================================================

@test "watch validates interval is positive" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --interval 0
    '
    assert_failure
    assert_output --partial "positive integer"
}

@test "watch validates interval is numeric" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --interval abc
    '
    assert_failure
    assert_output --partial "positive integer"
}

@test "watch validates negative interval" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --interval -5
    '
    assert_failure
    assert_output --partial "positive integer"
}

@test "watch rejects unknown options" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --unknown
    '
    assert_failure
    assert_output --partial "Unknown option"
}

# ============================================================================
# Argument parsing tests
# ============================================================================

@test "watch accepts --fix filter" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Use --max-iterations to prevent infinite loop, check it starts successfully
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --fix --max-iterations 1 2>&1 || true
    '
    # Should not show usage error for valid options
    refute_output --partial "Unknown option"
}

@test "watch accepts --chore filter" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --chore --max-iterations 1 2>&1 || true
    '
    refute_output --partial "Unknown option"
}

@test "watch accepts --merge filter" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --merge --max-iterations 1 2>&1 || true
    '
    refute_output --partial "Unknown option"
}

@test "watch accepts custom interval with -n" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" -n 2 --max-iterations 1 2>&1 || true
    '
    refute_output --partial "positive integer"
    refute_output --partial "Unknown option"
}

@test "watch accepts operation name as positional argument" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" my-feature --max-iterations 1 2>&1 || true
    '
    refute_output --partial "Unknown option"
}

@test "watch accepts operation name with -o flag" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" -o my-feature --max-iterations 1 2>&1 || true
    '
    refute_output --partial "Unknown option"
}

# ============================================================================
# Integration with main v0 command
# ============================================================================

@test "v0 watch command is routed correctly" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0" watch --help
    '
    assert_success
    assert_output --partial "Usage: v0 watch"
}

@test "v0 --help shows watch command" {
    run "$PROJECT_ROOT/bin/v0" --help
    assert_success
    assert_output --partial "watch"
    assert_output --partial "Continuously watch status"
}

@test "watch header shows project name" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 || true
    '
    # Header should show the project directory name
    assert_output --partial "Project: project/"
}

# ============================================================================
# Header bar width tests
# ============================================================================

@test "watch header bar contains box-drawing characters" {
    local project_dir
    project_dir=$(setup_isolated_project)

    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT bash -c '
        cd "'"$project_dir"'"
        "'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 || true
    '
    # Header bar should contain horizontal box-drawing character
    assert_output --partial "─"
}

@test "watch header bar respects COLUMNS env variable" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Test with a specific width
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT COLUMNS=40 bash -c '
        cd "'"$project_dir"'"
        output=$("'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 || true)
        # Extract the bar line (second line after header)
        bar=$(echo "$output" | grep -E "^─+$" | head -1)
        # Count characters (using wc -m for UTF-8)
        char_count=$(printf "%s" "$bar" | wc -m | tr -d " ")
        echo "bar_length=$char_count"
    '
    assert_output --partial "bar_length=40"
}

@test "watch header bar defaults to 80 with zero COLUMNS" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Test with COLUMNS=0, which should fall back to 80
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT COLUMNS=0 bash -c '
        cd "'"$project_dir"'"
        output=$("'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 || true)
        # Extract the bar line
        bar=$(echo "$output" | grep -E "^─+$" | head -1)
        # Count characters
        char_count=$(printf "%s" "$bar" | wc -m | tr -d " ")
        echo "bar_length=$char_count"
    '
    assert_output --partial "bar_length=80"
}

@test "watch header bar handles invalid COLUMNS gracefully" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Test with invalid COLUMNS value
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT COLUMNS="invalid" bash -c '
        cd "'"$project_dir"'"
        output=$("'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 || true)
        # Extract the bar line
        bar=$(echo "$output" | grep -E "^─+$" | head -1)
        # Count characters - should fall back to 80
        char_count=$(printf "%s" "$bar" | wc -m | tr -d " ")
        echo "bar_length=$char_count"
    '
    assert_output --partial "bar_length=80"
}

@test "watch header bar uses stty/tput fallback when COLUMNS unset" {
    local project_dir
    project_dir=$(setup_isolated_project)

    # Unset COLUMNS entirely - should fall back to stty/tput or 80
    run env -u PROJECT -u ISSUE_PREFIX -u V0_ROOT -u COLUMNS bash -c '
        cd "'"$project_dir"'"
        output=$("'"$PROJECT_ROOT"'/bin/v0-watch" --max-iterations 1 2>&1 || true)
        # Extract the bar line
        bar=$(echo "$output" | grep -E "^─+$" | head -1)
        # Count characters - should be a positive integer (stty/tput result or 80 fallback)
        char_count=$(printf "%s" "$bar" | wc -m | tr -d " ")
        if [[ "$char_count" -ge 1 ]]; then
            echo "bar_length_valid=true"
            echo "bar_length=$char_count"
        else
            echo "bar_length_valid=false"
        fi
    '
    assert_output --partial "bar_length_valid=true"
}
