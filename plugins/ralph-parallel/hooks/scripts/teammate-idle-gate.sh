#!/bin/bash
# Ralph Parallel - Teammate Idle Quality Gate
# Prevents teammates from going idle when they have uncompleted tasks.
#
# Exit codes:
#   0 = allow idle
#   2 = block idle + send stderr as feedback

set -euo pipefail

INPUT=$(cat)
TEAM_NAME=$(echo "$INPUT" | jq -r '.team_name // empty' 2>/dev/null) || TEAM_NAME=""
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null) || TEAMMATE_NAME=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

# Not a dispatch team — allow idle
if [ -z "$TEAM_NAME" ] || [[ "$TEAM_NAME" != *-parallel ]]; then
  exit 0
fi

SPEC_NAME="${TEAM_NAME%-parallel}"
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"
SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"

# No dispatch state — allow idle
if [ ! -f "$DISPATCH_STATE" ]; then
  exit 0
fi

# Find the group matching this teammate
GROUP_TASKS=$(jq -r --arg name "$TEAMMATE_NAME" \
  '.groups[] | select(.name == $name) | .tasks[]' \
  "$DISPATCH_STATE" 2>/dev/null) || GROUP_TASKS=""

# Teammate not in any group — allow idle
if [ -z "$GROUP_TASKS" ]; then
  exit 0
fi

# Check tasks.md for uncompleted tasks
TASKS_MD="$SPEC_DIR/tasks.md"
if [ ! -f "$TASKS_MD" ]; then
  exit 0
fi

UNCOMPLETED=""
for TASK_ID in $GROUP_TASKS; do
  # Check if task line has [ ] (uncompleted) vs [x] (completed)
  if grep -qE "^\s*- \[ \] ${TASK_ID}\b" "$TASKS_MD"; then
    DESC=$(grep -oE "^\s*- \[ \] ${TASK_ID}\s+.*" "$TASKS_MD" | sed "s/.*${TASK_ID}\s*//" | head -1)
    UNCOMPLETED="${UNCOMPLETED}  - ${TASK_ID}: ${DESC}\n"
  fi
done

if [ -z "$UNCOMPLETED" ]; then
  # All group tasks complete — allow idle
  exit 0
fi

# Block idle — re-engage teammate
echo "Continue working. You have uncompleted tasks:" >&2
echo -e "$UNCOMPLETED" >&2
echo "Claim the next uncompleted task, implement it, and mark it complete." >&2
exit 2
