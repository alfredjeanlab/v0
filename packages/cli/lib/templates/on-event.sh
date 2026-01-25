#!/bin/bash
# on-event.sh - Optional notification hook for v0 events
# Called by v0 status/mergeq when significant events occur
#
# Usage: echo '{"event":"operation:complete",...}' | on-event.sh
#
# Event types:
#   plan:created      - Implementation plan generated
#   work:queued       - Issues created in wk
#   issue:claimed     - Worker started an issue
#   issue:completed   - Worker finished an issue
#   operation:complete - All issues resolved
#   merge:queued      - Operation added to merge queue
#   merge:started     - Merge in progress
#   merge:completed   - Merge successful
#   merge:conflict    - Merge has conflicts (needs resolution)
#   merge:failed      - Merge failed

EVENT=$(cat)
EVENT_TYPE=$(echo "$EVENT" | jq -r '.event // empty')
OP_NAME=$(echo "$EVENT" | jq -r '.operation // empty')

[ -z "$EVENT_TYPE" ] && exit 0

# Helper: send notification (skip in test mode)
# Uses PROJECT env var in title when available
notify() {
  local title_suffix="$1"
  local message="$2"
  local title="${PROJECT:-v0}"
  [ -n "$title_suffix" ] && title="$title $title_suffix"
  if [ "${V0_TEST_MODE:-}" != "1" ] && command -v osascript &> /dev/null; then
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
  fi
}

case "$EVENT_TYPE" in
  operation:complete)
    notify "" "$OP_NAME completed successfully"
    ;;

  plan:created)
    notify "" "Plan created: $OP_NAME"
    ;;

  work:queued)
    ISSUE_COUNT=$(echo "$EVENT" | jq -r '.data.issue_count // "unknown"')
    notify "" "$ISSUE_COUNT issues queued for $OP_NAME"
    ;;

  merge:queued)
    notify "Merge" "$OP_NAME queued for merge"
    ;;

  merge:started)
    notify "Merge" "Merging $OP_NAME..."
    ;;

  merge:completed)
    notify "Merge" "$OP_NAME merged successfully"
    ;;

  merge:conflict)
    notify "Merge" "$OP_NAME has merge conflicts"
    ;;

  merge:failed)
    notify "Merge" "$OP_NAME merge failed"
    ;;
esac

exit 0
