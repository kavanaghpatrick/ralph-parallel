#!/bin/bash
# Test suite for stop hook JSON decision control and block counter
# Tests dispatch-coordinator.sh (Stop hook) and session-setup.sh (SessionStart hook)
# for the new JSON-based blocking, block counter with safety valve, and heartbeat-gated reclaim.
#
# Usage: bash ralph-parallel/scripts/test_stop_hook.sh
#
# Outputs per-test PASS/FAIL lines for grep-based verification:
#   T-SH1 PASS: Clean block-and-release cycle
#   T-SH2 PASS: Re-block with safety valve

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
  local dir="$1" coord="$2" status="${3:-dispatched}" spec="${4:-test-spec}" dispatched_at="${5:-}"
  mkdir -p "$dir/specs/$spec"
  local coord_field=""
  if [ "$coord" = "null" ]; then
    coord_field='"coordinatorSessionId": null,'
  elif [ -n "$coord" ]; then
    coord_field="\"coordinatorSessionId\": \"$coord\","
  fi
  local dispatched_field=""
  if [ -n "$dispatched_at" ]; then
    dispatched_field="\"dispatchedAt\": \"$dispatched_at\","
  fi
  cat > "$dir/specs/$spec/.dispatch-state.json" <<JSON
{
  ${coord_field}
  ${dispatched_field}
  "status": "${status}",
  "groups": [{"name": "g1"}],
  "completedGroups": []
}
JSON
}

