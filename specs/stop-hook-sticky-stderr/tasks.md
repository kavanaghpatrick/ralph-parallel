# Tasks: Stop Hook Sticky Stderr Fix

## Quality Commands

- **Build**: N/A (bash scripts)
- **Typecheck**: N/A (bash scripts)
- **Lint**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh` (syntax check)
- **Test**: `bash ralph-parallel/scripts/test_stop_hook.sh` (hook test suite)

## Phase 1: Make It Work (POC)

Focus: Replace exit-2 blocking with JSON decision control in dispatch-coordinator.sh. Validate the core behavioral change works end-to-end.

- [x] 1.1 Rewrite dispatch-coordinator.sh with JSON decision control and block counter
  - **Do**:
    1. Read current `ralph-parallel/hooks/scripts/dispatch-coordinator.sh` (197 lines)
    2. Rewrite the script following the design.md architecture. Key changes:
       - Add helper functions: `block_stop()` (using `jq -nc` for safe JSON), `allow_stop()`, `cleanup_and_allow()`, `read_block_counter()`, `write_block_counter()`, `write_heartbeat()`
       - Remove the `stop_hook_active` early exit (lines 24-26). The block counter now handles loop prevention.
       - Replace ALL `exit 2` paths with `block_stop "$REASON"` calls (exit 0 + JSON stdout)
       - Remove ALL `cat >&2 <<PROMPT` heredoc blocks (lines 165-194)
       - Add block counter logic: read `/tmp/ralph-stop-${SPEC_NAME}-${SESSION_ID}`, check `MAX_BLOCKS` (default 3, env `RALPH_MAX_STOP_BLOCKS`), increment on block
       - Block counter format: `count:status:dispatchedAt` to detect dispatch transitions
       - Add `write_heartbeat()` call before each `block_stop` -- writes `lastHeartbeat` ISO 8601 to `.dispatch-state.json`
       - Terminal status check (`cleanup_and_allow "$COUNTER_FILE"`) deletes counter file
       - "All tasks complete" path: silent `cleanup_and_allow` (no stderr reminder)
       - "Teammates lost" path: JSON block with team-loss reason
       - Safety valve: when `BLOCK_COUNT >= MAX_BLOCKS`, `exit 0` (allow) without deleting counter
       - Preserve: `set -euo pipefail`, teammate check, TEAM_NAME vs scan mode, session isolation, all `jq ... || exit 0` error handling
    3. Three reason templates per design.md (each < 250 chars):
       - Active dispatch: `[Dispatch: $SPEC] $DONE/$TOTAL groups done. Next: check TaskList for progress, coordinate idle teammates. Do NOT stop until all tasks complete and team cleaned up.`
       - Teammates lost: `[Dispatch: $SPEC] TEAMMATES LOST ($DONE/$TOTAL groups done). Team died. Re-run /ralph-parallel:dispatch to re-spawn. Do NOT execute tasks yourself.`
       - Re-block: `[Dispatch: $SPEC] Still active ($DONE/$TOTAL groups done, block $COUNT/$MAX). Check TaskList, coordinate teammates. Work remains.`
    4. Use `jq -nc --arg r "$REASON" '{"decision":"block","reason":$r}'` in `block_stop()` for safe JSON escaping
    5. All atomic writes use `.tmp.$$` suffix
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: Script has zero `exit 2` calls, zero `cat >&2` blocks, all blocking paths use JSON stdout + exit 0, block counter and heartbeat logic present
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && grep -c 'exit 2' ralph-parallel/hooks/scripts/dispatch-coordinator.sh | grep -q '^0$' && grep -c 'cat >&2' ralph-parallel/hooks/scripts/dispatch-coordinator.sh | grep -q '^0$' && echo "PASS: no exit-2, no stderr heredocs"`
  - **Commit**: `fix(hooks): rewrite dispatch-coordinator.sh with JSON decision control`
  - _Requirements: FR-1, FR-2, FR-3, FR-4, FR-5, FR-8, FR-9, FR-10, FR-11, FR-12_
  - _Design: Components 1, 2, 3_

