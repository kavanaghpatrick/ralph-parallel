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

_sanitize_cmd() {
  local cmd="$1"
  # Reject null bytes
  if printf '%s' "$cmd" | grep -qP '\x00' 2>/dev/null; then
    echo "ralph-parallel: REJECTED command (null bytes): $cmd" >&2
    return 1
  fi
  # Reject command substitution attempts
  if printf '%s' "$cmd" | grep -qE '\$\(|`' 2>/dev/null; then
    echo "ralph-parallel: REJECTED command (substitution): $cmd" >&2
    return 1
  fi
  # Reject path traversal
  if printf '%s' "$cmd" | grep -qF '..' 2>/dev/null; then
    echo "ralph-parallel: REJECTED command (path traversal): $cmd" >&2
    return 1
  fi
  return 0
}

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

# Determine project root (git rev-parse is canonical; CWD fallback for non-git envs)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"

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
  COMPLETED_SPEC_TASK=$(echo "$TASK_SUBJECT" | grep -oE '^[0-9]+\.[0-9]+' || true)
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
    VERIFY_CMD=$(echo "$line" | sed 's/.*\*\*Verify\*\*:[[:space:]]*//' | sed 's/`//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    break
  fi
done < "$SPEC_DIR/tasks.md"

if [ -z "$VERIFY_CMD" ]; then
  # No verify command found — allow through
  exit 0
fi

# --- Stage 1: Verify command with output capture ---
echo "ralph-parallel: Verifying task $COMPLETED_SPEC_TASK: $VERIFY_CMD" >&2

_sanitize_cmd "$VERIFY_CMD" || { echo "ralph-parallel: Command rejected by sanitizer: $VERIFY_CMD" >&2; exit 2; }
VERIFY_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$VERIFY_CMD" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?
if [ $VERIFY_EXIT -ne 0 ]; then
  echo "QUALITY GATE FAILED for task $COMPLETED_SPEC_TASK ($TASK_SUBJECT)" >&2
  echo "Verify command failed (exit $VERIFY_EXIT): $VERIFY_CMD" >&2
  echo "--- Output (last 50 lines) ---" >&2
  echo "$VERIFY_OUTPUT" | tail -50 >&2
  echo "Fix the issues and mark the task complete again." >&2
  exit 2
fi

# --- Assign DISPATCH_STATE before Stage 1.5 (needs it for quality commands) ---
DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"

# --- Stage 1.5: VERIFY task phase gate ---
# If the completed task is a [VERIFY] checkpoint, enforce full quality gate.
IS_VERIFY=false
while IFS= read -r vline; do
  if echo "$vline" | grep -qE "^\s*- \[.\] ${COMPLETED_SPEC_TASK}\b" && echo "$vline" | grep -qF "[VERIFY]"; then
    IS_VERIFY=true
    break
  fi
done < "$SPEC_DIR/tasks.md"

if [ "$IS_VERIFY" = true ]; then
  echo "ralph-parallel: VERIFY checkpoint detected for task $COMPLETED_SPEC_TASK — running full phase gate" >&2

  # Check all preceding tasks in same phase are [x]
  TASK_PHASE=$(echo "$COMPLETED_SPEC_TASK" | cut -d. -f1)
  UNCHECKED_PRECEDING=""
  while IFS= read -r pline; do
    PTID=$(echo "$pline" | grep -oE '^\s*- \[ \] [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' || true)
    if [ -n "$PTID" ]; then
      PPHASE=$(echo "$PTID" | cut -d. -f1)
      if [ "$PPHASE" = "$TASK_PHASE" ]; then
        # Compare: PTID < COMPLETED_SPEC_TASK (by numeric X.Y ordering)
        PT_MAJOR=$(echo "$PTID" | cut -d. -f1)
        PT_MINOR=$(echo "$PTID" | cut -d. -f2)
        CT_MAJOR=$(echo "$COMPLETED_SPEC_TASK" | cut -d. -f1)
        CT_MINOR=$(echo "$COMPLETED_SPEC_TASK" | cut -d. -f2)
        if [ "$PT_MAJOR" -lt "$CT_MAJOR" ] 2>/dev/null || \
           { [ "$PT_MAJOR" -eq "$CT_MAJOR" ] && [ "$PT_MINOR" -lt "$CT_MINOR" ]; } 2>/dev/null; then
          UNCHECKED_PRECEDING="$UNCHECKED_PRECEDING $PTID"
        fi
      fi
    fi
  done < "$SPEC_DIR/tasks.md"

  if [ -n "$UNCHECKED_PRECEDING" ]; then
    echo "VERIFY PHASE GATE FAILED for task $COMPLETED_SPEC_TASK" >&2
    echo "Unchecked preceding tasks in phase $TASK_PHASE:$UNCHECKED_PRECEDING" >&2
    echo "All tasks in the phase must be complete before the VERIFY checkpoint passes." >&2
    exit 2
  fi

  # Run ALL quality commands (build, test, lint) regardless of periodic intervals
  for SLOT in build test lint; do
    SLOT_CMD=$(jq -r ".qualityCommands.${SLOT} // empty" "$DISPATCH_STATE" 2>/dev/null || true)
    if [ "$SLOT_CMD" = "null" ]; then SLOT_CMD=""; fi
    if [ -n "$SLOT_CMD" ]; then
      echo "ralph-parallel: VERIFY phase gate — running $SLOT: $SLOT_CMD" >&2
      _sanitize_cmd "$SLOT_CMD" || { echo "ralph-parallel: Command rejected by sanitizer: $SLOT_CMD" >&2; exit 2; }
      SLOT_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$SLOT_CMD" 2>&1) && SLOT_EXIT=0 || SLOT_EXIT=$?
      if [ $SLOT_EXIT -ne 0 ]; then
        echo "VERIFY PHASE GATE FAILED: $SLOT command failed (exit $SLOT_EXIT)" >&2
        echo "Command: $SLOT_CMD" >&2
        echo "--- Output (last 50 lines) ---" >&2
        echo "$SLOT_OUTPUT" | tail -50 >&2
        echo "Fix $SLOT errors before completing this VERIFY checkpoint." >&2
        exit 2
      fi
      echo "ralph-parallel: VERIFY $SLOT passed" >&2
    fi
  done

  echo "ralph-parallel: VERIFY phase gate passed for task $COMPLETED_SPEC_TASK" >&2
  # Continue to remaining stages (typecheck, file check, etc.) for additional safety
fi

# --- Stage 2: Supplemental typecheck ---
TYPECHECK_CMD=$(jq -r '.qualityCommands.typecheck // empty' "$DISPATCH_STATE" 2>/dev/null || true)

if [ -n "$TYPECHECK_CMD" ]; then
  echo "ralph-parallel: Running supplemental typecheck: $TYPECHECK_CMD" >&2
  _sanitize_cmd "$TYPECHECK_CMD" || { echo "ralph-parallel: Command rejected by sanitizer: $TYPECHECK_CMD" >&2; exit 2; }
  TC_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$TYPECHECK_CMD" 2>&1) && TC_EXIT=0 || TC_EXIT=$?
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
    TASK_FILES=$(echo "$fline" | sed 's/.*\*\*Files\*\*:[[:space:]]*//' | sed 's/`//g' | sed 's/ *(NEW)//g; s/ *(MODIFY)//g; s/ *(CREATE)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    break
  fi
done < "$SPEC_DIR/tasks.md"

# Skip file check for sentinel values (none, n/a, -, empty)
case "$(echo "$TASK_FILES" | tr '[:upper:]' '[:lower:]')" in
  none|n/a|n/a\ *|-|"") TASK_FILES="" ;;
esac

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
    _sanitize_cmd "$BUILD_CMD" || { echo "ralph-parallel: Command rejected by sanitizer: $BUILD_CMD" >&2; exit 2; }
    BUILD_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$BUILD_CMD" 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
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

# parse_test_count: Extract passing test count from test runner output.
# Returns count via echo. Returns -1 if unparseable.
parse_test_count() {
  local output="$1"
  local count=""

  # Jest/Vitest: "Tests:  5 passed" or "5 passed"
  count=$(echo "$output" | grep -oE 'Tests:\s+[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  if [ -n "$count" ]; then echo "$count"; return; fi

  # Pytest: "5 passed"
  count=$(echo "$output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  if [ -n "$count" ]; then echo "$count"; return; fi

  # Cargo test: "test result: ok. 5 passed"
  count=$(echo "$output" | grep -oE 'test result:.*[0-9]+ passed' | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  if [ -n "$count" ]; then echo "$count"; return; fi

  # Go test: count "ok" lines
  count=$(echo "$output" | grep -cE '^ok\s+' 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ] 2>/dev/null; then echo "$count"; return; fi

  # Generic fallback: count lines containing pass/ok/✓
  count=$(echo "$output" | grep -ciE '(pass|✓|✔)' 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ] 2>/dev/null; then echo "$count"; return; fi

  echo "-1"
}

TEST_CMD=$(jq -r '.qualityCommands.test // empty' "$DISPATCH_STATE" 2>/dev/null || true)
BASELINE_JSON=$(jq -r '.baselineSnapshot // {}' "$DISPATCH_STATE" 2>/dev/null || true)
BASELINE_HARD_FAIL=$(echo "$BASELINE_JSON" | jq -r '.hardFail // false' 2>/dev/null || true)
BASELINE_EXIT_CODE=$(echo "$BASELINE_JSON" | jq -r '.exitCode // empty' 2>/dev/null || true)
if [ "$BASELINE_HARD_FAIL" = "null" ]; then BASELINE_HARD_FAIL="false"; fi
TEST_INTERVAL=${TEST_INTERVAL:-2}

if [ -n "$TEST_CMD" ]; then
  # Reuse completed count from Stage 4 if available, otherwise recount
  if [ -z "${COMPLETED_COUNT:-}" ]; then
    COMPLETED_COUNT=$(grep -cE '^\s*- \[x\]' "$SPEC_DIR/tasks.md" 2>/dev/null || echo 0)
  fi

  if [ $((COMPLETED_COUNT % TEST_INTERVAL)) -eq 0 ] || [ "$COMPLETED_COUNT" -le 1 ]; then
    echo "ralph-parallel: Running test suite regression check ($COMPLETED_COUNT tasks done): $TEST_CMD" >&2
    _sanitize_cmd "$TEST_CMD" || { echo "ralph-parallel: Command rejected by sanitizer: $TEST_CMD" >&2; exit 2; }
    TEST_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$TEST_CMD" 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?

    # --- Baseline comparison: detect test count regression ---
    BASELINE_COUNT=$(echo "$BASELINE_JSON" | jq -r '.testCount // empty' 2>/dev/null || true)
    # Guard against jq returning literal "null" string
    if [ "$BASELINE_COUNT" = "null" ] || [ "$BASELINE_COUNT" = "" ]; then
      BASELINE_COUNT=""
    fi

    if [ $TEST_EXIT -ne 0 ]; then
      # Tests failed — check if this is a pre-existing hardFail
      if [ "$BASELINE_HARD_FAIL" = "true" ] && [ -n "$BASELINE_EXIT_CODE" ] && \
         [ "$TEST_EXIT" -eq "$BASELINE_EXIT_CODE" ] 2>/dev/null; then
        echo "ralph-parallel: Tests failing with same exit code ($TEST_EXIT) as broken baseline — pre-existing, allowing" >&2
      else
        echo "REGRESSION CHECK FAILED: test suite" >&2
        echo "Command: $TEST_CMD (exit $TEST_EXIT)" >&2
        echo "--- Output (last 50 lines) ---" >&2
        echo "$TEST_OUTPUT" | tail -50 >&2
        if [ "$BASELINE_HARD_FAIL" = "true" ]; then
          echo "Baseline was also broken (exit ${BASELINE_EXIT_CODE:-unknown}) but this is a DIFFERENT failure." >&2
        fi
        echo "Fix ALL test failures before marking task complete." >&2
        exit 2
      fi
    else
      # Tests passed — do baseline count comparison
      TEST_OUTPUT_CLEAN=$(printf '%s' "$TEST_OUTPUT" | sed $'s/\x1b\\[[0-9;]*m//g')

      if [ "$BASELINE_HARD_FAIL" = "true" ]; then
        echo "ralph-parallel: Tests now PASSING (improved from broken baseline)" >&2
      fi

      if [ -n "$BASELINE_COUNT" ] && [ "$BASELINE_COUNT" -gt 0 ] 2>/dev/null; then
        CURRENT_COUNT=$(parse_test_count "$TEST_OUTPUT_CLEAN")
        if [ "$CURRENT_COUNT" -gt 0 ] 2>/dev/null; then
          if [ "$BASELINE_COUNT" -le 10 ] 2>/dev/null; then
            THRESHOLD=$((BASELINE_COUNT - 1))
            [ "$THRESHOLD" -lt 1 ] && THRESHOLD=1
          else
            THRESHOLD=$(( BASELINE_COUNT * 90 / 100 ))
          fi
          if [ "$CURRENT_COUNT" -lt "$THRESHOLD" ]; then
            echo "TEST COUNT REGRESSION DETECTED" >&2
            echo "Baseline: $BASELINE_COUNT tests passing at dispatch" >&2
            echo "Current:  $CURRENT_COUNT tests passing now" >&2
            echo "Threshold: $THRESHOLD (minimum allowed)" >&2
            echo "Your changes may have deleted or broken existing tests." >&2
            echo "Restore missing tests before marking task complete." >&2
            exit 2
          fi
          echo "ralph-parallel: Test count OK ($CURRENT_COUNT current vs $BASELINE_COUNT baseline)" >&2
        fi
      fi
    fi
  fi
fi

# --- Stage 6: Periodic lint check ---
LINT_CMD=$(jq -r '.qualityCommands.lint // empty' "$DISPATCH_STATE" 2>/dev/null || true)
# Guard against jq returning literal "null" string
if [ "$LINT_CMD" = "null" ]; then
  LINT_CMD=""
fi
LINT_INTERVAL=${LINT_INTERVAL:-3}

if [ -n "$LINT_CMD" ]; then
  # Reuse completed count from earlier stages if available, otherwise recount
  if [ -z "${COMPLETED_COUNT:-}" ]; then
    COMPLETED_COUNT=$(grep -cE '^\s*- \[x\]' "$SPEC_DIR/tasks.md" 2>/dev/null || echo 0)
  fi

  if [ $((COMPLETED_COUNT % LINT_INTERVAL)) -eq 0 ] || [ "$COMPLETED_COUNT" -le 1 ]; then
    echo "ralph-parallel: Running periodic lint check ($COMPLETED_COUNT tasks done): $LINT_CMD" >&2
    _sanitize_cmd "$LINT_CMD" || { echo "ralph-parallel: Command rejected by sanitizer: $LINT_CMD" >&2; exit 2; }
    LINT_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$LINT_CMD" 2>&1) && LINT_EXIT=0 || LINT_EXIT=$?
    if [ $LINT_EXIT -ne 0 ]; then
      echo "SUPPLEMENTAL CHECK FAILED: lint (periodic, every ${LINT_INTERVAL} tasks)" >&2
      echo "Command: $LINT_CMD (exit $LINT_EXIT)" >&2
      echo "--- Output (last 30 lines) ---" >&2
      echo "$LINT_OUTPUT" | tail -30 >&2
      echo "Fix lint errors before marking task complete." >&2
      exit 2
    fi
    echo "ralph-parallel: Lint check passed ($COMPLETED_COUNT tasks done)" >&2
  fi
fi

# All stages passed
exit 0