write_dispatch_state_with_heartbeat() {
  local dir="$1" coord="$2" status="${3:-dispatched}" spec="${4:-test-spec}" heartbeat="${5:-}"
  mkdir -p "$dir/specs/$spec"
  local coord_field=""
  if [ -n "$coord" ]; then
    coord_field="\"coordinatorSessionId\": \"$coord\","
  fi
  local heartbeat_field=""
  if [ -n "$heartbeat" ]; then
    heartbeat_field="\"lastHeartbeat\": \"$heartbeat\","
  fi
  cat > "$dir/specs/$spec/.dispatch-state.json" <<JSON
{
  ${coord_field}
  ${heartbeat_field}
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

cleanup_counter_files() {
  rm -f /tmp/ralph-stop-test-spec-* 2>/dev/null || true
  rm -f /tmp/ralph-stop-test-spec- 2>/dev/null || true
  rm -f /tmp/ralph-stop-spec-* 2>/dev/null || true
  rm -f /tmp/tsh12_out1 /tmp/tsh12_out2 /tmp/tsh12_err1 /tmp/tsh12_err2 2>/dev/null || true
}

begin_test() {
  CURRENT_TEST="$1"
  TEST_PASS=true
  cleanup_counter_files
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

# Validate stdout is valid JSON with expected decision and reason substring
assert_stdout_json() {
  local stdout="$1" expected_decision="$2" reason_substring="${3:-}" desc="${4:-}"

  # Check valid JSON
  if ! echo "$stdout" | jq . > /dev/null 2>&1; then
    echo "  ASSERT FAIL: stdout is not valid JSON: '$stdout' ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
    return
  fi

  # Check decision field
  local decision
  decision=$(echo "$stdout" | jq -r '.decision' 2>/dev/null) || decision=""
  if [ "$decision" != "$expected_decision" ]; then
    echo "  ASSERT FAIL: decision='$decision', expected '$expected_decision' ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
    return
  fi
  PASSES=$((PASSES + 1))

  # Check reason substring if provided
  if [ -n "$reason_substring" ]; then
    local reason
    reason=$(echo "$stdout" | jq -r '.reason' 2>/dev/null) || reason=""
    if echo "$reason" | grep -q "$reason_substring"; then
      PASSES=$((PASSES + 1))
    else
      echo "  ASSERT FAIL: reason does not contain '$reason_substring' (got: '$reason') ${desc:+($desc)}" >&2
      FAILURES=$((FAILURES + 1))
      TEST_PASS=false
    fi
  fi
}

# Assert stderr is empty
assert_no_stderr() {
  local stderr="$1" desc="${2:-}"
  if [ -z "$stderr" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "  ASSERT FAIL: stderr is not empty: '$stderr' ${desc:+($desc)}" >&2
    FAILURES=$((FAILURES + 1))
    TEST_PASS=false
  fi
}

# Run stop hook with clean env (no CLAUDE_CODE_* vars)
# Must cd into the tmpdir so git rev-parse fails and falls back to CWD from stdin JSON.
# Usage: echo '{"session_id":"...","cwd":"$tmpdir",...}' | run_stop_hook "$tmpdir"
run_stop_hook() {
  local dir="${1:-/tmp}"
  (cd "$dir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME bash "$STOP_HOOK")
}

# Run session hook with clean env in given directory
run_session_hook() {
  local dir="$1"
  shift
  (cd "$dir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME "$@" bash "$SESSION_HOOK")
}

# --- Test 1 (T-SH1): Clean block-and-release cycle ---

test_TSH1_clean_block_and_release() {
  begin_test "T-SH1"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  # Step 1: Trigger stop hook with TEAM_NAME context (realistic coordinator scenario)
  local stdout stderr exit_code
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash "$STOP_HOOK" 2>/tmp/tsh1_stderr) || true
  exit_code=$?
  stderr=$(cat /tmp/tsh1_stderr 2>/dev/null)

  assert_exit_code "$exit_code" 0 "blocking should exit 0"
  assert_stdout_json "$stdout" "block" "test-spec" "should output JSON block decision"
  assert_no_stderr "$stderr" "no stderr on block"

  # Step 2: Update to terminal status (merged)
  write_dispatch_state "$tmpdir" "sess-A" "merged"

  # Step 3: Trigger stop hook again with TEAM_NAME -- should allow with no output and clean counter
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash "$STOP_HOOK" 2>/tmp/tsh1_stderr2) || true
  exit_code=$?
  stderr=$(cat /tmp/tsh1_stderr2 2>/dev/null)

  assert_exit_code "$exit_code" 0 "terminal status should exit 0"
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "no stdout on allow"
  assert_no_stderr "$stderr" "no stderr on allow"

  # Step 4: Verify counter file cleaned up
  local counter_file="/tmp/ralph-stop-test-spec-sess-A"
  assert_true "$([ ! -f "$counter_file" ] && echo true || echo false)" "counter file cleaned up on terminal status"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir" /tmp/tsh1_stderr /tmp/tsh1_stderr2
  end_test "Clean block-and-release cycle"
}

# --- Test 2 (T-SH2): Re-block with safety valve ---

test_TSH2_reblock_safety_valve() {
  begin_test "T-SH2"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local stdout exit_code

  # Block 1: stop_hook_active=false
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?
  assert_exit_code "$exit_code" 0 "block 1 exit 0"
  assert_stdout_json "$stdout" "block" "" "block 1 JSON"

  # Block 2: stop_hook_active=true (re-block)
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?
  assert_exit_code "$exit_code" 0 "block 2 exit 0"
  assert_stdout_json "$stdout" "block" "block 2/3" "block 2 JSON shows counter"

  # Block 3: stop_hook_active=true (re-block at MAX_BLOCKS)
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?
  assert_exit_code "$exit_code" 0 "block 3 exit 0"
  assert_stdout_json "$stdout" "block" "block 3/3" "block 3 JSON shows counter at max"

  # Block 4: stop_hook_active=true -- should be allowed (safety valve)
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?
  assert_exit_code "$exit_code" 0 "safety valve exit 0"
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "safety valve: no stdout (allow)"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Re-block with safety valve"
}

# --- Test 3 (T-SH3): Block counter reset on new dispatch ---

test_TSH3_counter_reset_new_dispatch() {
  begin_test "T-SH3"
  local tmpdir; tmpdir=$(setup_project)

  # Dispatch A with dispatchedAt=1000
  write_dispatch_state "$tmpdir" "sess-A" "dispatched" "test-spec" "1000"
  write_team_config "test-spec" 1

  local stdout

  # Block twice for dispatch A
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  # Verify counter is at 2
  local counter_file="/tmp/ralph-stop-test-spec-sess-A"
  local count
  count=$(cut -d: -f1 "$counter_file" 2>/dev/null) || count="0"
  assert_true "$([ "$count" = "2" ] && echo true || echo false)" "dispatch A counter should be 2"

  # Abort dispatch A, create dispatch B with different dispatchedAt
  write_dispatch_state "$tmpdir" "sess-A" "dispatched" "test-spec" "2000"

  # Block once for dispatch B -- counter should reset
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true

  assert_stdout_json "$stdout" "block" "" "dispatch B first block"

  # Verify counter reset to 1, not 3
  count=$(cut -d: -f1 "$counter_file" 2>/dev/null) || count="0"
  assert_true "$([ "$count" = "1" ] && echo true || echo false)" "dispatch B counter should be 1 (reset)"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Block counter reset on new dispatch"
}

# --- Test 4 (T-SH4): JSON output validity ---

test_TSH4_json_output_validity() {
  begin_test "T-SH4"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local stdout

  # Scenario 1: Active dispatch, first block
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true

  # Validate JSON parseable by jq
  local valid_json
  valid_json=$(echo "$stdout" | jq -e '.' > /dev/null 2>&1 && echo true || echo false)
  assert_true "$valid_json" "stdout is valid JSON"

  # Validate decision field
  local decision
  decision=$(echo "$stdout" | jq -r '.decision' 2>/dev/null) || decision=""
  assert_true "$([ "$decision" = "block" ] && echo true || echo false)" "decision is block"

  # Validate reason is a string
  local reason_type
  reason_type=$(echo "$stdout" | jq -r '.reason | type' 2>/dev/null) || reason_type=""
  assert_true "$([ "$reason_type" = "string" ] && echo true || echo false)" "reason is a string"

  # Scenario 2: Re-block (stop_hook_active=true)
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true

  valid_json=$(echo "$stdout" | jq -e '.' > /dev/null 2>&1 && echo true || echo false)
  assert_true "$valid_json" "re-block stdout is valid JSON"

  decision=$(echo "$stdout" | jq -r '.decision' 2>/dev/null) || decision=""
  assert_true "$([ "$decision" = "block" ] && echo true || echo false)" "re-block decision is block"

  # Scenario 3: Teammates lost
  cleanup_team_config "test-spec"
  # Re-create dispatch but with team name context (team lost in team-name branch)
  # Must cd into tmpdir so git rev-parse fails and falls back to CWD
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash "$STOP_HOOK" 2>/dev/null) || true

  valid_json=$(echo "$stdout" | jq -e '.' > /dev/null 2>&1 && echo true || echo false)
  assert_true "$valid_json" "team-lost stdout is valid JSON"

  decision=$(echo "$stdout" | jq -r '.decision' 2>/dev/null) || decision=""
  assert_true "$([ "$decision" = "block" ] && echo true || echo false)" "team-lost decision is block"

  local reason
  reason=$(echo "$stdout" | jq -r '.reason' 2>/dev/null) || reason=""
  assert_true "$(echo "$reason" | grep -q 'TEAMMATES LOST' && echo true || echo false)" "team-lost reason mentions TEAMMATES LOST"

  rm -rf "$tmpdir"
  end_test "JSON output validity"
}

# --- Test 5 (T-SH5): Heartbeat write on block ---

test_TSH5_heartbeat_write_on_block() {
  begin_test "T-SH5"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local state_file="$tmpdir/specs/test-spec/.dispatch-state.json"

  # Verify no heartbeat initially
  local has_heartbeat
  has_heartbeat=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_heartbeat="false"
  assert_true "$([ "$has_heartbeat" = "false" ] && echo true || echo false)" "no heartbeat before block"

  # Trigger a block
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  # Verify heartbeat was written
  has_heartbeat=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_heartbeat="false"
  assert_true "$([ "$has_heartbeat" = "true" ] && echo true || echo false)" "heartbeat present after block"

  # Verify heartbeat is a valid ISO 8601 timestamp
  local heartbeat
  heartbeat=$(jq -r '.lastHeartbeat' "$state_file" 2>/dev/null) || heartbeat=""
  assert_true "$(echo "$heartbeat" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo true || echo false)" "heartbeat is valid ISO 8601"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Heartbeat write on block"
}

# --- Test 6 (T-SH6): Heartbeat-gated reclaim ---

test_TSH6_heartbeat_gated_reclaim() {
  begin_test "T-SH6"
  local tmpdir; tmpdir=$(setup_git_project)

  # Scenario A: Recent heartbeat -> skip reclaim
  local recent_ts
  recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  write_dispatch_state_with_heartbeat "$tmpdir" "sess-OLD" "dispatched" "test-spec" "$recent_ts"
  write_team_config "test-spec" 1

  local session_output
  session_output=$(echo "{\"session_id\":\"sess-NEW\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" 2>/dev/null) || true

  # With a recent heartbeat, reclaim should be skipped
  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-OLD" "recent heartbeat: coord should remain unchanged"

  # Scenario B: Stale heartbeat (>10 min) -> reclaim proceeds
  # Use a heartbeat from 15 minutes ago
  local stale_ts
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "2020-01-01T00:00:00Z" "+%s" > /dev/null 2>&1; then
    # macOS (BSD date)
    stale_ts=$(date -u -j -v-15M +%Y-%m-%dT%H:%M:%SZ)
  else
    # GNU date
    stale_ts=$(date -u -d "15 minutes ago" +%Y-%m-%dT%H:%M:%SZ)
  fi
  write_dispatch_state_with_heartbeat "$tmpdir" "sess-OLD2" "dispatched" "test-spec" "$stale_ts"

  echo "{\"session_id\":\"sess-NEW2\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW2" "stale heartbeat: reclaim should proceed"

  # Scenario C: No heartbeat (legacy) -> reclaim proceeds
  write_dispatch_state "$tmpdir" "sess-OLD3" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-NEW3\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW3" "no heartbeat (legacy): reclaim should proceed"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Heartbeat-gated reclaim"
}

# --- Ported tests from test_session_isolation.sh (updated expectations) ---

test_PORT_T1_matching_session_blocks_json() {
  begin_test "T-PORT1"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "matching session exits 0 (not exit 2)"
  assert_stdout_json "$stdout" "block" "" "matching session produces JSON block"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Matching session blocks with JSON (was exit 2)"
}

test_PORT_T3_legacy_no_coord_blocks_json() {
  begin_test "T-PORT3"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "" "dispatched"
  write_team_config "test-spec" 1

  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"sess-B\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "legacy dispatch exits 0 (not exit 2)"
  assert_stdout_json "$stdout" "block" "" "legacy dispatch produces JSON block"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Legacy no coord blocks with JSON (was exit 2)"
}

test_PORT_T5_empty_session_id_blocks_json() {
  begin_test "T-PORT5"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "empty session_id exits 0 (not exit 2)"
  assert_stdout_json "$stdout" "block" "" "empty session_id produces JSON block"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Empty session_id blocks with JSON (was exit 2)"
}

test_PORT_T13_stop_hook_active_reblocks() {
  begin_test "T-PORT13"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  # First block (stop_hook_active=false)
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  # Re-trigger with stop_hook_active=true -- should re-block (not immediately allow)
  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "re-trigger exits 0"
  assert_stdout_json "$stdout" "block" "Still active" "re-trigger blocks with re-block message (not immediate allow)"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "stop_hook_active re-blocks (was immediate allow)"
}

# --- Backward Compat Tests ---

test_TBC1_no_heartbeat_reclaims_normally() {
  begin_test "T-BC1"
  local tmpdir; tmpdir=$(setup_git_project)

  # Dispatch state WITHOUT lastHeartbeat
  write_dispatch_state "$tmpdir" "sess-OLD" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-NEW\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW" "no heartbeat -> reclaim proceeds normally"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "No lastHeartbeat -> reclaims normally (backward compat)"
}

# --- Test 7 (T-SH7): Block counter file missing/corrupt -> treated as count=0 ---

test_TSH7_counter_file_missing_corrupt() {
  begin_test "T-SH7"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local counter_file="/tmp/ralph-stop-test-spec-sess-A"

  # Scenario A: Counter file missing -- should still block (count=0, first block)
  rm -f "$counter_file" 2>/dev/null || true
  local stdout
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  assert_stdout_json "$stdout" "block" "" "missing counter file still blocks"

  # Verify counter file was created with count=1
  local count
  count=$(cut -d: -f1 "$counter_file" 2>/dev/null) || count="0"
  assert_true "$([ "$count" = "1" ] && echo true || echo false)" "counter created at 1 after first block"

  # Scenario B: Counter file corrupt (garbage content)
  echo "GARBAGE_CORRUPT_DATA" > "$counter_file"
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true

  # Corrupt file should be treated as count=0, so this is block 1 (reset)
  assert_stdout_json "$stdout" "block" "" "corrupt counter file still blocks"

  # Scenario C: Counter file empty
  : > "$counter_file"
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  assert_stdout_json "$stdout" "block" "" "empty counter file still blocks"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Block counter file missing/corrupt -> treated as count=0"
}

# --- Test 8 (T-SH8): Block counter survives after safety valve ---

test_TSH8_counter_survives_safety_valve() {
  begin_test "T-SH8"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local counter_file="/tmp/ralph-stop-test-spec-sess-A"
  local stdout

  # Block 1, 2, 3 (reach MAX_BLOCKS)
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  # Block 4: safety valve triggers (allow)
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "safety valve allows (no stdout)"

  # Counter file should still exist (NOT deleted by safety valve)
  assert_true "$([ -f "$counter_file" ] && echo true || echo false)" "counter file survives safety valve"

  # Verify counter is at MAX_BLOCKS (3)
  local count
  count=$(cut -d: -f1 "$counter_file" 2>/dev/null) || count="0"
  assert_true "$([ "$count" = "3" ] && echo true || echo false)" "counter at MAX_BLOCKS=3"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Block counter survives after safety valve"
}

# --- Test 9 (T-SH9): Counter file cleaned up on terminal status ---

test_TSH9_counter_cleanup_terminal_status() {
  begin_test "T-SH9"
  local tmpdir; tmpdir=$(setup_project)
  write_team_config "test-spec" 1

  local counter_file="/tmp/ralph-stop-test-spec-sess-A"

  # Test each terminal status: merged, aborted, stale
  # Must use CLAUDE_CODE_TEAM_NAME so the script takes the team-name branch
  # (not scan mode, which skips non-dispatched states in its scan loop)
  for terminal_status in merged aborted stale; do
    # Setup: create a dispatch, block once to create counter file
    write_dispatch_state "$tmpdir" "sess-A" "dispatched"
    echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
      | (cd "$tmpdir" && env -u CLAUDE_CODE_AGENT_NAME CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash "$STOP_HOOK") > /dev/null 2>&1 || true

    # Verify counter file exists
    assert_true "$([ -f "$counter_file" ] && echo true || echo false)" "counter exists before $terminal_status"

    # Transition to terminal status
    write_dispatch_state "$tmpdir" "sess-A" "$terminal_status"
    echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
      | (cd "$tmpdir" && env -u CLAUDE_CODE_AGENT_NAME CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash "$STOP_HOOK") > /dev/null 2>&1 || true

    # Counter file should be cleaned up
    assert_true "$([ ! -f "$counter_file" ] && echo true || echo false)" "counter cleaned up on $terminal_status"
  done

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Counter file cleaned up on terminal status (merged/aborted/stale)"
}

# --- Test 10 (T-SH10): Empty SESSION_ID -> counter file at /tmp/ralph-stop-SPECNAME- ---

test_TSH10_empty_session_id_counter() {
  begin_test "T-SH10"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  # Counter file for empty session_id: /tmp/ralph-stop-test-spec-
  local counter_file="/tmp/ralph-stop-test-spec-"
  rm -f "$counter_file" 2>/dev/null || true

  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "empty session_id exits 0"
  assert_stdout_json "$stdout" "block" "" "empty session_id blocks"

  # Counter file should be created at the expected path
  assert_true "$([ -f "$counter_file" ] && echo true || echo false)" "counter file created at /tmp/ralph-stop-test-spec-"

  # Verify counter is functional (second block increments)
  echo "{\"session_id\":\"\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true
  local count
  count=$(cut -d: -f1 "$counter_file" 2>/dev/null) || count="0"
  assert_true "$([ "$count" = "2" ] && echo true || echo false)" "empty session_id counter increments to 2"

  rm -f "$counter_file" 2>/dev/null || true
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Empty SESSION_ID -> counter file still works"
}

# --- Test 11 (T-SH11): RALPH_MAX_STOP_BLOCKS env var overrides default 3 ---

test_TSH11_max_blocks_env_override() {
  begin_test "T-SH11"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local stdout

  # Set MAX_BLOCKS to 1 via env var
  # Block 1: should block (first block uses initial message, no counter in reason)
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME RALPH_MAX_STOP_BLOCKS=1 bash "$STOP_HOOK" 2>/dev/null) || true
  assert_stdout_json "$stdout" "block" "test-spec" "block 1 with MAX=1 (blocks on first attempt)"

  # Block 2: safety valve should trigger (allow) because counter is already at 1 = MAX_BLOCKS
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME RALPH_MAX_STOP_BLOCKS=1 bash "$STOP_HOOK" 2>/dev/null) || true
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "safety valve at MAX=1 allows"

  # Reset counter for next sub-test
  cleanup_counter_files

  # Set MAX_BLOCKS to 5 -- block 5 times, then safety valve on 6th
  write_dispatch_state "$tmpdir" "sess-A" "dispatched" "test-spec" "3000"
  for i in 1 2 3 4 5; do
    local active="false"
    [ "$i" -gt 1 ] && active="true"
    stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":$active,\"last_assistant_message\":\"\"}" \
      | env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME RALPH_MAX_STOP_BLOCKS=5 bash "$STOP_HOOK" 2>/dev/null) || true
  done
  # The 5th block should have blocked with "block 5/5"
  assert_stdout_json "$stdout" "block" "block 5/5" "block 5/5 with MAX=5"

  # 6th attempt: safety valve
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME RALPH_MAX_STOP_BLOCKS=5 bash "$STOP_HOOK" 2>/dev/null) || true
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "safety valve at MAX=5 allows"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "RALPH_MAX_STOP_BLOCKS env var overrides default 3"
}

