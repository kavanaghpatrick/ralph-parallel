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

# Find the spec directory with active dispatch
SPEC_DIR=""
for state_file in "$PROJECT_ROOT"/specs/*/.dispatch-state.json; do
  [ -f "$state_file" ] || continue
  STATUS=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || continue
  if [ "$STATUS" = "dispatched" ]; then
    SPEC_DIR=$(dirname "$state_file")
    break
  fi
done

if [ -z "$SPEC_DIR" ] || [ ! -f "$SPEC_DIR/tasks.md" ]; then
  # No active dispatch or no tasks.md — allow through
  exit 0
fi

# Extract verify command for this task from tasks.md
# Look for the task ID line, then find the **Verify** bullet under it
VERIFY_CMD=""
IN_TASK=false

while IFS= read -r line; do
  # Check if this is our task line (match task ID at start of task bullet)
  if echo "$line" | grep -qE "^\s*- \[.\] ${TASK_ID}\b"; then
    IN_TASK=true
    continue
  fi

  # If we hit another task line, stop
  if [ "$IN_TASK" = true ] && echo "$line" | grep -qE "^\s*- \[.\] [0-9]"; then
    break
  fi

  # Extract verify command
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
echo "ralph-parallel: Running verification for task $TASK_ID: $VERIFY_CMD" >&2

if eval "$VERIFY_CMD" >/dev/null 2>&1; then
  # Verification passed
  exit 0
else
  # Verification failed — block task completion with feedback via stderr
  echo "QUALITY GATE FAILED for task $TASK_ID ($TASK_SUBJECT)" >&2
  echo "Verify command failed: $VERIFY_CMD" >&2
  echo "Fix the issues and mark the task complete again." >&2
  exit 2
fi
