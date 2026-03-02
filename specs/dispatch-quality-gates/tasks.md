# Tasks: Dispatch Quality Gates

## Quality Commands

- **Build**: N/A
- **Typecheck**: N/A
- **Lint**: N/A
- **Test**: `pytest ralph-parallel/scripts/test_*.py && bash ralph-parallel/scripts/test_stop_hook.sh`

---

## Phase 1: Make It Work (POC)

Focus: Get all 6 gates functional end-to-end. Skip edge cases initially, accept minimal test coverage.

### Group A: New validation script + tests

**Files owned**: `ralph-parallel/scripts/validate-pre-merge.py`, `ralph-parallel/scripts/test_validate_pre_merge.py`

- [x] 1.1 Create validate-pre-merge.py with all 5 checks
  - **Do**:
    1. Create `ralph-parallel/scripts/validate-pre-merge.py`
    2. Implement argparse with `--dispatch-state`, `--tasks-md`, `--skip-quality-commands`
    3. Check 1: Parse tasks.md for `- [ ]` vs `- [x]` checkboxes. Report unchecked task IDs
    4. Check 2: Compare `groups[].name` against `completedGroups` array. Report missing groups
    5. Checks 3-5: Run `qualityCommands.build`, `.test`, `.lint` via subprocess (300s timeout). Skip if `--skip-quality-commands`
    6. Resolve project root: walk up 2 dirs from `--dispatch-state` path (same as capture-baseline.sh)
    7. Output structured JSON on stdout: `{"passed": bool, "checks": {...}}`
    8. Exit 0 if all pass, exit 1 if any fail
    9. Handle missing files: exit 1 with `{"error": "..."}` JSON
  - **Files**: `ralph-parallel/scripts/validate-pre-merge.py`
  - **Done when**: Script runs standalone with `--dispatch-state` and `--tasks-md` args, exits 0 for valid input and 1 for invalid
  - **Verify**: `python3 ralph-parallel/scripts/validate-pre-merge.py --help && echo "exits 0"`
  - **Commit**: `feat(scripts): add validate-pre-merge.py pre-merge gate script`
  - _Requirements: FR-1, FR-2, AC-1.1 through AC-1.9_
  - _Design: Component 1_

- [x] 1.2 Create test_validate_pre_merge.py with 10 test cases
  - **Do**:
    1. Create `ralph-parallel/scripts/test_validate_pre_merge.py`
    2. Follow existing pattern from `test_mark_tasks_complete.py`: subprocess.run against script, JSON output parsing, tmp_path fixtures
    3. Implement test cases from design section:
       - All tasks checked + all groups complete -> exit 0, passed=true
       - Unchecked tasks remain -> exit 1, allTasksChecked.passed=false
       - Missing group in completedGroups -> exit 1, allGroupsCompleted.passed=false
       - Quality build fails (mock command `exit 1`) -> exit 1, qualityBuild.passed=false
       - Quality test fails -> exit 1, qualityTest.passed=false
       - --skip-quality-commands flag still fails on checkboxes -> exit 1
       - Missing dispatch-state.json -> exit 1, error JSON
       - Missing tasks.md -> exit 1, error JSON
       - No groups in dispatch-state (empty array) -> exit 0 (vacuously true)
       - No quality commands defined -> exit 0 (quality checks skipped)
    4. Use `tmp_path` for all fixture files. Create synthetic dispatch-state.json and tasks.md per test
  - **Files**: `ralph-parallel/scripts/test_validate_pre_merge.py`
  - **Done when**: All 10 test cases pass
  - **Verify**: `pytest ralph-parallel/scripts/test_validate_pre_merge.py -v`
  - **Commit**: `test(scripts): add tests for validate-pre-merge.py`
  - _Requirements: AC-7.1_
  - _Design: Test Strategy - test_validate_pre_merge.py_

### Group B: task-completed-gate.sh modifications

