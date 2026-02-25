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
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

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

if [ -n "$TEAM_NAME" ]; then
  # Derive spec name from team name
  SPEC_NAME="${TEAM_NAME%-parallel}"
  SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
  DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"
else
  # No team context (session restart?) -- scan ALL active dispatches
  DISPATCH_STATE=""
  SPEC_NAME=""
  FOUND_ANY_ACTIVE=false
  FOUND_MY_DISPATCH=false

  for state_file in "$PROJECT_ROOT"/specs/*/.dispatch-state.json; do
    [ -f "$state_file" ] || continue
    FILE_STATUS=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null) || continue
    [ "$FILE_STATUS" = "dispatched" ] || continue

    FOUND_ANY_ACTIVE=true
    COORD_SID=$(jq -r '.coordinatorSessionId // empty' "$state_file" 2>/dev/null) || COORD_SID=""

    if [ -z "$COORD_SID" ]; then
      # Legacy dispatch (no coordinatorSessionId) -- block any session
      FOUND_MY_DISPATCH=true
      DISPATCH_STATE="$state_file"
      SPEC_NAME=$(basename "$(dirname "$state_file")")
      SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
      break
    elif [ -z "$SESSION_ID" ]; then
      # Empty session_id in input -- treat as legacy (block)
      FOUND_MY_DISPATCH=true
      DISPATCH_STATE="$state_file"
      SPEC_NAME=$(basename "$(dirname "$state_file")")
      SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
      break
    elif [ "$COORD_SID" = "$SESSION_ID" ]; then
      # This session owns this dispatch -- block
      FOUND_MY_DISPATCH=true
      DISPATCH_STATE="$state_file"
      SPEC_NAME=$(basename "$(dirname "$state_file")")
      SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
      break
    fi
    # Mismatch -- continue scanning other specs
  done

  if [ "$FOUND_MY_DISPATCH" = false ]; then
    # No active dispatch belongs to this session (or no active dispatches at all)
    exit 0
  fi
fi

if [ ! -f "$DISPATCH_STATE" ]; then
  exit 0
fi

STATUS=$(jq -r '.status // "unknown"' "$DISPATCH_STATE" 2>/dev/null) || exit 0

if [ "$STATUS" != "dispatched" ]; then
  # Not actively dispatched — allow stop
  exit 0
fi

# --- Session isolation (team-name branch) ---
if [ -n "$TEAM_NAME" ] && [ -f "$DISPATCH_STATE" ]; then
  COORD_SID=$(jq -r '.coordinatorSessionId // empty' "$DISPATCH_STATE" 2>/dev/null) || COORD_SID=""
  if [ -n "$COORD_SID" ] && [ -n "$SESSION_ID" ]; then
    if [ "$COORD_SID" != "$SESSION_ID" ]; then
      exit 0
    fi
  fi
  # Missing COORD_SID or empty SESSION_ID: legacy behavior (block)
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

# Check if team still exists
TEAM_CONFIG="$HOME/.claude/teams/${SPEC_NAME}-parallel/config.json"
TEAM_LOST=false
if [ ! -f "$TEAM_CONFIG" ]; then
  TEAM_LOST=true
else
  MEMBER_COUNT=$(jq '.members | length' "$TEAM_CONFIG" 2>/dev/null) || MEMBER_COUNT=0
  if [ "$MEMBER_COUNT" -eq 0 ]; then
    TEAM_LOST=true
  fi
fi

if [ "$TEAM_LOST" = true ]; then
  cat >&2 <<PROMPT
ACTIVE DISPATCH DETECTED — TEAMMATES LOST

Spec: $SPEC_NAME
Status: $COMPLETED_GROUPS/$TOTAL_GROUPS groups complete
Groups: $GROUP_NAMES
Completed: $COMPLETED_LIST

The team no longer exists but the dispatch is still active.
You MUST re-run /ralph-parallel:dispatch to re-spawn teammates.
Do NOT execute the remaining tasks yourself — that defeats parallel execution.

The dispatch command will detect the existing state and resume from where it left off.
PROMPT
else
  cat >&2 <<PROMPT
You are coordinating a parallel dispatch for spec '$SPEC_NAME'.

STATUS: $COMPLETED_GROUPS/$TOTAL_GROUPS groups complete
Groups: $GROUP_NAMES
Completed: $COMPLETED_LIST

NEXT ACTIONS:
1. Check TaskList for teammate progress
2. If waiting for teammates: they may be idle — check and send status messages
3. When all Phase N tasks done: run the verify checkpoint yourself
4. When all tasks done: update dispatch-state.json status to "merged", shut down teammates, TeamDelete

Do NOT stop until all tasks are complete and the team is cleaned up.
PROMPT
fi

exit 2