- [x] 1.2 Update session-setup.sh with heartbeat-gated auto-reclaim
  - **Do**:
    1. Read current `ralph-parallel/hooks/scripts/session-setup.sh` (131 lines)
    2. Modify the auto-reclaim section (lines 89-103):
       - Before reclaiming on session mismatch, read `lastHeartbeat` from dispatch state
       - Compute heartbeat age using `date -j -f "%Y-%m-%dT%H:%M:%SZ"` (macOS BSD) with `date -d` (GNU) fallback, defaulting to epoch 0 on parse failure
       - If heartbeat is recent (< `RALPH_RECLAIM_THRESHOLD_MINUTES`, default 10): log warning, skip reclaim
       - If heartbeat is stale or missing (legacy): proceed with reclaim
    3. Update ALL `jq` write patterns to use `.tmp.$$` suffix:
       - Line 95-96: auto-reclaim write
       - Line 100-101: legacy stamp write
       - Lines 114-117: stale-dispatch marking write
    4. Preserve all existing behavior for dispatches without `lastHeartbeat` (backward compat)
  - **Files**: `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: Auto-reclaim checks heartbeat age before proceeding, all `.tmp` writes use `.tmp.$$`, legacy dispatches still reclaimable
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/session-setup.sh && grep -c '\.tmp\.\$\$' ralph-parallel/hooks/scripts/session-setup.sh | xargs test 3 -le && echo "PASS: syntax ok, tmp.$$ present"`
  - **Commit**: `fix(hooks): gate auto-reclaim on heartbeat staleness in session-setup.sh`
  - _Requirements: FR-6, FR-7_
  - _Design: Component 4_

- [x] 1.3 [VERIFY] Quality checkpoint: syntax validation
  - **Do**: Run bash syntax check on both modified scripts
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && echo "PASS"`
  - **Done when**: Both scripts pass bash syntax validation
  - **Commit**: `chore(hooks): pass syntax validation` (only if fixes needed)

- [x] 1.4 Create test_stop_hook.sh test suite
  - **Do**:
    1. Create `ralph-parallel/scripts/test_stop_hook.sh` following the pattern of `test_session_isolation.sh`
    2. Include the same helper functions: `setup_project()`, `write_dispatch_state()`, `write_team_config()`, `cleanup_team_config()`, `begin_test()`, `end_test()`, `assert_exit_code()`, `assert_json_field()`, `assert_true()`
    3. Extend `write_dispatch_state()` to accept optional `dispatchedAt` parameter for block counter tests
    4. Add `assert_stdout_json()` helper: validates stdout is valid JSON with expected field values
    5. Add `assert_no_stderr()` helper: captures stderr and asserts it's empty
    6. Implement all 6 test scenarios from design.md:
       - **Test 1 (T-SH1): Clean block-and-release cycle** -- active dispatch blocks with JSON stdout, terminal status allows with no output, counter file cleaned up
       - **Test 2 (T-SH2): Re-block with safety valve** -- first block (stop_hook_active=false), re-blocks on stop_hook_active=true up to MAX_BLOCKS=3, then allows on 4th attempt
       - **Test 3 (T-SH3): Block counter reset on new dispatch** -- dispatch A gets 2 blocks, abort, dispatch B blocks -> counter at 1 not 3
       - **Test 4 (T-SH4): JSON output validity** -- all blocking scenarios produce valid `jq`-parseable JSON with `decision=block` and string `reason`
       - **Test 5 (T-SH5): Heartbeat write on block** -- after a block, `.dispatch-state.json` contains `lastHeartbeat` field
       - **Test 6 (T-SH6): Heartbeat-gated reclaim** -- session-setup skips reclaim when heartbeat < 10min, reclaims when heartbeat > 10min or missing
    7. Also port/update relevant tests from `test_session_isolation.sh` that now have different expected behavior:
       - T-1 (matching session blocked): now expects exit 0 + JSON stdout (not exit 2)
       - T-3 (legacy no coord blocks): now expects exit 0 + JSON stdout
       - T-5 (empty session_id blocks): now expects exit 0 + JSON stdout
       - T-13 (stop_hook_active allows): now expects exit 0 + JSON block on first re-trigger (not immediate allow)
    8. Backward compat tests:
       - **T-BC1**: Dispatch state without `lastHeartbeat` -> session-setup reclaims normally
       - **T-BC2**: Dispatch state without `coordinatorSessionId` -> same as current behavior
  - **Files**: `ralph-parallel/scripts/test_stop_hook.sh`
  - **Done when**: Test script covers all 6 design scenarios + backward compat, follows test_session_isolation.sh patterns, is executable
  - **Verify**: `bash -n ralph-parallel/scripts/test_stop_hook.sh && echo "PASS: test script syntax ok"`
  - **Commit**: `test(hooks): add test_stop_hook.sh for JSON decision control and block counter`
  - _Requirements: AC-1.1 through AC-1.6, AC-2.1 through AC-2.7, AC-3.1 through AC-3.6, AC-4.1 through AC-4.6, AC-6.1 through AC-6.4_
  - _Design: Test Strategy_

- [x] 1.5 POC Checkpoint: run test suite end-to-end
  - **Do**:
    1. Run the new test suite: `bash ralph-parallel/scripts/test_stop_hook.sh`
    2. If tests fail, fix issues in dispatch-coordinator.sh or session-setup.sh
    3. Also run the existing session isolation tests to verify no regressions: `bash ralph-parallel/scripts/test_session_isolation.sh`
    4. The existing tests will need updating since they expect `exit 2` but the new hook uses `exit 0` + JSON. Note which tests fail for Phase 2 migration.
    5. Verify JSON output manually for one blocking scenario:
       ```bash
       # Create test state and pipe to hook, capture stdout
       tmpdir=$(mktemp -d) && mkdir -p "$tmpdir/specs/test-spec" && \
       echo '{"status":"dispatched","dispatchedAt":"2026-02-27T10:00:00Z","groups":[{"name":"g1"}],"completedGroups":[]}' > "$tmpdir/specs/test-spec/.dispatch-state.json" && \
       mkdir -p "$HOME/.claude/teams/test-spec-parallel" && \
       echo '{"members":[{"name":"t1","agentId":"x","agentType":"general-purpose"}]}' > "$HOME/.claude/teams/test-spec-parallel/config.json" && \
       echo "{\"session_id\":\"test-sess\",\"cwd\":\"$tmpdir\",\"stop_hook_active\":false}" | bash ralph-parallel/hooks/scripts/dispatch-coordinator.sh 2>/dev/null | jq . && \
       rm -rf "$tmpdir" "$HOME/.claude/teams/test-spec-parallel"
       ```
  - **Done when**: New test suite passes with 0 failures, JSON output is valid
  - **Verify**: `bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS: all tests pass"`
  - **Commit**: `feat(hooks): complete POC for JSON decision control`
  - _Requirements: All FR-*, All AC-*_

## Phase 2: Refactoring

After POC validated, clean up and align the existing test suite.

- [x] 2.1 Update test_session_isolation.sh for new exit code behavior
  - **Do**:
    1. Read `ralph-parallel/scripts/test_session_isolation.sh`
    2. Update tests that assert `exit 2` to assert `exit 0` (the new behavior for JSON blocking):
       - T-1: `assert_exit_code "$exit_code" 2` -> `assert_exit_code "$exit_code" 0` + add stdout JSON assertion
       - T-3: same change
       - T-5: same change
       - IT-1: `exit_a` assertion from 2 to 0
       - IT-2: `exit_code` assertion from 2 to 0
       - IT-4: both assertions from 2 to 0
       - IT-5: `exit_code` assertion from 2 to 0
       - EC-6: assertion from 2 to 0
    3. T-13 (stop_hook_active): This is the biggest behavioral change. The new hook re-checks state on stop_hook_active=true instead of unconditionally exiting 0. Update to expect exit 0 + JSON block output (if under MAX_BLOCKS).
    4. Add a new helper `assert_stdout_contains_json_block()` that validates exit 0 + JSON `decision=block` on stdout
    5. Keep existing structure and test IDs for continuity
  - **Files**: `ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All tests pass with updated exit code expectations, JSON assertions added for blocking tests
  - **Verify**: `bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS"`
  - **Commit**: `test(hooks): update session isolation tests for JSON decision control`
  - _Requirements: AC-6.1, AC-6.2_

