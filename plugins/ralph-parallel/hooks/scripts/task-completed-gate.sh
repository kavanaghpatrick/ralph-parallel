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
    VERIFY_CMD=$(echo "$line" | sed 's/.*\*\*Verify\*\*:[[:space:]]*//' | sed 's/`//g' | xargs)
    break
  fi
done < "$SPEC_DIR/tasks.md"

if [ -z "$VERIFY_CMD" ]; then
  # No verify command found — allow through
  exit 0
fi

# Run the verify command from project root
cd "$PROJECT_ROOT"

# --- Stage 1: Verify command with output capture ---
echo "ralph-parallel: Verifying task $COMPLETED_SPEC_TASK: $VERIFY_CMD" >&2

VERIFY_OUTPUT=$(eval "$VERIFY_CMD" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?
if [ $VERIFY_EXIT -ne 0 ]; then
  echo "QUALITY GATE FAILED for task $COMPLETED_SPEC_TASK ($TASK_SUBJECT)" >&2
  echo "Verify command failed (exit $VERIFY_EXIT): $VERIFY_CMD" >&2
  echo "--- Output (last 50 lines) ---" >&2
  echo "$VERIFY_OUTPUT" | tail -50 >&2
  echo "Fix the issues and mark the task complete again." >&2
  exit 2
fi

# --- Stage 2: Supplemental typecheck ---
DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"
TYPECHECK_CMD=$(jq -r '.qualityCommands.typecheck // empty' "$DISPATCH_STATE" 2>/dev/null || true)

if [ -n "$TYPECHECK_CMD" ]; then
  echo "ralph-parallel: Running supplemental typecheck: $TYPECHECK_CMD" >&2
  TC_OUTPUT=$(eval "$TYPECHECK_CMD" 2>&1) && TC_EXIT=0 || TC_EXIT=$?
  if [ $TC_EXIT -ne 0 ]; then
    echo "SUPPLEMENTAL CHECK FAILED: typecheck" >&2
    echo "Command: $TYPECHECK_CMD (exit $TC_EXIT)" >&2
    echo "--- Output (last 30 lines) ---" >&2
    echo "$TC_OUTPUT" | tail -30 >&2
    echo "Fix type errors before marking task complete." >&2
    exit 2
  fi
fi

# --- Stage 3: File existence check ---
TASK_FILES=""
IN_TASK=false
while IFS= read -r fline; do
  if echo "$fline" | grep -qE "^\s*- \[.\] ${COMPLETED_SPEC_TASK}\b"; then
    IN_TASK=true; continue
  fi
  if [ "$IN_TASK" = true ] && echo "$fline" | grep -qE "^\s*- \[.\] [0-9]"; then break; fi
  if [ "$IN_TASK" = true ] && echo "$fline" | grep -qE "\*\*Files\*\*:"; then
    TASK_FILES=$(echo "$fline" | sed 's/.*\*\*Files\*\*:[[:space:]]*//' | sed 's/`//g' | xargs)
    break
  fi
done < "$SPEC_DIR/tasks.md"

if [ -n "$TASK_FILES" ]; then
  MISSING=""
  IFS=',' read -ra FILE_LIST <<< "$TASK_FILES"
  for f in "${FILE_LIST[@]}"; do
    f=$(echo "$f" | xargs)  # trim whitespace
    [ -z "$f" ] && continue
    if [ ! -e "$PROJECT_ROOT/$f" ]; then
      MISSING="$MISSING $f"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "SUPPLEMENTAL CHECK FAILED: file existence" >&2
    echo "Missing files:$MISSING" >&2
    echo "Create the missing files before marking task complete." >&2
    exit 2
  fi
fi

# --- Stage 4: Periodic build check ---
BUILD_CMD=$(jq -r '.qualityCommands.build // empty' "$DISPATCH_STATE" 2>/dev/null || true)
BUILD_INTERVAL=${BUILD_INTERVAL:-3}

if [ -n "$BUILD_CMD" ]; then
  # Count completed tasks (marked [x]) in tasks.md
  COMPLETED_COUNT=$(grep -cE '^\s*- \[x\]' "$SPEC_DIR/tasks.md" 2>/dev/null || echo 0)

  if [ $((COMPLETED_COUNT % BUILD_INTERVAL)) -eq 0 ] || [ "$COMPLETED_COUNT" -le 1 ]; then
    echo "ralph-parallel: Running periodic build check ($COMPLETED_COUNT tasks done): $BUILD_CMD" >&2
    BUILD_OUTPUT=$(eval "$BUILD_CMD" 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
    if [ $BUILD_EXIT -ne 0 ]; then
      echo "SUPPLEMENTAL CHECK FAILED: build (periodic, every ${BUILD_INTERVAL} tasks)" >&2
      echo "Command: $BUILD_CMD (exit $BUILD_EXIT)" >&2
      echo "--- Output (last 50 lines) ---" >&2
      echo "$BUILD_OUTPUT" | tail -50 >&2
      echo "Fix build errors before marking task complete." >&2
      exit 2
    fi
  fi
fi

# --- Stage 5: Test suite regression check ---
TEST_CMD=$(jq -r '.qualityCommands.test // empty' "$DISPATCH_STATE" 2>/dev/null || true)
TEST_INTERVAL=${TEST_INTERVAL:-2}

if [ -n "$TEST_CMD" ]; then
  # Reuse completed count from Stage 4 if available, otherwise recount
  if [ -z "${COMPLETED_COUNT:-}" ]; then
    COMPLETED_COUNT=$(grep -cE '^\s*- \[x\]' "$SPEC_DIR/tasks.md" 2>/dev/null || echo 0)
  fi

  if [ $((COMPLETED_COUNT % TEST_INTERVAL)) -eq 0 ] || [ "$COMPLETED_COUNT" -le 1 ]; then
    echo "ralph-parallel: Running test suite regression check ($COMPLETED_COUNT tasks done): $TEST_CMD" >&2
    TEST_OUTPUT=$(eval "$TEST_CMD" 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?
    if [ $TEST_EXIT -ne 0 ]; then
      echo "REGRESSION CHECK FAILED: test suite" >&2
      echo "Command: $TEST_CMD (exit $TEST_EXIT)" >&2
      echo "--- Output (last 50 lines) ---" >&2
      echo "$TEST_OUTPUT" | tail -50 >&2
      echo "Your changes broke existing tests. Fix ALL test failures before marking task complete." >&2
      exit 2
    fi
  fi
fi

# All stages passed
exit 0
