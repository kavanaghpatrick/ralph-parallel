#!/bin/bash
# Ralph Parallel - Task Completed Quality Gate
#
# Registered as a TaskCompleted hook (no matchers supported).
# Reads the completed task info and runs the verify command from tasks.md.
#
# Exit codes:
#   0 = allow (task passes quality gate)
#   2 = block + send stderr as feedback to teammate
#
# Input (JSON on stdin):
#   task_id, task_subject, task_description, teammate_name, team_name
#   Plus common fields: session_id, cwd, permission_mode, hook_event_name

set -euo pipefail

# Read input from stdin
INPUT=$(cat)

# Parse fields using jq (matches documented TaskCompleted schema)
TASK_ID=$(echo "$INPUT" | jq -r '.task_id // empty' 2>/dev/null) || TASK_ID=""
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // empty' 2>/dev/null) || TASK_SUBJECT=""
TASK_DESCRIPTION=$(echo "$INPUT" | jq -r '.task_description // empty' 2>/dev/null) || TASK_DESCRIPTION=""
TEAM_NAME=$(echo "$INPUT" | jq -r '.team_name // empty' 2>/dev/null) || TEAM_NAME=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

if [ -z "$TASK_ID" ]; then
  # No task ID — can't verify, allow through
  exit 0
fi

# Determine project root
if [ -n "$CWD" ]; then
  PROJECT_ROOT="$CWD"
else
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi

# --- Spec Resolution ---
# Priority 1: team_name (e.g., "user-auth-parallel" → "user-auth")
# Priority 2: .current-spec file
# Priority 3: first dispatched spec (last resort)
SPEC_DIR=""

if [ -n "$TEAM_NAME" ]; then
  SPEC_NAME="${TEAM_NAME%-parallel}"
  if [ -d "$PROJECT_ROOT/specs/$SPEC_NAME" ]; then
    SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
  fi
fi

if [ -z "$SPEC_DIR" ] && [ -f "$PROJECT_ROOT/specs/.current-spec" ]; then
  SPEC_NAME=$(tr -d '[:space:]' < "$PROJECT_ROOT/specs/.current-spec")
  if [ -n "$SPEC_NAME" ] && [ -d "$PROJECT_ROOT/specs/$SPEC_NAME" ]; then
    SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
  fi
fi

if [ -z "$SPEC_DIR" ]; then
  for state_file in "$PROJECT_ROOT"/specs/*/.dispatch-state.json; do
    [ -f "$state_file" ] || continue
    STATUS=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || continue
    if [ "$STATUS" = "dispatched" ]; then
      SPEC_DIR=$(dirname "$state_file")
      break
    fi
  done
fi

if [ -z "$SPEC_DIR" ] || [ ! -f "$SPEC_DIR/tasks.md" ]; then
  # No matching dispatch or no tasks.md — allow through
  exit 0
fi

# --- Determine which spec task was just completed ---
# Strategy: Look up the TaskList task_id in the dispatch state to find its spec task IDs.
# The dispatch state maps group tasks to spec task IDs.
# We find which group this task belongs to by checking task_subject or task_description
# for spec task ID patterns (X.Y format).

DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"
COMPLETED_SPEC_TASK=""

if [ -f "$DISPATCH_STATE" ]; then
  # Extract the LAST spec task ID mentioned in the subject — this is the task just completed
  # Task subjects like "Group 1: data-models (tasks 1.1, 1.2)" contain all group tasks,
  # but task_description often has the specific task being completed.
  # Best approach: check description first, then subject
  if [ -n "$TASK_DESCRIPTION" ]; then
    COMPLETED_SPEC_TASK=$(echo "$TASK_DESCRIPTION" | grep -oE '[0-9]+\.[0-9]+' | tail -1)
  fi
  if [ -z "$COMPLETED_SPEC_TASK" ] && [ -n "$TASK_SUBJECT" ]; then
    # If subject has only one task ID, use it; otherwise allow through
    TASK_IDS_IN_SUBJECT=$(echo "$TASK_SUBJECT" | grep -oE '[0-9]+\.[0-9]+' | sort -u)
    TASK_COUNT=$(echo "$TASK_IDS_IN_SUBJECT" | wc -l | tr -d ' ')
    if [ "$TASK_COUNT" = "1" ]; then
      COMPLETED_SPEC_TASK="$TASK_IDS_IN_SUBJECT"
    fi
  fi
fi

if [ -z "$COMPLETED_SPEC_TASK" ]; then
  # Can't determine specific task — allow through rather than block
  exit 0
fi

# --- Extract verify command for this SINGLE task from tasks.md ---
VERIFY_CMD=""
IN_TASK=false

while IFS= read -r line; do
  if echo "$line" | grep -qE "^\s*- \[.\] ${COMPLETED_SPEC_TASK}\b"; then
    IN_TASK=true
    continue
  fi

  if [ "$IN_TASK" = true ] && echo "$line" | grep -qE "^\s*- \[.\] [0-9]"; then
    break
  fi

  if [ "$IN_TASK" = true ] && echo "$line" | grep -qE "\*\*Verify\*\*:"; then
    VERIFY_CMD=$(echo "$line" | sed 's/.*\*\*Verify\*\*:\s*//' | sed 's/`//g')
    break
  fi
done < "$SPEC_DIR/tasks.md"

if [ -z "$VERIFY_CMD" ]; then
  # No verify command found — allow through
  exit 0
fi

# Run the verify command from project root
cd "$PROJECT_ROOT"
echo "ralph-parallel: Verifying task $COMPLETED_SPEC_TASK: $VERIFY_CMD" >&2

if eval "$VERIFY_CMD" >/dev/null 2>&1; then
  # Verification passed
  exit 0
else
  # Verification failed — block task completion with feedback via stderr
  echo "QUALITY GATE FAILED for task $COMPLETED_SPEC_TASK ($TASK_SUBJECT)" >&2
  echo "Verify command failed: $VERIFY_CMD" >&2
  echo "Fix the issues and mark the task complete again." >&2
  exit 2
fi
