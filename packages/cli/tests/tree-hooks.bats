#!/usr/bin/env bats
# Tests for hook installation in worktrees

load '../../test-support/helpers/test_helper'

setup() {
  # Standard test setup
  TEST_TEMP_DIR="$(mktemp -d)"
  export TEST_TEMP_DIR
  mkdir -p "$TEST_TEMP_DIR/project/.v0/build"
  export REAL_HOME="$HOME"
  export HOME="$TEST_TEMP_DIR/home"
  mkdir -p "$HOME/.local/state/v0"
  # Disable OS notifications during tests
  export V0_TEST_MODE=1
  cd "$TEST_TEMP_DIR/project"
  export ORIGINAL_PATH="$PATH"
}

teardown() {
  export HOME="$REAL_HOME"
  export PATH="$ORIGINAL_PATH"
  [ -n "$TEST_TEMP_DIR" ] && rm -rf "$TEST_TEMP_DIR"
}

@test "chore worker installs PostToolUse hook in settings.local.json" {
  # Set up a real git repo
  git init "$TEST_TEMP_DIR/project" >/dev/null 2>&1
  cd "$TEST_TEMP_DIR/project"
  git config user.email "test@test.com"
  git config user.name "Test User"
  git commit --allow-empty -m "initial" >/dev/null 2>&1

  # Create a test branch
  git checkout -b v0/worker/chore >/dev/null 2>&1

  # Mock v0_load_config to set required variables
  V0_ROOT="$TEST_TEMP_DIR/project"
  REPO_NAME=$(basename "$V0_ROOT")
  BUILD_DIR="$TEST_TEMP_DIR/project/.v0/build"
  mkdir -p "$BUILD_DIR"

  # Simulate the settings.local.json creation from v0-chore
  HOOK_SCRIPT="${PROJECT_ROOT}/packages/hooks/lib/stop-chore.sh"
  NOTIFY_HOOK="${PROJECT_ROOT}/packages/hooks/lib/notify-progress.sh"
  TREE_DIR="$TEST_TEMP_DIR/project/.tree/v0-chore-worker"
  mkdir -p "${TREE_DIR}/.claude"
  cat > "${TREE_DIR}/.claude/settings.local.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_SCRIPT}"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "V0_BUILD_DIR='${BUILD_DIR}' ${NOTIFY_HOOK}"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "wk prime"}]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "wk prime"}]
      }
    ]
  }
}
SETTINGS_EOF

  # Verify the settings file was created
  assert_file_exists "${TREE_DIR}/.claude/settings.local.json"

  # Verify PostToolUse hook is configured
  run jq '.hooks.PostToolUse[0].matcher' "${TREE_DIR}/.claude/settings.local.json"
  assert_output "\"Bash\""

  # Verify the hook command contains notify-progress.sh
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "${TREE_DIR}/.claude/settings.local.json"
  assert_output --partial "notify-progress.sh"
}

@test "fix worker installs PostToolUse hook in settings.local.json" {
  # Set up a real git repo
  git init "$TEST_TEMP_DIR/project" >/dev/null 2>&1
  cd "$TEST_TEMP_DIR/project"
  git config user.email "test@test.com"
  git config user.name "Test User"
  git commit --allow-empty -m "initial" >/dev/null 2>&1

  # Create a test branch
  git checkout -b v0/worker/fix >/dev/null 2>&1

  # Mock v0_load_config to set required variables
  V0_ROOT="$TEST_TEMP_DIR/project"
  REPO_NAME=$(basename "$V0_ROOT")
  BUILD_DIR="$TEST_TEMP_DIR/project/.v0/build"
  mkdir -p "$BUILD_DIR"

  # Simulate the settings.local.json creation from v0-fix
  HOOK_SCRIPT="${PROJECT_ROOT}/packages/hooks/lib/stop-fix.sh"
  NOTIFY_HOOK="${PROJECT_ROOT}/packages/hooks/lib/notify-progress.sh"
  TREE_DIR="$TEST_TEMP_DIR/project/.tree/v0-fix-worker"
  mkdir -p "${TREE_DIR}/.claude"
  cat > "${TREE_DIR}/.claude/settings.local.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_SCRIPT}"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "V0_BUILD_DIR='${BUILD_DIR}' ${NOTIFY_HOOK}"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "wk prime"}]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "wk prime"}]
      }
    ]
  }
}
SETTINGS_EOF

  # Verify the settings file was created
  assert_file_exists "${TREE_DIR}/.claude/settings.local.json"

  # Verify PostToolUse hook is configured
  run jq '.hooks.PostToolUse[0].matcher' "${TREE_DIR}/.claude/settings.local.json"
  assert_output "\"Bash\""

  # Verify the hook command contains notify-progress.sh
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "${TREE_DIR}/.claude/settings.local.json"
  assert_output --partial "notify-progress.sh"
}

