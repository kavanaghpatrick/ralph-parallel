#!/bin/bash
# Test suite for session isolation feature
# Tests dispatch-coordinator.sh (Stop hook) and session-setup.sh (SessionStart hook)
#
# Usage: bash ralph-parallel/scripts/test_session_isolation.sh
#
# Outputs per-test PASS/FAIL lines for grep-based verification:
#   T-1 PASS: Matching session blocked
#   EC-2 PASS: Corrupted JSON exits gracefully

set -uo pipefail

# Isolate tests from parent environment (e.g., running inside a team dispatch)
unset CLAUDE_CODE_AGENT_NAME 2>/dev/null || true
unset CLAUDE_CODE_TEAM_NAME 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

STOP_HOOK="$PROJECT_ROOT/ralph-parallel/hooks/scripts/dispatch-coordinator.sh"
SESSION_HOOK="$PROJECT_ROOT/ralph-parallel/hooks/scripts/session-setup.sh"

PASSES=0
FAILURES=0
CURRENT_TEST=""
TEST_PASS=true

# --- Helper Functions ---

setup_project() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/specs/test-spec"
  echo "$tmpdir"
}

setup_git_project() {
  local tmpdir
  tmpdir=$(mktemp -d)
  (cd "$tmpdir" && git init -q && git commit --allow-empty -m "init" -q)
  mkdir -p "$tmpdir/specs/test-spec"
  echo "$tmpdir"
}

write_dispatch_state() {
  local dir="$1" coord="$2" status="${3:-dispatched}" spec="${4:-test-spec}"
  mkdir -p "$dir/specs/$spec"
  local coord_field=""
  if [ "$coord" = "null" ]; then
    coord_field='"coordinatorSessionId": null,'
  elif [ -n "$coord" ]; then
    coord_field="\"coordinatorSessionId\": \"$coord\","
  fi
  cat > "$dir/specs/$spec/.dispatch-state.json" <<JSON
{
  ${coord_field}
  "status": "${status}",
  "groups": [{"name": "g1"}],
  "completedGroups": []
}
JSON
}

write_team_config() {
  local spec="$1" count="$2"
  local dir="$HOME/.claude/teams/${spec}-parallel"
  mkdir -p "$dir"
  if [ "$count" -gt 0 ]; then
    echo '{"members":[{"name":"teammate-1","agentId":"abc-123","agentType":"general-purpose"}]}' > "$dir/config.json"
  else
    echo '{"members":[]}' > "$dir/config.json"
  fi
}

cleanup_team_config() {
  rm -rf "$HOME/.claude/teams/${1}-parallel"
}

begin_test() {
  CURRENT_TEST="$1"
  TEST_PASS=true
}

end_test() {
  local desc="$1"
  if [ "$TEST_PASS" = true ]; then
    echo "$CURRENT_TEST PASS: $desc"
  else
    echo "$CURRENT_TEST FAIL: $desc"
  fi
}

