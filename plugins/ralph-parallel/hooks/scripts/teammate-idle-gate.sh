#!/bin/bash
# Ralph Parallel - Teammate Idle Quality Gate
# Prevents teammates from going idle when they have uncompleted tasks.
#
# Safety valve: after MAX_IDLE_BLOCKS repeated blocks, allows idle to prevent
# infinite token-burning loops. Counter resets on dispatch identity change.
#
# Exit codes:
#   0 = allow idle
#   2 = block idle + send stderr as feedback

set -euo pipefail

_sanitize_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "ralph-parallel: REJECTED empty name" >&2
    return 1
  fi
  if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'; then
    echo "ralph-parallel: REJECTED invalid name: $name" >&2
    return 1
  fi
  printf '%s' "$name"
}

# --- Counter functions (inlined from dispatch-coordinator.sh pattern) ---

read_block_counter() {
  local counter_file="$1"
  local current_status="$2"
  local dispatched_at="$3"

  if [ ! -f "$counter_file" ]; then
    echo "0"
    return
  fi

  local stored
  stored=$(cat "$counter_file" 2>/dev/null) || { echo "0"; return; }
  local stored_count stored_status stored_ts
  stored_count=$(echo "$stored" | cut -d: -f1)
  stored_status=$(echo "$stored" | cut -d: -f2)
  stored_ts=$(echo "$stored" | cut -d: -f3-)

  # Reset if dispatch identity changed
  if [ "$stored_status" != "$current_status" ] || [ "$stored_ts" != "$dispatched_at" ]; then
    echo "0"
    return
  fi

  echo "${stored_count:-0}"
}

write_block_counter() {
  local counter_file="$1"
  local count="$2"
  local current_status="$3"
  local dispatched_at="$4"
  echo "${count}:${current_status}:${dispatched_at}" > "$counter_file" 2>/dev/null || true
}

# --- Parse input ---

INPUT=$(cat)
TEAM_NAME=$(echo "$INPUT" | jq -r '.team_name // empty' 2>/dev/null) || TEAM_NAME=""
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null) || TEAMMATE_NAME=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

# Not a dispatch team — allow idle
if [ -z "$TEAM_NAME" ] || [[ "$TEAM_NAME" != *-parallel ]]; then
  exit 0
fi

SPEC_NAME="${TEAM_NAME%-parallel}"
SPEC_NAME=$(_sanitize_name "$SPEC_NAME") || exit 0
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"
SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"

# No dispatch state — allow idle
if [ ! -f "$DISPATCH_STATE" ]; then
  exit 0
fi

# --- Read dispatch identity for counter ---
STATUS=$(jq -r '.status // "unknown"' "$DISPATCH_STATE" 2>/dev/null) || STATUS="unknown"
DISPATCHED_AT=$(jq -r '.dispatchedAt // "unknown"' "$DISPATCH_STATE" 2>/dev/null) || DISPATCHED_AT="unknown"

MAX_IDLE_BLOCKS="${RALPH_MAX_IDLE_BLOCKS:-5}"
TEAMMATE_NAME_SAFE=$(_sanitize_name "$TEAMMATE_NAME" 2>/dev/null) || TEAMMATE_NAME_SAFE="unknown"
COUNTER_FILE="/tmp/ralph-idle-${SPEC_NAME}-${TEAMMATE_NAME_SAFE}"

# --- completedGroups bypass (authoritative source, checked before tasks.md) ---
TEAMMATE_GROUP_DONE=$(jq -r --arg name "$TEAMMATE_NAME" \
  '.completedGroups // [] | map(select(. == $name)) | length > 0' \
  "$DISPATCH_STATE" 2>/dev/null) || TEAMMATE_GROUP_DONE="false"

if [ "$TEAMMATE_GROUP_DONE" = "true" ]; then
  echo "ralph-parallel: Group '$TEAMMATE_NAME' in completedGroups — allowing idle" >&2
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
while IFS= read -r TASK_ID; do
  [ -z "$TASK_ID" ] && continue
  # Check if task line has [ ] (uncompleted) vs [x] (completed)
  if grep -qE "^\s*- \[ \] ${TASK_ID}\b" "$TASKS_MD"; then
    DESC=$(grep -oE "^\s*- \[ \] ${TASK_ID}\s+.*" "$TASKS_MD" | sed "s/.*${TASK_ID}\s*//" | head -1)
    UNCOMPLETED="${UNCOMPLETED}  - ${TASK_ID}: ${DESC}\n"
  fi
done <<< "$GROUP_TASKS"

if [ -z "$UNCOMPLETED" ]; then
  # All group tasks complete in tasks.md — allow idle
  exit 0
fi

# --- Safety valve check ---
BLOCK_COUNT=$(read_block_counter "$COUNTER_FILE" "$STATUS" "$DISPATCHED_AT")

if [ "$BLOCK_COUNT" -ge "$MAX_IDLE_BLOCKS" ] 2>/dev/null; then
  echo "ralph-parallel: SAFETY VALVE — allowing idle after $BLOCK_COUNT blocks (max $MAX_IDLE_BLOCKS)" >&2
  echo "ralph-parallel: Teammate '$TEAMMATE_NAME' may have stuck tasks. Check dispatch state." >&2
  exit 0
fi

# --- Increment counter and block ---
NEW_COUNT=$((BLOCK_COUNT + 1))
write_block_counter "$COUNTER_FILE" "$NEW_COUNT" "$STATUS" "$DISPATCHED_AT"

echo "Continue working. You have uncompleted tasks (block $NEW_COUNT/$MAX_IDLE_BLOCKS):" >&2
echo -e "$UNCOMPLETED" >&2
echo "Claim the next uncompleted task, implement it, and mark it complete." >&2
exit 2