# --- Test 12 (T-SH12): Concurrent stop hook invocations don't crash ---

test_TSH12_concurrent_invocations() {
  begin_test "T-SH12"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  # Run two hook invocations concurrently in background
  local pid1 pid2 exit1 exit2

  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /tmp/tsh12_out1 2>/tmp/tsh12_err1 &
  pid1=$!

  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /tmp/tsh12_out2 2>/tmp/tsh12_err2 &
  pid2=$!

  # Wait for both to complete
  wait $pid1; exit1=$?
  wait $pid2; exit2=$?

  assert_exit_code "$exit1" 0 "concurrent invocation 1 exits 0"
  assert_exit_code "$exit2" 0 "concurrent invocation 2 exits 0"

  # Both should have produced valid JSON block output
  local out1 out2
  out1=$(cat /tmp/tsh12_out1 2>/dev/null) || out1=""
  out2=$(cat /tmp/tsh12_out2 2>/dev/null) || out2=""
  assert_stdout_json "$out1" "block" "" "concurrent 1 produced valid JSON block"
  assert_stdout_json "$out2" "block" "" "concurrent 2 produced valid JSON block"

  # No stderr from either invocation
  local err1 err2
  err1=$(cat /tmp/tsh12_err1 2>/dev/null) || err1=""
  err2=$(cat /tmp/tsh12_err2 2>/dev/null) || err2=""
  assert_no_stderr "$err1" "concurrent 1 no stderr"
  assert_no_stderr "$err2" "concurrent 2 no stderr"

  rm -f /tmp/tsh12_out1 /tmp/tsh12_out2 /tmp/tsh12_err1 /tmp/tsh12_err2
  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Concurrent stop hook invocations don't crash"
}