- [ ] 2.2 Add error handling hardening to dispatch-coordinator.sh
  - **Do**:
    1. Ensure `write_heartbeat` failures are non-fatal: wrap with `|| true` so a failed heartbeat write doesn't prevent blocking
    2. Ensure `write_block_counter` failures are non-fatal: wrap with `|| true`
    3. Verify all jq reads use the `$(jq ... 2>/dev/null) || DEFAULT` pattern
    4. Verify counter file permission denied handling: if `/tmp` write fails, block still works (just without counter tracking)
    5. Verify `date` parse failures in session-setup.sh fall back to epoch 0 (which means "very stale" = allow reclaim = safe default)
    6. Add a comment documenting each error path's fallback behavior
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`, `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: All error paths documented with comments, all writes are non-fatal with `|| true` where appropriate
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && echo "PASS"`
  - **Commit**: `refactor(hooks): harden error handling in stop hook and session setup`
  - _Requirements: AC-5.3_
  - _Design: Error Handling table_

- [ ] 2.3 [VERIFY] Quality checkpoint: full test suite
  - **Do**: Run both test suites and syntax validation
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -1 | grep -q '0 failed' && bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS: all checks green"`
  - **Done when**: Syntax clean, both test suites pass
  - **Commit**: `chore(hooks): pass quality checkpoint` (only if fixes needed)

## Phase 3: Testing

- [ ] 3.1 Add edge case tests for block counter behavior
  - **Do**:
    1. Add tests to `test_stop_hook.sh`:
       - **T-SH7**: Block counter file missing/corrupt -> treated as count=0
       - **T-SH8**: Block counter survives after safety valve (MAX_BLOCKS reached, counter file NOT deleted)
       - **T-SH9**: Counter file cleaned up on terminal status (merged/aborted/stale)
       - **T-SH10**: Empty SESSION_ID -> counter file created at `/tmp/ralph-stop-SPECNAME-` (still works)
       - **T-SH11**: `RALPH_MAX_STOP_BLOCKS` env var overrides default 3
       - **T-SH12**: Concurrent stop hook invocations don't crash (run hook twice in background, check both exit 0)
  - **Files**: `ralph-parallel/scripts/test_stop_hook.sh`
  - **Done when**: 6 new edge case tests added and passing
  - **Verify**: `bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS"`
  - **Commit**: `test(hooks): add block counter edge case tests`
  - _Requirements: AC-2.3 through AC-2.7_

- [ ] 3.2 Add edge case tests for heartbeat and reclaim behavior
  - **Do**:
    1. Add tests to `test_stop_hook.sh`:
       - **T-SH13**: Heartbeat write uses `.tmp.$$` pattern (check that no orphan `.tmp` files remain after write)
       - **T-SH14**: `RALPH_RECLAIM_THRESHOLD_MINUTES` env var overrides default 10
       - **T-SH15**: Heartbeat written only on block, NOT on allow (dispatch a terminal status, check no heartbeat update)
       - **T-SH16**: Concurrent sessions: session A dispatches, session B starts, heartbeat < 10min -> B skips reclaim
       - **T-SH17**: Legacy dispatch (no lastHeartbeat, no coordinatorSessionId) -> both hooks work identically to pre-change
  - **Files**: `ralph-parallel/scripts/test_stop_hook.sh`
  - **Done when**: 5 new heartbeat/reclaim tests added and passing
  - **Verify**: `bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS"`
  - **Commit**: `test(hooks): add heartbeat and reclaim edge case tests`
  - _Requirements: AC-4.1 through AC-4.6, AC-6.1 through AC-6.3_

- [ ] 3.3 [VERIFY] Quality checkpoint: complete test coverage
  - **Do**: Run all test suites
  - **Verify**: `bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -1 | grep -q '0 failed' && bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS: all tests green"`
  - **Done when**: All test suites pass
  - **Commit**: `chore(hooks): pass quality checkpoint` (only if fixes needed)

- [ ] 3.4 Sync plugin to cache and validate
  - **Do**:
    1. Sync modified plugin to cache: `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/`
    2. Verify the symlink is intact: `ls -la ~/.claude/plugins/cache/ralph-parallel` (should point to `ralph-parallel-local`)
    3. Verify the synced files match: `diff ralph-parallel/hooks/scripts/dispatch-coordinator.sh ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/hooks/scripts/dispatch-coordinator.sh`
    4. Verify the synced session-setup: `diff ralph-parallel/hooks/scripts/session-setup.sh ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/hooks/scripts/session-setup.sh`
  - **Files**: `~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/` (sync target)
  - **Done when**: Plugin cache is synced, symlink intact, diffs show no difference
  - **Verify**: `diff ralph-parallel/hooks/scripts/dispatch-coordinator.sh ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/hooks/scripts/dispatch-coordinator.sh && diff ralph-parallel/hooks/scripts/session-setup.sh ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/hooks/scripts/session-setup.sh && echo "PASS: cache synced"`
  - **Commit**: No commit (cache sync is local only)