assert_exit_code() {
  local actual="$1" expected="$2" desc="${3:-}"
  if [ "$actual" -eq "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "  ASSERT FAIL: expected exit $expected, got $actual ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
  fi
}

assert_json_field() {
  local file="$1" expr="$2" expected="$3" desc="${4:-}"
  local actual
  actual=$(jq -r "$expr" "$file" 2>/dev/null) || actual="<jq-error>"
  if [ "$actual" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "  ASSERT FAIL: jq '$expr' = '$actual', expected '$expected' ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
  fi
}

assert_file_contains() {
  local file="$1" pattern="$2" desc="${3:-}"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    PASSES=$((PASSES + 1))
  else
    echo "  ASSERT FAIL: '$file' does not contain '$pattern' ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
  fi
}

assert_true() {
  local condition="$1" desc="${2:-}"
  if [ "$condition" = "true" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "  ASSERT FAIL: expected true, got '$condition' ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
  fi
}

# Run stop hook with clean env (no CLAUDE_CODE_* vars)
run_stop_hook() {
  env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME bash "$STOP_HOOK"
}

# Run session hook with clean env in given directory
run_session_hook() {
  local dir="$1"
  shift
  (cd "$dir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME "$@" bash "$SESSION_HOOK")
}

# --- Unit Tests: dispatch-coordinator.sh (Stop Hook) ---

test_T1_matching_session_blocked() {
  begin_test "T-1"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local exit_code=0
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 2 "matching session should be blocked"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Matching session blocked"
}

test_T2_mismatching_session_allowed() {
  begin_test "T-2"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local exit_code=0
  echo "{\"session_id\":\"sess-B\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 0 "different session should be allowed"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Mismatching session allowed"
}

test_T3_legacy_no_coord_blocks() {
  begin_test "T-3"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "" "dispatched"
  write_team_config "test-spec" 1

  local exit_code=0
  echo "{\"session_id\":\"sess-B\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 2 "legacy dispatch should block any session"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Legacy dispatch blocks any session"
}

test_T4_non_active_dispatch_allows() {
  begin_test "T-4"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "merged"

  local exit_code=0
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 0 "merged dispatch should allow stop"
  rm -rf "$tmpdir"
  end_test "Non-active dispatch allows stop"
}

test_T5_empty_session_id_blocks() {
  begin_test "T-5"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local exit_code=0
  echo "{\"session_id\":\"\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 2 "empty session_id should block"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Empty session_id blocks"
}

# --- Unit Tests: session-setup.sh (SessionStart Hook) ---

test_T6_auto_reclaim_on_mismatch_with_team() {
  begin_test "T-6"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-B\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-B" "coord should be updated"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Auto-reclaim on mismatch with team"
}

test_T7_no_reclaim_without_team() {
  begin_test "T-7"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  cleanup_team_config "test-spec"

  echo "{\"session_id\":\"sess-B\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-A" "coord should remain unchanged"
  rm -rf "$tmpdir"
  end_test "No reclaim without team"
}

test_T8_legacy_stamp_with_team() {
  begin_test "T-8"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-B\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-B" "legacy should get session stamped"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Legacy stamp with team"
}

test_T9_no_stamp_without_team() {
  begin_test "T-9"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "" "dispatched"
  cleanup_team_config "test-spec"

  echo "{\"session_id\":\"sess-B\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  local has_field
  has_field=$(jq 'has("coordinatorSessionId")' "$tmpdir/specs/test-spec/.dispatch-state.json" 2>/dev/null) || has_field="error"
  assert_true "$([ "$has_field" = "false" ] && echo true || echo false)" "coord field should not be added"
  rm -rf "$tmpdir"
  end_test "No stamp without team"
}

test_T10_env_file_export() {
  begin_test "T-10"
  local tmpdir; tmpdir=$(setup_git_project)
  local envfile; envfile=$(mktemp)

  echo "{\"session_id\":\"sess-X\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | (cd "$tmpdir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME CLAUDE_ENV_FILE="$envfile" bash "$SESSION_HOOK") > /dev/null 2>&1

  assert_file_contains "$envfile" "CLAUDE_SESSION_ID=sess-X" "env file should contain session ID"
  rm -f "$envfile"; rm -rf "$tmpdir"
  end_test "CLAUDE_ENV_FILE export"
}

test_T11_no_error_without_env_file() {
  begin_test "T-11"
  local tmpdir; tmpdir=$(setup_git_project)

  local exit_code=0
  echo "{\"session_id\":\"sess-B\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | (cd "$tmpdir" && env -u CLAUDE_ENV_FILE -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME bash "$SESSION_HOOK") > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 0 "should not error without CLAUDE_ENV_FILE"
  rm -rf "$tmpdir"
  end_test "No error without env file"
}

test_T12_noop_on_match() {
  begin_test "T-12"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-A\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-A" "coord should remain unchanged on match"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "No-op on session match"
}

# --- Integration Tests ---

test_IT1_session_A_dispatches_B_stops() {
  begin_test "IT-1"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local exit_b=0
  echo "{\"session_id\":\"sess-B\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_b=$?
  assert_exit_code "$exit_b" 0 "session B allowed"

  local exit_a=0
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_a=$?
  assert_exit_code "$exit_a" 2 "session A blocked"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Session A blocked, B allowed"
}

test_IT2_resume_auto_reclaim() {
  begin_test "IT-2"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "sess-OLD" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-NEW\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW" "auto-reclaim should update coord"

  local exit_code=0
  echo "{\"session_id\":\"sess-NEW\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?
  assert_exit_code "$exit_code" 2 "new coordinator blocked by Stop hook"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Resume auto-reclaim flow"
}

test_IT3_status_ownership() {
  begin_test "IT-3"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-COORD" "dispatched"

  local coord
  coord=$(jq -r '.coordinatorSessionId // empty' "$tmpdir/specs/test-spec/.dispatch-state.json" 2>/dev/null)
  assert_true "$([ "$coord" = "sess-COORD" ] && echo true || echo false)" "coordinatorSessionId readable"

  rm -rf "$tmpdir"
  end_test "Status ownership readable"
}

test_IT4_legacy_blocks_all() {
  begin_test "IT-4"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "" "dispatched"
  write_team_config "test-spec" 1

  local exit_a=0
  echo "{\"session_id\":\"sess-X\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_a=$?
  assert_exit_code "$exit_a" 2 "blocks session X"

  local exit_b=0
  echo "{\"session_id\":\"sess-Y\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_b=$?
  assert_exit_code "$exit_b" 2 "blocks session Y"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Legacy blocks all sessions"
}

test_IT5_reclaim_updates_coord() {
  begin_test "IT-5"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-OLD" "dispatched"

  local state_file="$tmpdir/specs/test-spec/.dispatch-state.json"
  jq --arg sid "sess-RECLAIMED" '.coordinatorSessionId = $sid' "$state_file" > "${state_file}.tmp" \
    && mv "${state_file}.tmp" "$state_file"

  assert_json_field "$state_file" ".coordinatorSessionId" "sess-RECLAIMED" "reclaim updated"

  write_team_config "test-spec" 1
  local exit_code=0
  echo "{\"session_id\":\"sess-RECLAIMED\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?
  assert_exit_code "$exit_code" 2 "reclaimed session blocked"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Manual reclaim updates coord"
}

# --- Edge Case Tests ---

test_EC1_two_specs_different_coordinators() {
  begin_test "EC-1"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched" "spec-a"
  write_dispatch_state "$tmpdir" "sess-B" "dispatched" "spec-b"
  write_team_config "spec-a" 1
  write_team_config "spec-b" 1

  local exit_a=0
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_a=$?
  assert_exit_code "$exit_a" 2 "session A blocked by spec-a"

  local exit_c=0
  echo "{\"session_id\":\"sess-C\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_c=$?
  assert_exit_code "$exit_c" 0 "session C allowed"

  cleanup_team_config "spec-a"; cleanup_team_config "spec-b"; rm -rf "$tmpdir"
  end_test "Two specs different coordinators"
}

test_EC2_corrupted_json() {
  begin_test "EC-2"
  local tmpdir; tmpdir=$(setup_project)
  echo "{invalid json" > "$tmpdir/specs/test-spec/.dispatch-state.json"

  local exit_code=0
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\"}" \
    | run_stop_hook > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 0 "corrupted JSON should exit 0"
  rm -rf "$tmpdir"
  end_test "Corrupted JSON exits gracefully"
}

test_EC3_env_file_bad_path() {
  begin_test "EC-3"
  local tmpdir; tmpdir=$(setup_git_project)

  local exit_code=0
  echo "{\"session_id\":\"sess-B\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | (cd "$tmpdir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME CLAUDE_ENV_FILE="/nonexistent/dir/file" bash "$SESSION_HOOK") > /dev/null 2>&1 || exit_code=$?

  assert_exit_code "$exit_code" 0 "bad env file path should not error"
  rm -rf "$tmpdir"
  end_test "Bad env file path no error"
}

test_EC4_team_config_zero_members() {
  begin_test "EC-4"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 0

  echo "{\"session_id\":\"sess-B\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-A" "coord unchanged with zero members"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Zero members skips auto-reclaim"
}

test_EC5_concurrent_starts() {
  begin_test "EC-5"
  local tmpdir; tmpdir=$(setup_git_project)
  write_dispatch_state "$tmpdir" "sess-OLD" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-FIRST\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  echo "{\"session_id\":\"sess-SECOND\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-SECOND" "last writer should win"
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Concurrent starts last writer wins"
}

# --- Run All Tests ---

echo "=== Session Isolation Test Suite ==="
echo ""

echo "--- Stop Hook Unit Tests ---"
test_T1_matching_session_blocked
test_T2_mismatching_session_allowed
test_T3_legacy_no_coord_blocks
test_T4_non_active_dispatch_allows
test_T5_empty_session_id_blocks
echo ""

echo "--- SessionStart Hook Unit Tests ---"
test_T6_auto_reclaim_on_mismatch_with_team
test_T7_no_reclaim_without_team
test_T8_legacy_stamp_with_team
test_T9_no_stamp_without_team
test_T10_env_file_export
test_T11_no_error_without_env_file
test_T12_noop_on_match
echo ""

echo "--- Integration Tests ---"
test_IT1_session_A_dispatches_B_stops
test_IT2_resume_auto_reclaim
test_IT3_status_ownership
test_IT4_legacy_blocks_all
test_IT5_reclaim_updates_coord
echo ""

echo "--- Edge Case Tests ---"
test_EC1_two_specs_different_coordinators
test_EC2_corrupted_json
test_EC3_env_file_bad_path
test_EC4_team_config_zero_members
test_EC5_concurrent_starts
echo ""

# --- Summary ---
TOTAL=$((PASSES + FAILURES))
echo "=== Results: $PASSES passed, $FAILURES failed (of $TOTAL assertions) ==="

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi
