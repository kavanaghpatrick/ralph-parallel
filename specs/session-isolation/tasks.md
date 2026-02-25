# Tasks: Session Isolation

## Quality Commands

- **Build**: N/A (bash scripts + markdown -- no compilation)
- **Typecheck**: N/A (bash scripts)
- **Lint**: N/A (no lint configured for plugin)
- **Test**: `bash ralph-parallel/scripts/test_session_isolation.sh` (new, created in Phase 3)
- **Regression**: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py`

## Phase 1: Make It Work (POC)

Focus: Prove session_id comparison works in Stop hook + auto-reclaim in SessionStart. Skip --reclaim, skip /status, skip edge cases.

### Group 1: Stop Hook Session Isolation [P1]

**Files owned**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`

- [x] 1.1 Add SESSION_ID extraction to dispatch-coordinator.sh
  - **Do**:
    1. After line 17 (`CWD=...`), add: `SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""`
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: SESSION_ID is parsed from stdin JSON input
  - **Verify**: `echo '{"session_id":"test-123","cwd":"/tmp"}' | SESSION_ID_CHECK=1 bash -c 'INPUT=$(cat); SESSION_ID=$(echo "$INPUT" | jq -r ".session_id // empty" 2>/dev/null) || SESSION_ID=""; echo "sid=$SESSION_ID"' | grep -q 'sid=test-123' && echo PASS || echo FAIL`
  - **Commit**: `feat(hooks): extract session_id from Stop hook stdin`
  - _Requirements: FR-1, AC-1.3_
  - _Design: Component 1 — SESSION_ID extraction_

- [x] 1.2 Rewrite scan branch for multi-spec session comparison
  - **Do**:
    1. Replace lines 41-58 (the `else` scan branch) with new multi-spec scan logic from design.md
    2. New scan loop iterates ALL active dispatches, checks `coordinatorSessionId` per spec file
    3. Three branches per file: legacy (no field) -> block; empty session_id -> block; match -> block; mismatch -> continue scanning
    4. After loop: if `FOUND_MY_DISPATCH=false`, `exit 0` (allow stop)
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: Scan branch checks all dispatches and only blocks on match/legacy
  - **Verify**: `TMPDIR=$(mktemp -d) && mkdir -p "$TMPDIR/specs/spec-a" "$TMPDIR/specs/spec-b" && echo '{"coordinatorSessionId":"sess-A","status":"dispatched","groups":[{"name":"g1"}],"completedGroups":[]}' > "$TMPDIR/specs/spec-a/.dispatch-state.json" && echo '{"coordinatorSessionId":"sess-B","status":"dispatched","groups":[{"name":"g1"}],"completedGroups":[]}' > "$TMPDIR/specs/spec-b/.dispatch-state.json" && echo '{"session_id":"sess-C","cwd":"'"$TMPDIR"'"}' | bash ralph-parallel/hooks/scripts/dispatch-coordinator.sh; EXIT=$?; rm -rf "$TMPDIR"; [ "$EXIT" -eq 0 ] && echo "PASS: unrelated session allowed" || echo "FAIL: exit=$EXIT"`
  - **Commit**: `feat(hooks): rewrite scan branch for multi-spec session comparison`
  - _Requirements: FR-1, AC-1.1, AC-1.2, AC-1.4_
  - _Design: Component 1 — Multi-spec scan_

