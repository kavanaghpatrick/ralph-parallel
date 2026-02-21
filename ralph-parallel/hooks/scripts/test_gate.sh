#!/bin/bash
# Integration tests for task-completed-gate.sh
set -euo pipefail

GATE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/task-completed-gate.sh"
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

  # Set up minimal spec dir structure
  mkdir -p "$tmpdir/specs/test-spec"

  # Let test setup function populate files
  "$@" "$tmpdir"

  # Build input JSON
  local input
  input=$(cat <<JSON
{"task_id":"1","task_subject":"1.1 Test task","team_name":"test-spec-parallel","cwd":"$tmpdir"}
JSON
  )

  local stderr_file="$tmpdir/stderr.txt"
  local exit_code=0
  echo "$input" | bash "$GATE_SCRIPT" 2>"$stderr_file" || exit_code=$?

  if [ "$exit_code" -ne "$expected_exit" ]; then
    echo "FAIL: $name — expected exit $expected_exit, got $exit_code"
    cat "$stderr_file"
    FAIL=$((FAIL + 1))
    return
  fi

  if [ -n "$check_stderr" ]; then
    if ! grep -q "$check_stderr" "$stderr_file" 2>/dev/null; then
      echo "FAIL: $name — expected '$check_stderr' in stderr"
      cat "$stderr_file"
      FAIL=$((FAIL + 1))
      return
    fi
  fi

  echo "PASS: $name"
  PASS=$((PASS + 1))
}

# ── Test setup functions ──────────────────────────────────────

setup_verify_fail() {
  local dir="$1"
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [ ] 1.1 Test task
  - **Verify**: `false`
EOF
}

setup_verify_pass() {
  local dir="$1"
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [ ] 1.1 Test task
  - **Verify**: `true`
EOF
}

setup_typecheck_pass() {
  local dir="$1"
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [ ] 1.1 Test task
  - **Verify**: `true`
EOF
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","qualityCommands":{"typecheck":"true"}}
EOF
}

setup_typecheck_fail() {
  local dir="$1"
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [ ] 1.1 Test task
  - **Verify**: `true`
EOF
  cat > "$dir/specs/test-spec/.dispatch-state.json" <<'EOF'
{"status":"dispatched","qualityCommands":{"typecheck":"false"}}
EOF
}

setup_file_exist_pass() {
  local dir="$1"
  touch "$dir/existing-file.ts"
  cat > "$dir/specs/test-spec/tasks.md" <<EOF
- [ ] 1.1 Test task
  - **Files**: existing-file.ts
  - **Verify**: \`true\`
EOF
}

setup_file_exist_fail() {
  local dir="$1"
  cat > "$dir/specs/test-spec/tasks.md" <<EOF
- [ ] 1.1 Test task
  - **Files**: nonexistent-file.ts
  - **Verify**: \`true\`
EOF
}

setup_no_dispatch_state() {
  local dir="$1"
  cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
- [ ] 1.1 Test task
  - **Verify**: `true`
EOF
  # No .dispatch-state.json — backward compat test
}

# ── Run tests ─────────────────────────────────────────────────

run_test "verify output on failure"       2  "QUALITY GATE FAILED"    setup_verify_fail
run_test "verify success"                 0  ""                        setup_verify_pass
run_test "supplemental typecheck pass"    0  ""                        setup_typecheck_pass
run_test "supplemental typecheck fail"    2  "SUPPLEMENTAL CHECK FAILED" setup_typecheck_fail
run_test "file existence pass"            0  ""                        setup_file_exist_pass
run_test "file existence fail"            2  "Missing files"           setup_file_exist_fail
run_test "backward compat (no state)"     0  ""                        setup_no_dispatch_state

# ── Summary ───────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