## Phase 4: Quality Gates

- [ ] 4.1 [VERIFY] Full local CI: syntax + all tests
  - **Do**: Run complete validation suite
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh && bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -1 | grep -q '0 failed' && bash ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -1 | grep -q '0 failed' && echo "PASS: all local CI green"`
  - **Done when**: All syntax checks pass, all test suites pass
  - **Commit**: `fix(hooks): address quality issues` (if fixes needed)

- [ ] 4.2 Create PR and verify CI
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Stage changed files: `git add ralph-parallel/hooks/scripts/dispatch-coordinator.sh ralph-parallel/hooks/scripts/session-setup.sh ralph-parallel/scripts/test_stop_hook.sh ralph-parallel/scripts/test_session_isolation.sh`
    4. Push branch: `git push -u origin <branch-name>`
    5. Create PR: `gh pr create --title "fix(hooks): replace exit-2 stderr with JSON decision control" --body "..."`
    6. PR body should reference: sticky stderr bug, JSON decision control migration, block counter safety valve, heartbeat-gated reclaim
  - **Verify**: `gh pr checks --watch` (wait for CI completion) or `gh pr checks`
  - **Done when**: All CI checks green, PR ready for review
  - **If CI fails**: Read failure details with `gh pr checks`, fix locally, push, re-verify

## Phase 5: PR Lifecycle

- [ ] 5.1 [VERIFY] CI pipeline passes
  - **Do**: Verify GitHub Actions/CI passes after push
  - **Verify**: `gh pr checks` shows all green
  - **Done when**: CI pipeline passes
  - **Commit**: None

- [ ] 5.2 [VERIFY] AC checklist
  - **Do**: Programmatically verify each acceptance criterion:
    1. AC-1.1/1.2: `grep -c 'exit 2' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` = 0
    2. AC-1.3/3.1/3.2: `grep 'decision.*block' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` present
    3. AC-1.5: `grep -c 'cat >&2' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` = 0
    4. AC-2.1: `grep -c 'stop_hook_active.*exit 0' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` = 0 (no unconditional early exit)
    5. AC-2.3: `grep 'ralph-stop-' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` present (temp file counter)
    6. AC-2.4: `grep 'MAX_BLOCKS' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` present
    7. AC-3.5: Run one blocking scenario through `jq .` to validate JSON
    8. AC-4.1: `grep 'lastHeartbeat' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` present
    9. AC-4.2: `grep 'lastHeartbeat' ralph-parallel/hooks/scripts/session-setup.sh` present
    10. AC-5.4: `grep '\.tmp\.\$\$' ralph-parallel/hooks/scripts/session-setup.sh` present
    11. AC-6.4: `diff <(jq '.hooks.Stop' ralph-parallel/hooks/hooks.json) <(echo '[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/dispatch-coordinator.sh","timeout":10}]}]')` confirms registration unchanged
  - **Verify**: All grep/diff commands return expected results
  - **Done when**: All acceptance criteria confirmed met
  - **Commit**: None

## Notes

- **POC shortcuts taken**: None -- this is a focused 2-file rewrite with comprehensive test coverage
- **Production TODOs**:
  - Monitor empirically whether JSON `reason` field persists in conversation history like stderr did (unresolved question from design.md)
  - UX issue #12667 ("Stop hook error:" label) is cosmetic and upstream -- not fixed here
  - shellcheck not available on this machine; recommend installing for future CI
- **Key behavioral changes**:
  - `exit 2` -> `exit 0` + JSON stdout for ALL blocking
  - `stop_hook_active=true` no longer unconditionally allows stop; re-checks state up to MAX_BLOCKS
  - Auto-reclaim gated on heartbeat staleness (10 min default)
  - "All tasks complete" stderr reminder removed entirely
  - Block counter temp file per dispatch+session at `/tmp/ralph-stop-{spec}-{session}`
