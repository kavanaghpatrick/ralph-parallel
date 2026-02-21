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
# With 1:1 TaskList-to-spec-task mapping, the subject starts with "X.Y: description".
# Extract the spec task ID directly from the beginning of TASK_SUBJECT.
COMPLETED_SPEC_TASK=""

if [ -n "$TASK_SUBJECT" ]; then
  COMPLETED_SPEC_TASK=$(echo "$TASK_SUBJECT" | grep -oE '^[0-9]+\.[0-9]+')
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