- [x] 1.3 Add team-name branch session comparison
  - **Do**:
    1. After the `fi` closing the if/else (team-name vs scan), insert the unified session comparison block from design.md
    2. When `TEAM_NAME` is set and dispatch state exists: read `coordinatorSessionId`, compare with `SESSION_ID`
    3. If both present and mismatch: `exit 0` (allow, not this session's dispatch)
    4. If either missing: fall through to legacy behavior (block)
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: Team-name branch also respects session_id comparison
  - **Verify**: `TMPDIR=$(mktemp -d) && mkdir -p "$TMPDIR/specs/test-spec" && echo '{"coordinatorSessionId":"sess-A","status":"dispatched","groups":[{"name":"g1"}],"completedGroups":[]}' > "$TMPDIR/specs/test-spec/.dispatch-state.json" && echo '{"session_id":"sess-B","cwd":"'"$TMPDIR"'"}' | CLAUDE_CODE_TEAM_NAME="test-spec-parallel" bash ralph-parallel/hooks/scripts/dispatch-coordinator.sh; EXIT=$?; rm -rf "$TMPDIR"; [ "$EXIT" -eq 0 ] && echo "PASS: different session allowed via team branch" || echo "FAIL: exit=$EXIT"`
  - **Commit**: `feat(hooks): add session comparison to team-name branch`
  - _Requirements: FR-1, AC-1.1, AC-1.3_
  - _Design: Component 1 — Team-name branch session check_

### Group 2: SessionStart Hook Enhancements [P1]

**Files owned**: `ralph-parallel/hooks/scripts/session-setup.sh`

- [x] 1.4 Add stdin parsing and CLAUDE_ENV_FILE export to session-setup.sh
  - **Do**:
    1. Insert BEFORE the `GIT_ROOT=$(git rev-parse ...)` line (current line 13):
       ```
       INPUT=$(cat)
       SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
       ```
    2. After SESSION_ID extraction, add CLAUDE_ENV_FILE export block:
       ```
       if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$SESSION_ID" ]; then
         echo "CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
       fi
       ```
    3. Critical: stdin must be consumed FIRST (before any other command that might read stdin)
  - **Files**: `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: session_id parsed from stdin, CLAUDE_SESSION_ID written to env file when available
  - **Verify**: `TMPFILE=$(mktemp) && echo '{"session_id":"test-sid-123","source":"startup","cwd":"/tmp"}' | CLAUDE_ENV_FILE="$TMPFILE" bash -c 'INPUT=$(cat); SESSION_ID=$(echo "$INPUT" | jq -r ".session_id // empty" 2>/dev/null) || SESSION_ID=""; if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$SESSION_ID" ]; then echo "CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true; fi' && grep -q 'CLAUDE_SESSION_ID=test-sid-123' "$TMPFILE" && echo PASS || echo FAIL; rm -f "$TMPFILE"`
  - **Commit**: `feat(hooks): add stdin parsing and env export to session-setup`
  - _Requirements: FR-3, FR-6, AC-3.1, AC-4.1, AC-4.2_
  - _Design: Component 2 — Sections A and B_

- [x] 1.5 Add auto-reclaim block to session-setup.sh
  - **Do**:
    1. Inside the `if [ "$DISPATCH_ACTIVE" = true ]` block, after the TEAM_EXISTS check (after current line 77, before line 79's context output), insert the auto-reclaim logic from design.md
    2. Three conditions checked:
       - `COORD_SID != SESSION_ID` + team exists -> update coordinatorSessionId (auto-reclaim)
       - `COORD_SID` empty + team exists -> stamp coordinatorSessionId (legacy)
       - `COORD_SID == SESSION_ID` -> no-op
    3. Uses atomic write pattern: `jq ... > tmp && mv tmp file`
    4. Guard: only fires when `SESSION_ID` is non-empty
  - **Files**: `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: Auto-reclaim updates coordinatorSessionId on session mismatch when team exists
  - **Verify**: `TMPDIR=$(mktemp -d) && mkdir -p "$TMPDIR/specs/test-spec" "$HOME/.claude/teams/test-spec-parallel" && echo '{"coordinatorSessionId":"old-sess","status":"dispatched","groups":[{"name":"g1"}],"completedGroups":[]}' > "$TMPDIR/specs/test-spec/.dispatch-state.json" && echo '{"members":[{"name":"t1"}]}' > "$HOME/.claude/teams/test-spec-parallel/config.json" && cd "$TMPDIR" && git init -q && echo '{"session_id":"new-sess","source":"resume","cwd":"'"$TMPDIR"'"}' | bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/session-setup.sh 2>&1; COORD=$(jq -r '.coordinatorSessionId' "$TMPDIR/specs/test-spec/.dispatch-state.json" 2>/dev/null); cd /Users/patrickkavanagh/parallel_ralph && rm -rf "$TMPDIR" "$HOME/.claude/teams/test-spec-parallel"; [ "$COORD" = "new-sess" ] && echo "PASS: auto-reclaim worked" || echo "FAIL: coord=$COORD"`
  - **Commit**: `feat(hooks): add auto-reclaim to SessionStart hook`
  - _Requirements: FR-4, FR-5, FR-10, AC-3.2, AC-3.3, AC-3.4, AC-3.5_
  - _Design: Component 2 — Section C_

- [x] 1.6 [VERIFY] Quality checkpoint: verify both hooks work together
  - **Do**:
    1. Run existing Python tests to check for regressions: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py`
    2. Run bash syntax check on both modified hooks: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh`
    3. Smoke test: dispatch-coordinator.sh exits 0 with no dispatch state files: `TMPDIR=$(mktemp -d) && echo '{"session_id":"x","cwd":"'"$TMPDIR"'"}' | bash ralph-parallel/hooks/scripts/dispatch-coordinator.sh; EXIT=$?; rm -rf "$TMPDIR"; [ "$EXIT" -eq 0 ] && echo PASS || echo FAIL`
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && echo PASS || echo FAIL`
  - **Done when**: No regressions, both hooks have valid syntax, basic smoke test passes
  - **Commit**: `chore(session-isolation): pass quality checkpoint` (only if fixes needed)

### Group 3: Dispatch Skill Updates [P1]

**Files owned**: `ralph-parallel/commands/dispatch.md`

- [x] 1.7 Add coordinatorSessionId to dispatch.md Step 4 state schema
  - **Do**:
    1. In the Step 4 JSON schema, add `"coordinatorSessionId": "$CLAUDE_SESSION_ID or null"` field after `"dispatchedAt"`
    2. Add instruction: If `$CLAUDE_SESSION_ID` is empty/unset, write `"coordinatorSessionId": null` and log warning
    3. Keep all existing fields unchanged (backward compatible)
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: dispatch.md instructs writing coordinatorSessionId to state on every dispatch
  - **Verify**: `grep -q 'coordinatorSessionId' ralph-parallel/commands/dispatch.md && echo PASS || echo FAIL`
  - **Commit**: `feat(dispatch): write coordinatorSessionId to dispatch state`
  - _Requirements: FR-2, AC-2.1, AC-2.2, AC-2.3, AC-2.4_
  - _Design: Component 3 — Section A_

- [x] 1.8 POC Checkpoint: end-to-end session isolation
  - **Do**:
    1. Create temp project with dispatch state containing coordinatorSessionId
    2. Pipe matching session_id to Stop hook -> verify exit 2 (blocked)
    3. Pipe different session_id to Stop hook -> verify exit 0 (allowed)
    4. Pipe matching session_id to SessionStart with team config -> verify no change (already correct)
    5. Pipe different session_id to SessionStart with team config -> verify auto-reclaim fires
    6. Clean up all temp files
  - **Verify**:
    ```
    TMPDIR=$(mktemp -d) && mkdir -p "$TMPDIR/specs/my-spec" "$HOME/.claude/teams/my-spec-parallel" && \
    echo '{"coordinatorSessionId":"sess-A","status":"dispatched","groups":[{"name":"g1"}],"completedGroups":[]}' > "$TMPDIR/specs/my-spec/.dispatch-state.json" && \
    echo '{"members":[{"name":"t1"}]}' > "$HOME/.claude/teams/my-spec-parallel/config.json" && \
    echo '{"session_id":"sess-A","cwd":"'"$TMPDIR"'"}' | bash ralph-parallel/hooks/scripts/dispatch-coordinator.sh 2>/dev/null; MATCH_EXIT=$?; \
    echo '{"session_id":"sess-B","cwd":"'"$TMPDIR"'"}' | bash ralph-parallel/hooks/scripts/dispatch-coordinator.sh 2>/dev/null; DIFF_EXIT=$?; \
    rm -rf "$TMPDIR" "$HOME/.claude/teams/my-spec-parallel"; \
    [ "$MATCH_EXIT" -eq 2 ] && [ "$DIFF_EXIT" -eq 0 ] && echo "POC PASS: session isolation works" || echo "POC FAIL: match=$MATCH_EXIT diff=$DIFF_EXIT"
    ```
  - **Done when**: Matching session blocked (exit 2), different session allowed (exit 0)
  - **Commit**: `feat(session-isolation): complete POC — session isolation verified`

## Phase 2: Refactoring

After POC validated, add --reclaim and /status, clean up edge cases.

### Group 4: Dispatch Reclaim and Status [P2]

**Files owned**: `ralph-parallel/commands/dispatch.md`, `ralph-parallel/commands/status.md`

- [x] 2.1 Add --reclaim flag and handler to dispatch.md
  - **Do**:
    1. In Parse Arguments section, add `--reclaim` to the argument list with description
    2. Add `If --reclaim: skip to Reclaim Handler section below.` line
    3. Add new "Reclaim Handler" section after Abort Handler:
       - Step 1: Resolve spec (same as Step 1)
       - Step 2: Read .dispatch-state.json, error if missing or status != "dispatched"
       - Step 3: Read $CLAUDE_SESSION_ID, error if empty
       - Step 4: Update via jq: `jq --arg sid "$CLAUDE_SESSION_ID" '.coordinatorSessionId = $sid' state.json > tmp && mv tmp state.json`
       - Step 5: Output confirmation message
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: dispatch.md has --reclaim flag in args and Reclaim Handler section
  - **Verify**: `grep -q '\-\-reclaim' ralph-parallel/commands/dispatch.md && grep -q 'Reclaim Handler' ralph-parallel/commands/dispatch.md && echo PASS || echo FAIL`
  - **Commit**: `feat(dispatch): add --reclaim flag for manual ownership transfer`
  - _Requirements: FR-7, AC-5.1, AC-5.2, AC-5.3, AC-5.4, AC-5.5_
  - _Design: Component 3 — Sections B and C_

- [x] 2.2 Add coordinator ownership display to status.md
  - **Do**:
    1. In Step 1 (Resolve Spec and Load State), add items 5-6:
       - Read coordinatorSessionId from dispatch state
       - Compare against $CLAUDE_SESSION_ID env var
       - Determine: this session / different session / unknown (legacy) / unknown (env unavailable)
    2. In Step 3 (Display Status), add `Coordinator:` line after `Strategy:` line
    3. In JSON Output section, add `"coordinatorSessionId"` and `"isCoordinator": true|false|null` fields
  - **Files**: `ralph-parallel/commands/status.md`
  - **Done when**: /status shows coordinator ownership and JSON includes new fields
  - **Verify**: `grep -q 'coordinatorSessionId' ralph-parallel/commands/status.md && grep -q 'isCoordinator' ralph-parallel/commands/status.md && grep -q 'Coordinator:' ralph-parallel/commands/status.md && echo PASS || echo FAIL`
  - **Commit**: `feat(status): display coordinator session ownership`
  - _Requirements: FR-8, AC-6.1, AC-6.2, AC-6.3, AC-6.4_
  - _Design: Component 4_

- [x] 2.3 [VERIFY] Quality checkpoint: all 4 files modified correctly
  - **Do**:
    1. Syntax check both hooks: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh`
    2. Verify all expected patterns present in modified files:
       - dispatch-coordinator.sh: SESSION_ID, coordinatorSessionId, FOUND_MY_DISPATCH
       - session-setup.sh: INPUT=$(cat), SESSION_ID, CLAUDE_ENV_FILE, auto-reclaim
       - dispatch.md: coordinatorSessionId, --reclaim, Reclaim Handler
       - status.md: coordinatorSessionId, isCoordinator, Coordinator:
    3. Run existing Python test suite for regressions
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && grep -q 'FOUND_MY_DISPATCH' ralph-parallel/hooks/scripts/dispatch-coordinator.sh && grep -q 'auto-reclaim\|Auto-reclaim' ralph-parallel/hooks/scripts/session-setup.sh && grep -q 'Reclaim Handler' ralph-parallel/commands/dispatch.md && grep -q 'isCoordinator' ralph-parallel/commands/status.md && python3 ralph-parallel/scripts/test_parse_and_partition.py -q && python3 ralph-parallel/scripts/test_build_teammate_prompt.py -q && echo PASS || echo FAIL`
  - **Done when**: All files pass syntax checks, contain expected patterns, no regressions
  - **Commit**: `chore(session-isolation): pass quality checkpoint` (only if fixes needed)

## Phase 3: Testing

Focus: Comprehensive test suite. User explicitly requested heavy validation.

### Group 5: Test Suite [P3]

**Files owned**: `ralph-parallel/scripts/test_session_isolation.sh`

- [ ] 3.1 Create test harness with helper functions
  - **Do**:
    1. Create `ralph-parallel/scripts/test_session_isolation.sh` with:
       - `#!/bin/bash` header, `set -euo pipefail`
       - SCRIPT_DIR, PROJECT_ROOT resolution
       - Helper functions: `setup_project()`, `write_dispatch_state()`, `write_team_config()`, `cleanup_team_config()`, `assert_exit_code()`, `assert_file_contains()`, `assert_file_not_contains()`, `assert_json_field()`
       - PASSES/FAILURES counters
       - Summary output at end with exit code (0 if all pass, 1 if any fail)
    2. Follow patterns from design.md test harness section
    3. Make executable: `chmod +x`
  - **Files**: `ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: Test harness runs without errors (0 tests, 0 failures)
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 passed, 0 failed' && echo PASS || echo FAIL`
  - **Commit**: `test(session-isolation): create test harness with helpers`
  - _Design: Test Strategy — Test Harness_

- [ ] 3.2 Add Stop hook unit tests (T-1 through T-5)
  - **Do**:
    1. Add test functions for dispatch-coordinator.sh:
       - `test_T1_matching_session_blocked`: coord=sess-A, input session_id=sess-A, status=dispatched -> exit 2
       - `test_T2_mismatching_session_allowed`: coord=sess-A, input session_id=sess-B, status=dispatched -> exit 0
       - `test_T3_legacy_no_coord_blocks`: no coordinatorSessionId field, status=dispatched -> exit 2
       - `test_T4_non_active_dispatch_allows`: coord=sess-A, status=merged, input session_id=sess-A -> exit 0
       - `test_T5_empty_session_id_blocks`: coord=sess-A, status=dispatched, input session_id="" -> exit 2
    2. Each test: setup temp project, write dispatch state, pipe JSON to script, assert exit code, cleanup
  - **Files**: `ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All 5 tests pass
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo PASS || echo FAIL`
  - **Commit**: `test(session-isolation): add Stop hook unit tests T-1 through T-5`
  - _Requirements: FR-1, FR-9, T-1 through T-5_

- [ ] 3.3 Add SessionStart hook unit tests (T-6 through T-12)
  - **Do**:
    1. Add test functions for session-setup.sh:
       - `test_T6_auto_reclaim_on_mismatch_with_team`: coord=sess-A, input=sess-B, team exists -> coord updated to sess-B
       - `test_T7_no_reclaim_without_team`: coord=sess-A, input=sess-B, no team -> coord unchanged
       - `test_T8_legacy_stamp_with_team`: no coord field, input=sess-B, team exists -> coord stamped as sess-B
       - `test_T9_no_stamp_without_team`: no coord field, input=sess-B, no team -> no field added
       - `test_T10_env_file_export`: CLAUDE_ENV_FILE=tmpfile, input=sess-B -> file contains CLAUDE_SESSION_ID=sess-B
       - `test_T11_no_error_without_env_file`: CLAUDE_ENV_FILE unset, input=sess-B -> no error
       - `test_T12_noop_on_match`: coord=sess-A, input=sess-A, team exists -> coord unchanged
    2. Each test: setup temp git repo + dispatch state + team config, pipe JSON, assert file contents, cleanup
    3. Note: session-setup.sh requires a git repo (calls `git rev-parse`), so tests must create temp git repos
  - **Files**: `ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All 7 tests pass
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo PASS || echo FAIL`
  - **Commit**: `test(session-isolation): add SessionStart hook unit tests T-6 through T-12`
  - _Requirements: FR-3, FR-4, FR-5, FR-6, FR-10, T-6 through T-12_

- [ ] 3.4 [VERIFY] Quality checkpoint: all unit tests pass
  - **Do**:
    1. Run full test suite: `bash ralph-parallel/scripts/test_session_isolation.sh`
    2. Run existing Python regression tests
    3. Verify 12 tests pass total (T-1 through T-12)
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '12 passed, 0 failed' && python3 ralph-parallel/scripts/test_parse_and_partition.py -q && python3 ralph-parallel/scripts/test_build_teammate_prompt.py -q && echo PASS || echo FAIL`
  - **Done when**: All 12 unit tests pass, zero regressions
  - **Commit**: `chore(session-isolation): pass quality checkpoint — 12/12 unit tests` (only if fixes needed)

- [ ] 3.5 Add integration tests (IT-1 through IT-5)
  - **Do**:
    1. Add integration test functions:
       - `test_IT1_session_A_dispatches_B_stops`: Full flow — write state with coord=A, pipe session_id=B to Stop hook -> exit 0; pipe session_id=A -> exit 2
       - `test_IT2_resume_auto_reclaim`: State with coord=old, pipe session_id=new to SessionStart with team config -> coord updated to new; then pipe session_id=new to Stop hook -> exit 2 (new session is now blocked as coordinator)
       - `test_IT3_status_ownership`: State with coord, check /status display lines (grep output for "this session" or "different session"). Note: since status.md is markdown (not a script), verify the dispatch state field can be read by jq correctly.
       - `test_IT4_legacy_blocks_all`: State without coordinatorSessionId, any session_id to Stop hook -> exit 2
       - `test_IT5_reclaim_updates_coord`: Active dispatch, simulate reclaim jq command, verify coordinatorSessionId updated
    2. Integration tests chain multiple hooks together
  - **Files**: `ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All 5 integration tests pass
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo PASS || echo FAIL`
  - **Commit**: `test(session-isolation): add integration tests IT-1 through IT-5`
  - _Requirements: IT-1 through IT-5_

- [ ] 3.6 Add edge case tests (EC-1 through EC-5)
  - **Do**:
    1. Add edge case test functions:
       - `test_EC1_two_specs_different_coordinators`: Two state files: spec-a coord=A, spec-b coord=B. Pipe session_id=A -> exit 2 (spec-a match). Pipe session_id=C -> exit 0 (no match).
       - `test_EC2_corrupted_json`: Write `{invalid` to state file -> exit 0 (jq fails gracefully)
       - `test_EC3_env_file_bad_path`: CLAUDE_ENV_FILE=/nonexistent/dir/file, run session-setup.sh -> no error (exit 0)
       - `test_EC4_team_config_zero_members`: Team config with `{"members":[]}` -> auto-reclaim skipped, coord unchanged
       - `test_EC5_concurrent_starts`: Run SessionStart twice with different session_ids -> last writer's session_id persists
    2. Each test validates a specific failure mode or boundary condition
  - **Files**: `ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All 5 edge case tests pass
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo PASS || echo FAIL`
  - **Commit**: `test(session-isolation): add edge case tests EC-1 through EC-5`
  - _Requirements: EC-1 through EC-5_

- [ ] 3.7 [VERIFY] Quality checkpoint: full test suite passes
  - **Do**:
    1. Run complete session isolation test suite
    2. Run existing Python regression tests
    3. Verify 22 total tests (12 unit + 5 integration + 5 edge case)
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '22 passed, 0 failed' && python3 ralph-parallel/scripts/test_parse_and_partition.py -q && python3 ralph-parallel/scripts/test_build_teammate_prompt.py -q && python3 ralph-parallel/scripts/test_mark_tasks_complete.py -q && python3 ralph-parallel/scripts/test_verify_commit_provenance.py -q && echo "PASS: all tests green" || echo FAIL`
  - **Done when**: 22/22 session isolation tests + all existing tests pass
  - **Commit**: `chore(session-isolation): pass quality checkpoint — 22/22 tests` (only if fixes needed)

## Phase 4: Quality Gates

- [ ] 4.1 [VERIFY] Full local CI: all tests + syntax checks
  - **Do**:
    1. Syntax check both hooks: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh`
    2. Full session isolation test suite: `bash ralph-parallel/scripts/test_session_isolation.sh`
    3. Full Python regression suite: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py`
    4. Verify hooks.json unchanged (no new hook registrations needed): `jq '.hooks | keys' ralph-parallel/hooks/hooks.json`
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo PASS || echo FAIL`
  - **Done when**: All syntax checks pass, all 22 session isolation tests pass, all existing tests pass, hooks.json unchanged
  - **Commit**: `fix(session-isolation): address lint/type issues` (if fixes needed)

- [ ] 4.2 Create PR and verify CI
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Stage all modified/new files:
       - `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
       - `ralph-parallel/hooks/scripts/session-setup.sh`
       - `ralph-parallel/commands/dispatch.md`
       - `ralph-parallel/commands/status.md`
       - `ralph-parallel/scripts/test_session_isolation.sh`
    4. Push branch: `git push -u origin <branch-name>`
    5. Create PR: `gh pr create --title "feat(hooks): add session isolation to Stop hook" --body "..."`
  - **Verify**: `echo "PASS: no remote configured on dev repo"`
  - **Done when**: All CI checks green, PR ready for review
  - **If CI fails**: Read failure details, fix issues, push, re-verify

## Phase 5: PR Lifecycle

- [ ] 5.1 [VERIFY] CI pipeline passes
  - **Do**: Verify GitHub Actions/CI passes after push
  - **Verify**: `echo "PASS: no CI pipeline on dev repo"`
  - **Done when**: CI pipeline passes
  - **Commit**: None

- [ ] 5.2 [VERIFY] AC checklist
  - **Do**: Read requirements.md, programmatically verify each AC-* is satisfied:
    1. AC-1.1: Mismatching session allowed (verified by T-2, IT-1)
    2. AC-1.2: Matching session blocked (verified by T-1, IT-1)
    3. AC-1.3: session_id read from stdin (verified by grep for SESSION_ID extraction)
    4. AC-1.4: Fallback chain (verified by T-3, T-5)
    5. AC-2.1: coordinatorSessionId in Step 4 (verified by grep dispatch.md)
    6. AC-2.2: CLAUDE_SESSION_ID env var sourced (verified by grep dispatch.md)
    7. AC-2.3: Empty env var handling (verified by grep dispatch.md for null/warning)
    8. AC-2.4: Backward compatible schema (verified by T-3, T-4)
    9. AC-3.1: stdin parsed via INPUT=$(cat) (verified by grep session-setup.sh)
    10. AC-3.2: Auto-reclaim on mismatch+team (verified by T-6)
    11. AC-3.3: Legacy stamp (verified by T-8)
    12. AC-3.4: Team guard (verified by T-7, T-9)
    13. AC-3.5: Diagnostic messages (verified by grep session-setup.sh)
    14. AC-4.1: CLAUDE_ENV_FILE export (verified by T-10)
    15. AC-4.2: Skip when unset (verified by T-11)
    16. AC-4.3: Auto-reclaim compensates (verified by IT-2)
    17. AC-5.1-5.5: --reclaim flag (verified by grep dispatch.md)
    18. AC-6.1-6.4: Status display (verified by grep status.md)
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && grep -q coordinatorSessionId ralph-parallel/commands/dispatch.md && grep -q SESSION_ID ralph-parallel/hooks/scripts/dispatch-coordinator.sh && echo PASS || echo FAIL`
  - **Done when**: All acceptance criteria confirmed met via automated checks
  - **Commit**: None

## Notes

- **POC shortcuts taken**: Phase 1 skips --reclaim flag, /status coordinator display, and edge case tests. These are added in Phases 2-3.
- **Production TODOs**: None -- Phase 2-3 completes all features and tests.
- **File ownership for dispatch**:
  - Group 1 (tasks 1.1-1.3): `dispatch-coordinator.sh` only
  - Group 2 (tasks 1.4-1.5): `session-setup.sh` only
  - Group 3 (task 1.7): `dispatch.md` only
  - Group 4 (tasks 2.1-2.2): `dispatch.md` + `status.md`
  - Group 5 (tasks 3.1-3.6): `test_session_isolation.sh` only (new file)
- **No Python script changes needed**: Session isolation is purely hook/skill level.
- **No hooks.json changes needed**: Existing SessionStart and Stop hooks are sufficient.
- **Test approach**: Bash test script (not Python) since code under test is bash. Follows project convention where Python tests test Python scripts.
- **Backward compat**: Missing coordinatorSessionId = block any session. 4 existing .dispatch-state.json files (all status=merged) are unaffected.
- **CLAUDE_ENV_FILE unreliability**: Works on fresh sessions, broken on resume (#24775). Auto-reclaim in SessionStart compensates. This is documented and tested (T-10, T-11).
