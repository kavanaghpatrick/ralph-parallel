#!/bin/bash
# Ralph Parallel - Baseline Test Snapshot Capture
#
# Standalone script that replaces dispatch.md Step 4.5 prose with deterministic code.
# Runs the project's test command, parses the test count, and writes a baseline
# snapshot into the dispatch-state.json for later regression comparison.
#
# Usage:
#   scripts/capture-baseline.sh --dispatch-state specs/$specName/.dispatch-state.json
#
# Output (stdout): JSON object with baseline result
# Informational messages: stderr only (stdout reserved for JSON)
#
# Exit codes:
#   0 = always (never blocks dispatch)

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────

DISPATCH_STATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dispatch-state)
      DISPATCH_STATE="$2"
      shift 2
      ;;
    *)
      echo "Usage: capture-baseline.sh --dispatch-state <path-to-dispatch-state.json>" >&2
      exit 1
      ;;
  esac
done

if [ -z "$DISPATCH_STATE" ]; then
  echo "Error: --dispatch-state is required" >&2
  echo "Usage: capture-baseline.sh --dispatch-state <path-to-dispatch-state.json>" >&2
  exit 1
fi

if [ ! -f "$DISPATCH_STATE" ]; then
  echo "Error: dispatch-state.json not found: $DISPATCH_STATE" >&2
  exit 1
fi

# ── Resolve project root ─────────────────────────────────────
# dispatch-state.json lives at specs/<name>/.dispatch-state.json
# Project root is 2 levels up from the directory containing it.
SPEC_DIR=$(cd "$(dirname "$DISPATCH_STATE")" && pwd)
PROJECT_ROOT=$(cd "$SPEC_DIR/../.." && pwd)

echo "ralph-parallel: Capturing baseline test snapshot" >&2
echo "ralph-parallel: Dispatch state: $DISPATCH_STATE" >&2
echo "ralph-parallel: Project root: $PROJECT_ROOT" >&2

# ── Read test command from dispatch-state.json ────────────────

TEST_CMD=$(jq -r '.qualityCommands.test // empty' "$DISPATCH_STATE" 2>/dev/null || true)

if [ -z "$TEST_CMD" ]; then
  echo "ralph-parallel: No test command in dispatch-state.json — skipping baseline" >&2
  RESULT='{"testCount": -1, "reason": "no_test_command"}'
  echo "$RESULT"
  # Update dispatch-state.json with baseline snapshot
  jq --argjson snap "$RESULT" '.baselineSnapshot = $snap' "$DISPATCH_STATE" > "${DISPATCH_STATE}.tmp" \
    && mv "${DISPATCH_STATE}.tmp" "$DISPATCH_STATE"
  exit 0
fi

echo "ralph-parallel: Running test command: $TEST_CMD" >&2

# ── Run the test command ──────────────────────────────────────

cd "$PROJECT_ROOT"
TEST_OUTPUT=$(eval "$TEST_CMD" 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?

if [ "$TEST_EXIT" -ne 0 ]; then
  echo "ralph-parallel: Test command failed (exit $TEST_EXIT) — baseline will be -1" >&2
  echo "ralph-parallel: Last 20 lines of output:" >&2
  echo "$TEST_OUTPUT" | tail -20 >&2
  RESULT=$(jq -n --argjson exit_code "$TEST_EXIT" '{testCount: -1, exitCode: $exit_code, reason: "tests_failing"}')
  echo "$RESULT"
  # Update dispatch-state.json
  jq --argjson snap "$RESULT" '.baselineSnapshot = $snap' "$DISPATCH_STATE" > "${DISPATCH_STATE}.tmp" \
    && mv "${DISPATCH_STATE}.tmp" "$DISPATCH_STATE"
  exit 0
fi

# ── Parse test count ──────────────────────────────────────────
# Regex cascade matching task-completed-gate.sh parse_test_count function.

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

  # Generic fallback: count lines containing pass/ok/checkmark
  count=$(echo "$output" | grep -ciE '(pass|✓|✔)' 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ] 2>/dev/null; then echo "$count"; return; fi

  echo "-1"
}

TEST_COUNT=$(parse_test_count "$TEST_OUTPUT")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ "$TEST_COUNT" -eq -1 ] 2>/dev/null; then
  echo "ralph-parallel: Could not parse test count from output — baseline unparseable" >&2
  RESULT=$(jq -n '{testCount: -1, reason: "unparseable"}')
  echo "$RESULT"
  # Update dispatch-state.json
  jq --argjson snap "$RESULT" '.baselineSnapshot = $snap' "$DISPATCH_STATE" > "${DISPATCH_STATE}.tmp" \
    && mv "${DISPATCH_STATE}.tmp" "$DISPATCH_STATE"
  exit 0
fi

# ── Success: output baseline JSON ────────────────────────────

echo "ralph-parallel: Baseline captured: $TEST_COUNT tests passing" >&2

RESULT=$(jq -n \
  --argjson count "$TEST_COUNT" \
  --arg ts "$TIMESTAMP" \
  --arg cmd "$TEST_CMD" \
  '{testCount: $count, capturedAt: $ts, command: $cmd, exitCode: 0}')

echo "$RESULT"

# ── Update dispatch-state.json in-place ───────────────────────

jq --argjson snap "$RESULT" '.baselineSnapshot = $snap' "$DISPATCH_STATE" > "${DISPATCH_STATE}.tmp" \
  && mv "${DISPATCH_STATE}.tmp" "$DISPATCH_STATE"

echo "ralph-parallel: Baseline written to dispatch-state.json" >&2
exit 0