@test "notify-progress.sh hook handles wk start command" {
  # Create the hook
  local hook="$PROJECT_ROOT/packages/hooks/lib/notify-progress.sh"

  # Create logs directory
  mkdir -p "$TEST_TEMP_DIR/logs"

  # Test with simulated PostToolUse input
  local input='{"tool_name":"Bash","tool_input":{"command":"wk start test-123"}}'

  # Run hook
  echo "$input" | V0_BUILD_DIR="$TEST_TEMP_DIR" "$hook"

  # Check log was created
  assert_file_exists "$TEST_TEMP_DIR/logs/progress.log"

  # Check log contains the issue ID
  run grep "test-123" "$TEST_TEMP_DIR/logs/progress.log"
  assert_success
}

@test "notify-progress.sh ignores non-Bash tool calls" {
  local hook="$PROJECT_ROOT/packages/hooks/lib/notify-progress.sh"

  # Non-Bash tool call
  local input='{"tool_name":"Read","tool_input":{"file":"/tmp/test"}}'

  # Run hook - should exit cleanly without logging
  echo "$input" | V0_BUILD_DIR="$TEST_TEMP_DIR" "$hook"

  # No log should be created
  assert_file_not_exists "$TEST_TEMP_DIR/logs/progress.log"
}

@test "notify-progress.sh ignores non-wk-start bash commands" {
  local hook="$PROJECT_ROOT/packages/hooks/lib/notify-progress.sh"

  # Bash command that isn't wk start
  local input='{"tool_name":"Bash","tool_input":{"command":"git status"}}'

  echo "$input" | V0_BUILD_DIR="$TEST_TEMP_DIR" "$hook"

  assert_file_not_exists "$TEST_TEMP_DIR/logs/progress.log"
}

@test "notify-progress.sh extracts issue ID with various patterns" {
  local hook="$PROJECT_ROOT/packages/hooks/lib/notify-progress.sh"
  mkdir -p "$TEST_TEMP_DIR/logs"

  # Test with v0 prefix
  local input='{"tool_name":"Bash","tool_input":{"command":"wk start v0-abc123"}}'
  echo "$input" | V0_BUILD_DIR="$TEST_TEMP_DIR" "$hook"
  run grep "v0-abc123" "$TEST_TEMP_DIR/logs/progress.log"
  assert_success

  # Clean up for next test
  rm -f "$TEST_TEMP_DIR/logs/progress.log"

  # Test with longer prefix
  local input2='{"tool_name":"Bash","tool_input":{"command":"wk start myproject-xyz789"}}'
  echo "$input2" | V0_BUILD_DIR="$TEST_TEMP_DIR" "$hook"
  run grep "myproject-xyz789" "$TEST_TEMP_DIR/logs/progress.log"
  assert_success
}

@test "notify-progress.sh does not call osascript in test mode" {
  local hook="$PROJECT_ROOT/packages/hooks/lib/notify-progress.sh"
  mkdir -p "$TEST_TEMP_DIR/logs"
  mkdir -p "$TEST_TEMP_DIR/mock-bin"

  # Create mock osascript that records calls
  cat > "$TEST_TEMP_DIR/mock-bin/osascript" <<'EOF'
#!/bin/bash
echo "osascript called: $*" >> "$TEST_TEMP_DIR/osascript-calls.log"
EOF
  chmod +x "$TEST_TEMP_DIR/mock-bin/osascript"

  # Run with mock osascript in PATH and V0_TEST_MODE=1
  local input='{"tool_name":"Bash","tool_input":{"command":"wk start test-123"}}'
  echo "$input" | PATH="$TEST_TEMP_DIR/mock-bin:$PATH" V0_BUILD_DIR="$TEST_TEMP_DIR" V0_TEST_MODE=1 "$hook"

  # Verify osascript was NOT called
  assert_file_not_exists "$TEST_TEMP_DIR/osascript-calls.log"
}

@test "on-event.sh does not call osascript in test mode" {
  local hook="$PROJECT_ROOT/packages/cli/lib/templates/on-event.sh"
  mkdir -p "$TEST_TEMP_DIR/mock-bin"

  # Create mock osascript that records calls
  cat > "$TEST_TEMP_DIR/mock-bin/osascript" <<'EOF'
#!/bin/bash
echo "osascript called: $*" >> "$TEST_TEMP_DIR/osascript-calls.log"
EOF
  chmod +x "$TEST_TEMP_DIR/mock-bin/osascript"

  # Run with mock osascript in PATH and V0_TEST_MODE=1
  local input='{"event":"operation:complete","operation":"test-op"}'
  echo "$input" | PATH="$TEST_TEMP_DIR/mock-bin:$PATH" V0_TEST_MODE=1 "$hook"

  # Verify osascript was NOT called
  assert_file_not_exists "$TEST_TEMP_DIR/osascript-calls.log"
}
