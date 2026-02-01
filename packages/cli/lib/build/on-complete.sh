#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alfred Jean LLC
# On-complete script generation for feature operations
# Source this file to get on-complete script generation functions

# feature_create_on_complete <tree_dir> <state_file> <op_name> <v0_dir> <v0_root>
# Create the on-complete.sh script that runs when feature execution finishes
# Args:
#   $1 = tree directory (TREE_DIR)
#   $2 = state file path (STATE_FILE)
#   $3 = operation name (NAME)
#   $4 = v0 directory (V0_DIR)
#   $5 = v0 root (V0_ROOT)
feature_create_on_complete() {
  local tree_dir="$1"
  local state_file="$2"
  local op_name="$3"
  local v0_dir="$4"
  local v0_root="$5"

  mkdir -p "${tree_dir}/.claude"
  cat > "${tree_dir}/.claude/on-complete.sh" <<WRAPPER
#!/bin/bash
STATE_FILE="${state_file}"
BUILD_ROOT="${v0_root}"
OP_NAME="${op_name}"
V0_DIR="${v0_dir}"

# Safety net: Close any remaining open issues (handles bypassed stop hooks)
OPEN_IDS=\$(wk list --label "plan:\${OP_NAME}" --status todo 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+' || true)
IN_PROGRESS_IDS=\$(wk list --label "plan:\${OP_NAME}" --status in_progress 2>/dev/null | grep -oE '[a-zA-Z]+-[a-z0-9]+' || true)
ALL_OPEN_IDS="\${OPEN_IDS} \${IN_PROGRESS_IDS}"
ALL_OPEN_IDS=\$(echo "\${ALL_OPEN_IDS}" | xargs)  # Trim whitespace
if [[ -n "\${ALL_OPEN_IDS}" ]]; then
  echo "Closing remaining issues: \${ALL_OPEN_IDS}"
  read -ra IDS_ARRAY <<< "\${ALL_OPEN_IDS}"
  wk done "\${IDS_ARRAY[@]}" --reason "Auto-closed by on-complete handler" 2>/dev/null || true
fi

COMPLETED_JSON=\$(wk list --output json --label "plan:\${OP_NAME}" --status done 2>/dev/null | jq '[.[].id]' 2>/dev/null)
COMPLETED_JSON="\${COMPLETED_JSON:-[]}"
if [[ "\${COMPLETED_JSON}" != "[]" ]]; then
  tmp=\$(mktemp)
  jq ".completed = \${COMPLETED_JSON}" "\${STATE_FILE}" > "\${tmp}" && mv "\${tmp}" "\${STATE_FILE}"
fi

tmp=\$(mktemp)
jq '.phase = "completed" | .completed_at = "'\$(date -u +%Y-%m-%dT%H:%M:%SZ)'"' "\${STATE_FILE}" > "\${tmp}" && mv "\${tmp}" "\${STATE_FILE}"

if [[ "\$(jq -r '.merge_queued // false' "\${STATE_FILE}")" = "true" ]]; then
  echo "=== Merge queued, preparing for merge ==="
  tmp=\$(mktemp)
  jq '.phase = "pending_merge"' "\${STATE_FILE}" > "\${tmp}" && mv "\${tmp}" "\${STATE_FILE}"

  # Clear inherited MERGEQ_DIR/BUILD_DIR to prevent cross-project contamination
  # (tmux server may have inherited these from a different project)
  if unset MERGEQ_DIR BUILD_DIR; V0_ROOT="\${BUILD_ROOT}" "\${V0_DIR}/bin/v0-mergeq" --enqueue "\${OP_NAME}"; then
    echo "Operation '\${OP_NAME}' added to merge queue"
  else
    echo "Warning: Failed to enqueue for merge"
    echo "Run manually: v0 startup mergeq"
  fi
fi
WRAPPER
  chmod +x "${tree_dir}/.claude/on-complete.sh"
}

# feature_create_settings <tree_dir> <v0_dir>
# Create the settings.local.json file with hooks configuration
# Args:
#   $1 = tree directory (TREE_DIR)
#   $2 = v0 directory (V0_DIR)
feature_create_settings() {
  local tree_dir="$1"
  local v0_dir="$2"
  local hook_script="${v0_dir}/packages/hooks/lib/stop-feature.sh"

  mkdir -p "${tree_dir}/.claude"
  cat > "${tree_dir}/.claude/settings.local.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${hook_script}"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "wk prime"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "wk prime"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
}
