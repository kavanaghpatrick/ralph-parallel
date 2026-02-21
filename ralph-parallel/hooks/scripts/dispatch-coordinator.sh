#!/bin/bash
# Ralph Parallel - Dispatch Coordinator Stop Hook
#
# Prevents Claude from stopping while actively coordinating a parallel dispatch.
# Re-injects coordination context after context compaction.
#
# Exit codes:
#   0 = allow stop (no active dispatch or all complete)
#   2 = block stop + send coordination prompt via stderr
#
# Input (JSON on stdin):
#   stop_hook_active, last_assistant_message, session_id, cwd

set -euo pipefail

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

# Determine project root
if [ -n "$CWD" ]; then
  PROJECT_ROOT="$CWD"
else
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi

# Only enforce for team leads (not teammates)
AGENT_NAME="${CLAUDE_CODE_AGENT_NAME:-}"
if [ -n "$AGENT_NAME" ]; then
  # This is a teammate, not the lead — allow stop
  exit 0
fi

# Check if we're in an active team
TEAM_NAME="${CLAUDE_CODE_TEAM_NAME:-}"
if [ -z "$TEAM_NAME" ]; then
  # No team active — allow stop
  exit 0
fi

# Derive spec name from team name
SPEC_NAME="${TEAM_NAME%-parallel}"
SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"

if [ ! -f "$DISPATCH_STATE" ]; then
  exit 0
fi

STATUS=$(jq -r '.status // "unknown"' "$DISPATCH_STATE" 2>/dev/null) || exit 0

if [ "$STATUS" != "dispatched" ]; then
  # Not actively dispatched — allow stop
  exit 0
fi

# Active dispatch — check completion
TOTAL_GROUPS=$(jq '.groups | length' "$DISPATCH_STATE" 2>/dev/null) || exit 0
COMPLETED_GROUPS=$(jq '.completedGroups | length' "$DISPATCH_STATE" 2>/dev/null) || COMPLETED_GROUPS=0
SERIAL_COUNT=$(jq '.serialTasks | length' "$DISPATCH_STATE" 2>/dev/null) || SERIAL_COUNT=0
VERIFY_COUNT=$(jq '.verifyTasks | length' "$DISPATCH_STATE" 2>/dev/null) || VERIFY_COUNT=0

if [ "$COMPLETED_GROUPS" -ge "$TOTAL_GROUPS" ] 2>/dev/null; then
  # All groups complete — check if serial/verify tasks remain
  # Read tasks.md to check for incomplete tasks
  TASKS_MD="$SPEC_DIR/tasks.md"
  if [ -f "$TASKS_MD" ]; then
    INCOMPLETE=$(grep -c '^\- \[ \]' "$TASKS_MD" 2>/dev/null) || INCOMPLETE=0
    if [ "$INCOMPLETE" -eq 0 ]; then
      # Everything done — allow stop, but remind to cleanup
      echo "All tasks complete. Remember to update dispatch state to 'merged' and run TeamDelete." >&2
      exit 0
    fi
  else
    exit 0
  fi
fi

# Active dispatch with incomplete work — block stop
GROUP_NAMES=$(jq -r '[.groups[].name] | join(", ")' "$DISPATCH_STATE" 2>/dev/null) || GROUP_NAMES="unknown"
COMPLETED_LIST=$(jq -r '(.completedGroups // []) | join(", ")' "$DISPATCH_STATE" 2>/dev/null) || COMPLETED_LIST="none"

cat >&2 <<PROMPT
You are coordinating a parallel dispatch for spec '$SPEC_NAME'.

STATUS: $COMPLETED_GROUPS/$TOTAL_GROUPS groups complete
Groups: $GROUP_NAMES
Completed: $COMPLETED_LIST

NEXT ACTIONS:
1. Check TaskList for teammate progress
2. If waiting for teammates: they may be idle — check and send status messages
3. When all Phase 1 tasks done: run the verify checkpoint yourself
4. When all tasks done: update dispatch-state.json status to "merged", shut down teammates, TeamDelete

Do NOT stop until all tasks are complete and the team is cleaned up.
PROMPT

exit 2