**Files owned**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`

- [x] 1.3 Add Stage 1.5 VERIFY task phase gate to task-completed-gate.sh
  - **Do**:
    1. Insert new Stage 1.5 block after line 121 (after Stage 1 exit 2 block), before Stage 2
    2. Detect `[VERIFY]` marker: scan tasks.md for line matching `- [.] ${COMPLETED_SPEC_TASK}` AND containing `[VERIFY]`
    3. If VERIFY detected:
       a. Extract phase number from task ID (cut -d. -f1)
       b. Scan tasks.md for unchecked `- [ ]` tasks in same phase with lower task number
       c. If unchecked predecessors exist, exit 2 with list of unchecked task IDs
       d. Run ALL qualityCommands (build, test, lint) from dispatch-state.json regardless of periodic intervals
       e. If any quality command fails, exit 2 with command name, exit code, last 50 lines of output
    4. Non-VERIFY tasks skip Stage 1.5 entirely (no regression on existing behavior)
    5. After Stage 1.5, continue to Stages 2-6 for additional safety
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: VERIFY tasks trigger full quality gate; non-VERIFY tasks are unaffected
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && echo "syntax ok"`
  - **Commit**: `feat(hooks): add VERIFY task phase gate to task-completed-gate.sh`
  - _Requirements: FR-10, FR-11, AC-5.1 through AC-5.5_
  - _Design: Component 4a_

- [x] 1.4 Restructure Stage 5 for hardFail baseline comparison
  - **Do**:
    1. Read `BASELINE_HARD_FAIL` and `BASELINE_EXIT_CODE` from dispatch-state.json BEFORE the test execution block (after TEST_CMD is read, around line 225)
    2. Add null guards: `if [ "$BASELINE_HARD_FAIL" = "null" ]; then BASELINE_HARD_FAIL="false"; fi`
    3. Restructure the test failure/success flow (lines 237-276):
       a. If TEST_EXIT != 0 AND hardFail=true AND same exit code as baseline: allow (pre-existing), log to stderr
       b. If TEST_EXIT != 0 AND (hardFail=false OR different exit code): block with exit 2 (existing behavior for non-hardFail, new regression for hardFail)
       c. If TEST_EXIT == 0 AND hardFail=true: log improvement to stderr
       d. If TEST_EXIT == 0: do baseline count comparison (existing logic)
    4. Move ANSI strip to the test-passed branch only (it's for parse_test_count which only runs on success)
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Stage 5 handles hardFail baseline correctly; existing non-hardFail path unchanged
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && echo "syntax ok"`
  - **Commit**: `feat(hooks): add hardFail baseline comparison to Stage 5`
  - _Requirements: FR-5, FR-6, FR-7, AC-3.2 through AC-3.5_
  - _Design: Component 4b_

- [x] 1.5 [VERIFY] Quality checkpoint: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Do**: Verify bash syntax on all modified shell scripts
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: All shell scripts pass syntax check
  - **Commit**: `chore(hooks): pass quality checkpoint` (only if fixes needed)

### Group C: dispatch-coordinator.sh + merge-guard.sh + hooks.json

**Files owned**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`, `ralph-parallel/hooks/scripts/merge-guard.sh`, `ralph-parallel/hooks/hooks.json`

- [x] 1.6 Reorder terminal status check in dispatch-coordinator.sh
  - **Do**:
    1. Modify lines 204-207 of dispatch-coordinator.sh
    2. Change from: `if [ "$STATUS" != "dispatched" ]; then` (exits for ANY non-dispatched)
    3. Change to: `if [ "$STATUS" != "dispatched" ] && [ "$STATUS" != "merged" ]; then` (lets "merged" fall through)
    4. Add comment: `# "merged" falls through to completion check (prevents bypass).`
    5. Verify: "aborted", "superseded", "stale" still hit `cleanup_and_allow`. Only "merged" and "dispatched" reach the completion check
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: status="merged" falls through to completion check instead of immediately allowing stop
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && echo "syntax ok"`
  - **Commit**: `fix(hooks): stop hook checks completion for status=merged`
  - _Requirements: FR-3, FR-4, AC-2.1 through AC-2.4_
  - _Design: Component 2_

- [x] 1.7 Create merge-guard.sh PreToolUse hook
  - **Do**:
    1. Create `ralph-parallel/hooks/scripts/merge-guard.sh`
    2. Make executable: `chmod +x`
    3. Parse stdin JSON for `tool_name` and `tool_input`
    4. Fast path exits: not Write/Edit -> exit 0; has AGENT_NAME -> exit 0 (teammate, not coordinator); basename not `.dispatch-state.json` -> exit 0
    5. Content check: For Edit, check `new_string` for `"merged"`; for Write, check `content` for `"merged"`
    6. If merged detected: resolve spec dir from file path, find tasks.md
    7. Run `validate-pre-merge.py --dispatch-state <path> --tasks-md <path> --skip-quality-commands`
    8. If validate exits non-zero: exit 2 with stderr feedback
    9. If validate passes: exit 0 (allow write)
    10. Graceful degradation: if validate-pre-merge.py not found, exit 0 with WARNING
  - **Files**: `ralph-parallel/hooks/scripts/merge-guard.sh`
  - **Done when**: Hook intercepts status="merged" writes and blocks when validate-pre-merge.py fails
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/merge-guard.sh && echo "syntax ok"`
  - **Commit**: `feat(hooks): add merge-guard.sh PreToolUse hook`
  - _Requirements: FR-8, FR-9, AC-4.1 through AC-4.6_
  - _Design: Component 5_

- [x] 1.8 Register merge-guard.sh in hooks.json
  - **Do**:
    1. Modify `ralph-parallel/hooks/hooks.json`
    2. Add merge-guard.sh as second entry in the PreToolUse hooks array (after file-ownership-guard.sh)
    3. Use same matcher `Write|Edit`, timeout 30 (higher than file-ownership-guard.sh's 10 because validate-pre-merge.py runs)
    4. Both hooks share the same matcher and run in sequence
  - **Files**: `ralph-parallel/hooks/hooks.json`
  - **Done when**: hooks.json has both file-ownership-guard.sh and merge-guard.sh in PreToolUse
  - **Verify**: `python3 -c "import json; d=json.load(open('ralph-parallel/hooks/hooks.json')); hooks=d['hooks']['PreToolUse'][0]['hooks']; assert len(hooks)==2 and 'merge-guard' in hooks[1]['command']; print('OK')"`
  - **Commit**: `feat(hooks): register merge-guard.sh in hooks.json`
  - _Requirements: AC-4.6_
  - _Design: Component 5 - Hook registration_

### Group D: Script modifications (mark-tasks-complete.py + capture-baseline.sh)

**Files owned**: `ralph-parallel/scripts/mark-tasks-complete.py`, `ralph-parallel/scripts/capture-baseline.sh`, `ralph-parallel/scripts/test_mark_tasks_complete.py`

- [x] 1.9 Add hardFail flag to capture-baseline.sh
  - **Do**:
    1. Modify the test failure block (lines 87-97) in capture-baseline.sh
    2. Add `hardFail: true` to the jq JSON construction: change from `'{testCount: -1, exitCode: $exit_code, reason: "tests_failing"}'` to `'{testCount: -1, exitCode: $exit_code, reason: "tests_failing", hardFail: true}'`
    3. Add warning to stderr: `echo "ralph-parallel: WARNING: hardFail=true -- task-completed-gate.sh will still run tests per-task" >&2`
  - **Files**: `ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: When tests fail at baseline, dispatch-state.json gets `baselineSnapshot.hardFail: true`
  - **Verify**: `bash -n ralph-parallel/scripts/capture-baseline.sh && echo "syntax ok"`
  - **Commit**: `feat(scripts): add hardFail flag to capture-baseline.sh`
  - _Requirements: AC-3.1, AC-3.6_
  - _Design: Component 3_

- [x] 1.10 Add --strict mode to mark-tasks-complete.py
  - **Do**:
    1. Add `--strict` argument to argparse (after `--dry-run`)
    2. Add `skipped = []` tracking list
    3. In the task_ids loop, when `args.strict`:
       a. Already `[x]` tasks: accept (alreadyComplete++)
       b. Still `[ ]` tasks: skip + warn to stderr + add to skipped list
       c. Not found tasks: increment notFound
    4. In default mode (no --strict): preserve existing behavior exactly
    5. Add `strict` and `skipped` fields to output JSON when --strict active
    6. Exit 2 (not 1) when strict mode has skipped tasks
  - **Files**: `ralph-parallel/scripts/mark-tasks-complete.py`
  - **Done when**: `--strict` skips unchecked tasks with warning; default mode unchanged
  - **Verify**: `python3 ralph-parallel/scripts/mark-tasks-complete.py --help | grep -q strict && echo "strict flag present"`
  - **Commit**: `feat(scripts): add --strict mode to mark-tasks-complete.py`
  - _Requirements: FR-12, FR-13, AC-6.1 through AC-6.6_
  - _Design: Component 6_

- [x] 1.11 Add strict mode tests to test_mark_tasks_complete.py
  - **Do**:
    1. Extend `ralph-parallel/scripts/test_mark_tasks_complete.py`
    2. Update `run_script` helper to accept `strict=False` parameter
    3. Add test class `TestStrictMode` with 4 test cases:
       a. `test_strict_all_already_checked`: all tasks in completedGroup are [x] -> exit 0, skipped=[]
       b. `test_strict_unchecked_in_completed_group`: task 2.1 is [ ] but in completedGroup -> exit 2, skipped=["2.1"]
       c. `test_strict_mixed_checked_unchecked`: some [x] some [ ] -> exit 2, alreadyComplete counts [x], skipped lists [ ]
       d. `test_no_strict_unchanged`: same input without --strict -> exit 0, tasks marked [x] (backward compat)
  - **Files**: `ralph-parallel/scripts/test_mark_tasks_complete.py`
  - **Done when**: All strict mode tests pass alongside existing tests
  - **Verify**: `pytest ralph-parallel/scripts/test_mark_tasks_complete.py -v`
  - **Commit**: `test(scripts): add strict mode tests for mark-tasks-complete.py`
  - _Requirements: AC-7.2_
  - _Design: Test Strategy - test_mark_tasks_complete.py_

- [x] 1.12 [VERIFY] Quality checkpoint: `pytest ralph-parallel/scripts/test_validate_pre_merge.py ralph-parallel/scripts/test_mark_tasks_complete.py -v`
  - **Do**: Run Python test suite for all modified/new scripts
  - **Verify**: `pytest ralph-parallel/scripts/test_validate_pre_merge.py ralph-parallel/scripts/test_mark_tasks_complete.py -v`
  - **Done when**: All Python tests pass
  - **Commit**: `chore(scripts): pass quality checkpoint` (only if fixes needed)

---

## Phase 2: Integration Testing + Stop Hook Tests

Focus: Verify gates work together. Extend stop hook tests for merged+incomplete scenario.

- [x] 2.1 Add merged+incomplete and merged+complete test scenarios to test_stop_hook.sh
  - **Do**:
    1. Extend `ralph-parallel/scripts/test_stop_hook.sh`
    2. Add test `T-SH-MERGED-INCOMPLETE`:
       a. Setup: write dispatch-state with status="merged", 2 groups, 2 in completedGroups
       b. Write tasks.md with 1 unchecked `- [ ]` task remaining
       c. Run stop hook with piped JSON input (same pattern as existing tests)
       d. Assert: output contains JSON block (decision=block)
    3. Add test `T-SH-MERGED-COMPLETE`:
       a. Setup: write dispatch-state with status="merged", all groups completed
       b. Write tasks.md with all `- [x]` tasks
       c. Run stop hook
       d. Assert: exit 0, no JSON block output (allow)
    4. Add test `T-SH-ABORTED-UNCHANGED`:
       a. Setup: write dispatch-state with status="aborted"
       b. Run stop hook
       c. Assert: exit 0, no JSON block (no regression from reordering)
    5. Follow existing test helper patterns: `setup_project`, `write_dispatch_state`, `write_tasks_md`
  - **Files**: `ralph-parallel/scripts/test_stop_hook.sh`
  - **Done when**: All 3 new tests pass alongside existing tests
  - **Verify**: `bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | grep -E '(PASS|FAIL)' | tail -20`
  - **Commit**: `test(hooks): add merged+incomplete stop hook test scenarios`
  - _Requirements: AC-7.3_
  - _Design: Test Strategy - test_stop_hook.sh_

- [x] 2.2 [VERIFY] Full POC verification: `pytest ralph-parallel/scripts/test_*.py && bash ralph-parallel/scripts/test_stop_hook.sh`
  - **Do**:
    1. Run complete test suite: pytest (all Python tests) + bash (stop hook tests)
    2. Verify zero test failures, zero regressions
    3. Check all new test files are present and executable
  - **Verify**: `pytest ralph-parallel/scripts/test_*.py -v && bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | grep -c FAIL | grep -q '^0$'`
  - **Done when**: Full test suite passes with 0 failures
  - **Commit**: `feat(dispatch-quality-gates): complete POC`
  - _Requirements: AC-7.4, AC-7.5_

---

## Phase 3: Refactoring + Edge Cases

Focus: Harden edge cases, improve error messages, ensure backward compatibility.

- [ ] 3.1 Add edge case handling to validate-pre-merge.py
  - **Do**:
    1. Handle malformed JSON in dispatch-state: try/except JSONDecodeError -> exit 1 with error JSON
    2. Handle subprocess timeout (300s) for quality commands -> exit 1 with timeout message
    3. Handle empty tasks.md (no checkboxes at all) -> pass (vacuously true) or fail based on groups
    4. Handle `qualityCommands` values that are "null" string or empty string -> skip (treat as undefined)
    5. Add `_resolve_project_root()` helper that walks up 2 dirs from dispatch-state path
  - **Files**: `ralph-parallel/scripts/validate-pre-merge.py`
  - **Done when**: All edge cases handled gracefully with informative error messages
  - **Verify**: `pytest ralph-parallel/scripts/test_validate_pre_merge.py -v`
  - **Commit**: `refactor(scripts): add edge case handling to validate-pre-merge.py`
  - _Design: Error Handling table_

- [x] 3.2 Harden merge-guard.sh edge cases
  - **Do**:
    1. Handle case where SCRIPT_DIR resolution fails (BASH_SOURCE edge cases)
    2. Ensure fast path exit for non-.dispatch-state.json files is first check after tool_name
    3. Handle empty `new_string` or `content` fields without error
    4. Add timeout protection: if validate-pre-merge.py hangs, the hook's 30s timeout in hooks.json kills it
  - **Files**: `ralph-parallel/hooks/scripts/merge-guard.sh`
  - **Done when**: Hook handles all edge cases without crashing
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/merge-guard.sh && echo "syntax ok"`
  - **Commit**: `refactor(hooks): harden merge-guard.sh edge cases`
  - _Design: Component 5 - Error handling_

- [ ] 3.3 [VERIFY] Quality checkpoint: `pytest ralph-parallel/scripts/test_*.py && bash ralph-parallel/scripts/test_stop_hook.sh`
  - **Do**: Run full test suite to verify no regressions from refactoring
  - **Verify**: `pytest ralph-parallel/scripts/test_*.py -v && bash ralph-parallel/scripts/test_stop_hook.sh 2>&1 | grep -c FAIL | grep -q '^0$'`
  - **Done when**: All tests pass
  - **Commit**: `chore(quality-gates): pass quality checkpoint` (only if fixes needed)

---

## Phase 4: Quality Gates

- [ ] 4.1 Local quality check
  - **Do**: Run ALL quality checks locally
  - **Verify**: All commands must pass:
    - Tests: `pytest ralph-parallel/scripts/test_*.py -v`
    - Shell tests: `bash ralph-parallel/scripts/test_stop_hook.sh`
    - Syntax: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && bash -n ralph-parallel/hooks/scripts/merge-guard.sh && bash -n ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: All commands pass with no errors
  - **Commit**: `fix(dispatch-quality-gates): address quality issues` (if fixes needed)

- [ ] 4.2 Create PR and verify CI
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Push branch: `git push -u origin <branch-name>`
    4. Create PR: `gh pr create --title "feat(hooks): add dispatch quality gates" --body "..."`
    5. PR body should summarize: triple-gate enforcement (PreToolUse + stop hook + validate-pre-merge.py), VERIFY task phase gate, baseline hardening, strict mode for mark-tasks-complete.py
  - **Verify**: `gh pr checks --watch` (wait for CI completion)
  - **Done when**: All CI checks green, PR ready for review
  - **If CI fails**: Read failure details, fix locally, push, re-verify

## Phase 5: PR Lifecycle

- [ ] 5.1 Monitor CI and fix failures
  - **Do**:
    1. Check CI status: `gh pr checks`
    2. If any check fails, read logs and fix
    3. Push fixes and re-verify
  - **Verify**: `gh pr checks` shows all passing
  - **Done when**: CI green
  - **Commit**: `fix(dispatch-quality-gates): resolve CI failures` (if needed)

- [ ] 5.2 Address review comments
  - **Do**:
    1. Read PR comments: `gh pr view --comments`
    2. Implement requested changes
    3. Push and re-verify CI
  - **Verify**: `gh pr checks` shows all passing after changes
  - **Done when**: Review comments resolved, CI green

- [ ] 5.3 [VERIFY] AC checklist
  - **Do**: Programmatically verify each acceptance criterion:
    1. AC-1.1: `python3 ralph-parallel/scripts/validate-pre-merge.py` exists and handles all-checked input
    2. AC-2.1: `grep -q 'STATUS.*!=.*merged' ralph-parallel/hooks/scripts/dispatch-coordinator.sh` (merged falls through)
    3. AC-3.1: `grep -q 'hardFail.*true' ralph-parallel/scripts/capture-baseline.sh` (hardFail written)
    4. AC-4.1: `test -f ralph-parallel/hooks/scripts/merge-guard.sh` (merge guard exists)
    5. AC-5.1: `grep -q 'VERIFY' ralph-parallel/hooks/scripts/task-completed-gate.sh` (VERIFY detection)
    6. AC-6.1: `python3 ralph-parallel/scripts/mark-tasks-complete.py --help | grep -q strict` (strict flag)
    7. AC-7.4: `pytest ralph-parallel/scripts/test_*.py` exits 0 (all tests pass)
  - **Verify**: Run all AC checks as a single compound command
  - **Done when**: All acceptance criteria confirmed met via automated checks
  - **Commit**: None

---

## Notes

- **POC shortcuts taken**: Shell scripts verified via `bash -n` (syntax only) in Phase 1 rather than integration tests. Full integration tests added in Phase 2.
- **Production TODOs**: validate-pre-merge.py quality command timeout (300s) may need tuning for large projects. merge-guard.sh 30s hook timeout in hooks.json may need increase.
- **Parallel dispatch grouping**: 4 groups (A-D) with no file ownership conflicts. Group A (new scripts) is independent. Group B (task-completed-gate.sh) is single-file. Group C (dispatch-coordinator.sh + merge-guard.sh + hooks.json) are related coordinator hooks. Group D (mark-tasks-complete.py + capture-baseline.sh + tests) are independent scripts.
- **Dependency note**: validate-pre-merge.py (Group A, task 1.1) must be created before merge-guard.sh (Group C, task 1.7) can call it. If dispatched in parallel, Group C should wait for Group A's task 1.1 to complete before starting task 1.7.
- **plugin-audit-fixes ordering**: This spec modifies task-completed-gate.sh and dispatch-coordinator.sh. If plugin-audit-fixes lands first, line numbers will shift. Coordinate implementation order.