# --- Test 13 (T-SH13): Heartbeat write uses .tmp.$$ pattern (no orphan .tmp files) ---

test_TSH13_heartbeat_tmp_no_orphans() {
  begin_test "T-SH13"
  local tmpdir; tmpdir=$(setup_project)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  local state_file="$tmpdir/specs/test-spec/.dispatch-state.json"

  # Trigger a block (which writes heartbeat)
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  # Check that no orphan .tmp files remain in the spec dir
  local orphan_count
  orphan_count=$(find "$tmpdir/specs/test-spec" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
  assert_true "$([ "$orphan_count" = "0" ] && echo true || echo false)" "no orphan .tmp files after heartbeat write"

  # Verify the heartbeat was actually written (not lost)
  local has_heartbeat
  has_heartbeat=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_heartbeat="false"
  assert_true "$([ "$has_heartbeat" = "true" ] && echo true || echo false)" "heartbeat present after block"

  # Trigger a second block to double-check no orphans accumulate
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  orphan_count=$(find "$tmpdir/specs/test-spec" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
  assert_true "$([ "$orphan_count" = "0" ] && echo true || echo false)" "no orphan .tmp files after second heartbeat write"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Heartbeat write uses .tmp.$$ pattern (no orphan .tmp files)"
}

# --- Test 14 (T-SH14): RALPH_RECLAIM_THRESHOLD_MINUTES env var overrides default 10 ---

test_TSH14_reclaim_threshold_env_override() {
  begin_test "T-SH14"
  local tmpdir; tmpdir=$(setup_git_project)

  # Create a dispatch with heartbeat 5 minutes ago
  local ts_5min_ago
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "2020-01-01T00:00:00Z" "+%s" > /dev/null 2>&1; then
    ts_5min_ago=$(date -u -j -v-5M +%Y-%m-%dT%H:%M:%SZ)
  else
    ts_5min_ago=$(date -u -d "5 minutes ago" +%Y-%m-%dT%H:%M:%SZ)
  fi
  write_dispatch_state_with_heartbeat "$tmpdir" "sess-OLD" "dispatched" "test-spec" "$ts_5min_ago"
  write_team_config "test-spec" 1

  # Default threshold is 10 min, so 5-min-old heartbeat -> skip reclaim
  echo "{\"session_id\":\"sess-NEW\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-OLD" "default threshold 10: 5min heartbeat -> no reclaim"

  # Now override threshold to 3 minutes -- 5-min-old heartbeat should be stale
  # Restore original dispatch state (reset coordinatorSessionId in case it was changed)
  write_dispatch_state_with_heartbeat "$tmpdir" "sess-OLD" "dispatched" "test-spec" "$ts_5min_ago"

  echo "{\"session_id\":\"sess-NEW2\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | (cd "$tmpdir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME RALPH_RECLAIM_THRESHOLD_MINUTES=3 bash "$SESSION_HOOK") > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW2" "threshold=3: 5min heartbeat -> reclaim proceeds"

  # Override threshold to 60 minutes -- 5-min-old heartbeat should be fresh
  write_dispatch_state_with_heartbeat "$tmpdir" "sess-OLD2" "dispatched" "test-spec" "$ts_5min_ago"

  echo "{\"session_id\":\"sess-NEW3\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | (cd "$tmpdir" && env -u CLAUDE_CODE_AGENT_NAME -u CLAUDE_CODE_TEAM_NAME RALPH_RECLAIM_THRESHOLD_MINUTES=60 bash "$SESSION_HOOK") > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-OLD2" "threshold=60: 5min heartbeat -> no reclaim"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "RALPH_RECLAIM_THRESHOLD_MINUTES env var overrides default 10"
}

# --- Test 15 (T-SH15): Heartbeat written only on block, NOT on allow ---

test_TSH15_heartbeat_only_on_block() {
  begin_test "T-SH15"
  local tmpdir; tmpdir=$(setup_project)
  write_team_config "test-spec" 1

  local state_file="$tmpdir/specs/test-spec/.dispatch-state.json"

  # Scenario A: Terminal status (merged) -> allow stop, no heartbeat update
  write_dispatch_state "$tmpdir" "sess-A" "merged"

  # Record the initial state (no heartbeat)
  local has_heartbeat_before
  has_heartbeat_before=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_heartbeat_before="false"
  assert_true "$([ "$has_heartbeat_before" = "false" ] && echo true || echo false)" "no heartbeat before allow (merged)"

  # Trigger stop hook (should allow, not block, and NOT write heartbeat)
  local stdout
  stdout=$(cd "$tmpdir" && echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | env -u CLAUDE_CODE_AGENT_NAME CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash "$STOP_HOOK" 2>/dev/null) || true

  # Verify no stdout (allow)
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "terminal status produces allow (no stdout)"

  # Verify no heartbeat was written
  local has_heartbeat_after
  has_heartbeat_after=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_heartbeat_after="false"
  assert_true "$([ "$has_heartbeat_after" = "false" ] && echo true || echo false)" "no heartbeat after allow (merged)"

  # Scenario B: Safety valve (exceed MAX_BLOCKS) -> allow, no heartbeat update
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"

  # Block 3 times (reach MAX_BLOCKS=3) then check 4th (safety valve)
  for i in 1 2 3; do
    local active="false"
    [ "$i" -gt 1 ] && active="true"
    echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":$active,\"last_assistant_message\":\"\"}" \
      | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true
  done

  # Record heartbeat timestamp after the 3rd block
  local hb_before_valve
  hb_before_valve=$(jq -r '.lastHeartbeat // "none"' "$state_file" 2>/dev/null) || hb_before_valve="none"

  # Small delay to ensure any new heartbeat would have a different timestamp
  sleep 1

  # 4th attempt: safety valve (allow)
  stdout=$(echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":true,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "safety valve produces allow (no stdout)"

  # Heartbeat should NOT have been updated during safety valve allow
  local hb_after_valve
  hb_after_valve=$(jq -r '.lastHeartbeat // "none"' "$state_file" 2>/dev/null) || hb_after_valve="none"
  assert_true "$([ "$hb_before_valve" = "$hb_after_valve" ] && echo true || echo false)" "heartbeat unchanged after safety valve allow"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Heartbeat written only on block, NOT on allow"
}

# --- Test 16 (T-SH16): Concurrent sessions: heartbeat < 10min -> B skips reclaim ---

test_TSH16_concurrent_sessions_skip_reclaim() {
  begin_test "T-SH16"
  local tmpdir; tmpdir=$(setup_git_project)

  # Session A dispatches and blocks (creating fresh heartbeat)
  write_dispatch_state "$tmpdir" "sess-A" "dispatched"
  write_team_config "test-spec" 1

  # Trigger stop hook as session A to write a fresh heartbeat
  echo "{\"session_id\":\"sess-A\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" > /dev/null 2>&1 || true

  # Verify heartbeat was written by session A
  local state_file="$tmpdir/specs/test-spec/.dispatch-state.json"
  local has_heartbeat
  has_heartbeat=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_heartbeat="false"
  assert_true "$([ "$has_heartbeat" = "true" ] && echo true || echo false)" "session A wrote heartbeat"

  # Session B starts (different session_id) -- should NOT reclaim because heartbeat is fresh
  echo "{\"session_id\":\"sess-B\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  # coordinatorSessionId should still be sess-A (no reclaim)
  assert_json_field "$state_file" \
    ".coordinatorSessionId" "sess-A" "session B skips reclaim (heartbeat fresh)"

  # Session B's stop hook should NOT block (session mismatch in scan mode)
  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"sess-B\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?
  assert_exit_code "$exit_code" 0 "session B stop hook exits 0"
  assert_true "$([ -z "$stdout" ] && echo true || echo false)" "session B stop hook allows (session mismatch)"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Concurrent sessions: heartbeat < 10min -> B skips reclaim"
}

# --- Test 17 (T-SH17): Legacy dispatch (no lastHeartbeat, no coordinatorSessionId) ---

test_TSH17_legacy_dispatch_both_hooks() {
  begin_test "T-SH17"
  local tmpdir; tmpdir=$(setup_git_project)

  # Create a legacy dispatch state: no coordinatorSessionId, no lastHeartbeat
  mkdir -p "$tmpdir/specs/test-spec"
  cat > "$tmpdir/specs/test-spec/.dispatch-state.json" <<JSON
{
  "status": "dispatched",
  "groups": [{"name": "g1"}, {"name": "g2"}],
  "completedGroups": ["g1"]
}
JSON
  write_team_config "test-spec" 1

  local state_file="$tmpdir/specs/test-spec/.dispatch-state.json"

  # Verify no coordinatorSessionId and no lastHeartbeat
  local has_coord has_hb
  has_coord=$(jq 'has("coordinatorSessionId")' "$state_file" 2>/dev/null) || has_coord="true"
  has_hb=$(jq 'has("lastHeartbeat")' "$state_file" 2>/dev/null) || has_hb="true"
  assert_true "$([ "$has_coord" = "false" ] && echo true || echo false)" "legacy: no coordinatorSessionId"
  assert_true "$([ "$has_hb" = "false" ] && echo true || echo false)" "legacy: no lastHeartbeat"

  # Session-setup hook: should stamp coordinatorSessionId (legacy stamp path)
  echo "{\"session_id\":\"sess-LEGACY\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$state_file" \
    ".coordinatorSessionId" "sess-LEGACY" "session-setup stamps legacy dispatch"

  # Stop hook: should block (active dispatch with team alive)
  # Reset to pure legacy state for stop hook test
  cat > "$state_file" <<JSON
{
  "status": "dispatched",
  "groups": [{"name": "g1"}, {"name": "g2"}],
  "completedGroups": ["g1"]
}
JSON

  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"sess-LEGACY\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "legacy stop hook exits 0"
  assert_stdout_json "$stdout" "block" "test-spec" "legacy dispatch blocks with JSON"
  # Reason should show correct progress (1/2 groups done)
  local reason
  reason=$(echo "$stdout" | jq -r '.reason' 2>/dev/null) || reason=""
  assert_true "$(echo "$reason" | grep -q '1/2' && echo true || echo false)" "legacy reason shows 1/2 groups done"

  # Now test reclaim path: new session reclaims legacy dispatch (no heartbeat = stale)
  # Re-create legacy state with the stamped coord from a previous session
  cat > "$state_file" <<JSON
{
  "coordinatorSessionId": "sess-OLD-LEGACY",
  "status": "dispatched",
  "groups": [{"name": "g1"}, {"name": "g2"}],
  "completedGroups": ["g1"]
}
JSON

  echo "{\"session_id\":\"sess-NEW-LEGACY\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$state_file" \
    ".coordinatorSessionId" "sess-NEW-LEGACY" "legacy dispatch (no heartbeat) reclaimed by new session"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "Legacy dispatch (no lastHeartbeat, no coordinatorSessionId) -> both hooks work"
}

# --- Backward Compat Tests ---

test_TBC1_no_heartbeat_reclaims_normally() {
  begin_test "T-BC1"
  local tmpdir; tmpdir=$(setup_git_project)

  # Dispatch state WITHOUT lastHeartbeat
  write_dispatch_state "$tmpdir" "sess-OLD" "dispatched"
  write_team_config "test-spec" 1

  echo "{\"session_id\":\"sess-NEW\",\"source\":\"resume\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW" "no heartbeat -> reclaim proceeds normally"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "No lastHeartbeat -> reclaims normally (backward compat)"
}

test_TBC2_no_coordinator_session_id() {
  begin_test "T-BC2"
  local tmpdir; tmpdir=$(setup_git_project)

  # Dispatch state WITHOUT coordinatorSessionId
  write_dispatch_state "$tmpdir" "" "dispatched"
  write_team_config "test-spec" 1

  # Session-setup should stamp the session ID (legacy stamp path)
  echo "{\"session_id\":\"sess-NEW\",\"source\":\"startup\",\"cwd\":\"$tmpdir\"}" \
    | run_session_hook "$tmpdir" > /dev/null 2>&1

  assert_json_field "$tmpdir/specs/test-spec/.dispatch-state.json" \
    ".coordinatorSessionId" "sess-NEW" "no coord field -> session stamped (legacy path)"

  # Stop hook should block (legacy dispatch with team = live)
  local stdout exit_code
  stdout=$(echo "{\"session_id\":\"sess-NEW\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false,\"last_assistant_message\":\"\"}" \
    | run_stop_hook "$tmpdir" 2>/dev/null) || true
  exit_code=$?

  assert_exit_code "$exit_code" 0 "stop hook exits 0"
  assert_stdout_json "$stdout" "block" "" "legacy dispatch blocks with JSON"

  cleanup_team_config "test-spec"; rm -rf "$tmpdir"
  end_test "No coordinatorSessionId -> same behavior (backward compat)"
}

# --- Run All Tests ---

echo "=== Stop Hook JSON Decision Control Test Suite ==="
echo ""

echo "--- Design Scenario Tests ---"
test_TSH1_clean_block_and_release
test_TSH2_reblock_safety_valve
test_TSH3_counter_reset_new_dispatch
test_TSH4_json_output_validity
test_TSH5_heartbeat_write_on_block
test_TSH6_heartbeat_gated_reclaim
echo ""

echo "--- Edge Case Tests (Block Counter) ---"
test_TSH7_counter_file_missing_corrupt
test_TSH8_counter_survives_safety_valve
test_TSH9_counter_cleanup_terminal_status
test_TSH10_empty_session_id_counter
test_TSH11_max_blocks_env_override
test_TSH12_concurrent_invocations
echo ""

echo "--- Edge Case Tests (Heartbeat & Reclaim) ---"
test_TSH13_heartbeat_tmp_no_orphans
test_TSH14_reclaim_threshold_env_override
test_TSH15_heartbeat_only_on_block
test_TSH16_concurrent_sessions_skip_reclaim
test_TSH17_legacy_dispatch_both_hooks
echo ""

echo "--- Ported Tests (updated expectations) ---"
test_PORT_T1_matching_session_blocks_json
test_PORT_T3_legacy_no_coord_blocks_json
test_PORT_T5_empty_session_id_blocks_json
test_PORT_T13_stop_hook_active_reblocks
echo ""

echo "--- Backward Compatibility Tests ---"
test_TBC1_no_heartbeat_reclaims_normally
test_TBC2_no_coordinator_session_id
echo ""

# --- Cleanup ---
cleanup_counter_files

# --- Summary ---
TOTAL=$((PASSES + FAILURES))
echo "=== Results: $PASSES passed, $FAILURES failed (of $TOTAL assertions) ==="

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi
