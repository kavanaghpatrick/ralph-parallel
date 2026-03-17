#!/bin/bash
# Integration tests for teammate-idle-gate.sh
set -euo pipefail

_RALPH_TMP="${TMPDIR:-/tmp}"
GATE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/teammate-idle-gate.sh"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected_exit="$2"
  local check_stderr="$3"  # substring to look for in stderr, or empty
  shift 3

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/specs/test-spec"

  # Let test setup function populate files
  "$@" "$tmpdir"

  # Build input JSON
  local teammate_name="${TEST_TEAMMATE_NAME:-test-group}"
  local team_name="${TEST_TEAM_NAME:-test-spec-parallel}"
  local input
  input=$(cat <<JSON
{"team_name":"$team_name","teammate_name":"$teammate_name","cwd":"$tmpdir"}
JSON
  )

  local stderr_file="$tmpdir/stderr.txt"
  local exit_code=0
  echo "$input" | bash "$GATE_SCRIPT" 2>"$stderr_file" || exit_code=$?

  if [ "$exit_code" -ne "$expected_exit" ]; then
    echo "FAIL: $name — expected exit $expected_exit, got $exit_code"
    cat "$stderr_file"
    FAIL=$((FAIL + 1))
    unset TEST_TEAMMATE_NAME TEST_TEAM_NAME
    return
  fi

  if [ -n "$check_stderr" ]; then
    if ! grep -q "$check_stderr" "$stderr_file" 2>/dev/null; then
      echo "FAIL: $name — expected '$check_stderr' in stderr"
      cat "$stderr_file"
      FAIL=$((FAIL + 1))
      unset TEST_TEAMMATE_NAME TEST_TEAM_NAME
      return
    fi
  fi

  echo "PASS: $name"
  PASS=$((PASS + 1))
  unset TEST_TEAMMATE_NAME TEST_TEAM_NAME
}

# ── Setup functions ──────────────────────────────────────────

setup_all_tasks_done() {
  local dir="$1"
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","dispatchedAt":"2026-03-04T00:00:00Z",
 "groups":[{"name":"test-group","tasks":["1.1","1.2"]}],
 "completedGroups":[]}
EOF
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [x] 1.1 First task
- [x] 1.2 Second task
EOF
}

setup_uncompleted_tasks() {
  local dir="$1"
  rm -f "$_RALPH_TMP/ralph-idle-test-spec-test-group" 2>/dev/null || true
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","dispatchedAt":"2026-03-04T00:00:00Z",
 "groups":[{"name":"test-group","tasks":["1.1","1.2"]}],
 "completedGroups":[]}
EOF
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [x] 1.1 First task
- [ ] 1.2 Second task
EOF
}

setup_safety_valve() {
  local dir="$1"
  # Pre-seed counter at MAX_IDLE_BLOCKS (5)
  echo "5:dispatched:2026-03-04T00:00:00Z" > "$_RALPH_TMP/ralph-idle-test-spec-test-group"
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","dispatchedAt":"2026-03-04T00:00:00Z",
 "groups":[{"name":"test-group","tasks":["1.1","1.2"]}],
 "completedGroups":[]}
EOF
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [x] 1.1 First task
- [ ] 1.2 Second task
EOF
}

setup_counter_reset() {
  local dir="$1"
  # Counter from OLD dispatch (different dispatchedAt) — should reset to 0
  echo "10:dispatched:2026-01-01T00:00:00Z" > "$_RALPH_TMP/ralph-idle-test-spec-test-group"
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","dispatchedAt":"2026-03-04T00:00:00Z",
 "groups":[{"name":"test-group","tasks":["1.1","1.2"]}],
 "completedGroups":[]}
EOF
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [x] 1.1 First task
- [ ] 1.2 Second task
EOF
}

setup_completed_groups_bypass() {
  local dir="$1"
  rm -f "$_RALPH_TMP/ralph-idle-test-spec-test-group" 2>/dev/null || true
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","dispatchedAt":"2026-03-04T00:00:00Z",
 "groups":[{"name":"test-group","tasks":["1.1","1.2"]}],
 "completedGroups":["test-group"]}
EOF
  # tasks.md still shows uncompleted — should be ignored due to completedGroups
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [x] 1.1 First task
- [ ] 1.2 Second task
EOF
}

setup_no_dispatch_state() {
  local dir="$1"
  # No .dispatch-state.json — should allow idle
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [ ] 1.1 First task
EOF
}

setup_non_dispatch_team() {
  local dir="$1"
  # team_name without -parallel suffix
  export TEST_TEAM_NAME="regular-team"
}

# ── Run tests ─────────────────────────────────────────────────

run_test "all tasks complete — allow idle"           0  ""                     setup_all_tasks_done
run_test "uncompleted tasks — block idle"            2  "uncompleted tasks"    setup_uncompleted_tasks
run_test "safety valve — allow after MAX blocks"     0  "SAFETY VALVE"         setup_safety_valve
run_test "counter reset on dispatch change — block"  2  "uncompleted tasks"    setup_counter_reset
run_test "completedGroups bypass — allow idle"       0  "completedGroups"      setup_completed_groups_bypass
run_test "no dispatch state — allow idle"            0  ""                     setup_no_dispatch_state
run_test "non-dispatch team — allow idle"            0  ""                     setup_non_dispatch_team

# ── Cleanup ──────────────────────────────────────────────────

rm -f "$_RALPH_TMP/ralph-idle-test-spec-test-group" 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
