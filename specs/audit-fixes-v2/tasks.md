---
spec: audit-fixes-v2
phase: tasks
total_tasks: 32
created: 2026-03-09
generated: auto
---

# Tasks: audit-fixes-v2

## Phase 1: Make It Work (Critical + High Fixes)

Focus: Fix all critical and high findings. Accept minimal test coverage for now.

- [ ] 1.1 Add command sanitizer and fix eval in task-completed-gate.sh (C1, H1, H8)
  - **Do**:
    1. Add `_sanitize_cmd()` function near top of script that rejects commands containing null bytes, unquoted backticks, or `..` path traversal sequences. Function should log rejected commands to stderr and return 1 on rejection.
    2. Wrap all 6 `eval` calls (lines ~100, 113, 173, 195, 253, 310, 384) with `_sanitize_cmd` check: `_sanitize_cmd "$CMD" || { echo "Command rejected by sanitizer" >&2; exit 2; }`
    3. Fix H1: Change line 77 `grep -oE '^[0-9]+\.[0-9]+')` to `grep -oE '^[0-9]+\.[0-9]+' || true)` (same for line 143)
    4. Fix H8: Replace predictable `/tmp` counter file references. The counter file path is in dispatch-coordinator.sh not here -- verify no predictable tmp in this file. If VERIFY_OUTPUT or similar uses tmp, use mktemp.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: All eval calls guarded by sanitizer. grep -oE calls have `|| true`. No predictable /tmp paths.
  - **Verify**: `grep -n 'eval ' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh | head -20` shows all eval calls preceded by _sanitize_cmd check. `grep -c '_sanitize_cmd' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh` returns >= 6.
  - **Commit**: `fix(hooks): add command sanitizer to task-completed-gate.sh (C1, H1)`
  - _Requirements: FR-1, FR-4_
  - _Design: Component A_

- [ ] 1.2 Add command sanitizer to capture-baseline.sh (C2)
  - **Do**:
    1. Add the same `_sanitize_cmd()` function from task 1.1
    2. Guard the `eval "$TEST_CMD"` call on line 84 with `_sanitize_cmd "$TEST_CMD"` check
    3. On rejection: output JSON `{"testCount": -1, "reason": "command_rejected"}` and exit 0 (never block dispatch)
  - **Files**: `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: eval on line 84 guarded. Rejected commands produce valid JSON output.
  - **Verify**: `grep -n '_sanitize_cmd' plugins/ralph-parallel/scripts/capture-baseline.sh` shows the guard. `grep -c 'eval' plugins/ralph-parallel/scripts/capture-baseline.sh` still shows 1 (the guarded one).
  - **Commit**: `fix(scripts): add command sanitizer to capture-baseline.sh (C2)`
  - _Requirements: FR-1_
  - _Design: Component A_

- [ ] 1.3 Remove shell=True and add typecheck to validate-pre-merge.py (C3, M)
  - **Do**:
    1. Import `shlex` at top
    2. In `_run_command()`, replace `subprocess.run(cmd, shell=True, ...)` with `subprocess.run(shlex.split(cmd), ...)`. Add try/except for `ValueError` from shlex.split (malformed commands).
    3. In the quality command loop (line 122), change `for slot in ['build', 'test', 'lint']:` to `for slot in ['build', 'typecheck', 'test', 'lint']:` to add missing typecheck
    4. Add `try/except` around `main()` call: wrap body in `try:...except Exception as e: print(json.dumps({"error": str(e)})); sys.exit(1)`
  - **Files**: `plugins/ralph-parallel/scripts/validate-pre-merge.py`
  - **Done when**: No `shell=True` in file. `shlex.split` used. typecheck in quality loop. main() wrapped.
  - **Verify**: `grep -c 'shell=True' plugins/ralph-parallel/scripts/validate-pre-merge.py` returns 0. `grep 'typecheck' plugins/ralph-parallel/scripts/validate-pre-merge.py` shows typecheck in the loop.
  - **Commit**: `fix(scripts): remove shell=True, add typecheck to validate-pre-merge.py (C3)`
  - _Requirements: FR-2, FR-19_
  - _Design: Component D_

- [ ] 1.4 Add fsync to write-dispatch-state.py and validate max_teammates (C4, M)
  - **Do**:
    1. In `_atomic_write()`, add `f.flush()` and `os.fsync(f.fileno())` between `f.write('\n')` and `tmp_path = f.name` (before the `with` block exits)
    2. Add a `try/finally` to clean up tmp_path on failure: wrap `os.replace` in try, add `finally: if os.path.exists(tmp_path): os.unlink(tmp_path)` -- actually better: wrap in try/except, unlink in except, re-raise
    3. In `main()`, after args parsing, validate `args.max_teammates`: must be >= 1 and <= 20. Exit 1 if out of bounds.
    4. Wrap `main()` body in try/except
  - **Files**: `plugins/ralph-parallel/scripts/write-dispatch-state.py`
  - **Done when**: fsync called before os.replace. tmp file cleaned on failure. max_teammates validated. main() wrapped.
  - **Verify**: `grep -A2 'f.write' plugins/ralph-parallel/scripts/write-dispatch-state.py` shows flush+fsync. `grep 'max_teammates' plugins/ralph-parallel/scripts/write-dispatch-state.py` shows bounds check.
  - **Commit**: `fix(scripts): add fsync and max_teammates validation to write-dispatch-state.py (C4)`
  - _Requirements: FR-3, FR-20_
  - _Design: Component C_

- [ ] 1.5 Add file locking and path sanitization to dispatch-coordinator.sh (H2, H3, H8, H9)
  - **Do**:
    1. Add `_sanitize_name()` function that rejects names containing `..`, `/`, `\`, control chars, or starting with `-` or `.`. Pattern: `^[a-zA-Z0-9_-]+$`
    2. After deriving SPEC_NAME from TEAM_NAME (line 129), run `SPEC_NAME=$(_sanitize_name "$SPEC_NAME") || exit 0`
    3. In the scan loop, sanitize SCAN_SPEC: `SCAN_SPEC=$(_sanitize_name "$SCAN_SPEC" 2>/dev/null) || continue`
    4. Fix H8: Replace `COUNTER_FILE="/tmp/ralph-stop-${SPEC_NAME}-${SESSION_ID}"` (line 203) with `COUNTER_FILE=$(mktemp -t "ralph-stop-${SPEC_NAME}-XXXXXX")` -- but this breaks counter persistence. Instead: use a hash-based approach or keep the name but validate SPEC_NAME and SESSION_ID are sanitized. Since both are now sanitized, the predictable name is acceptable (the symlink attack requires controlling the name components).
    5. Fix H3: Where multiple jq calls read DISPATCH_STATE sequentially, combine into single jq call where practical. E.g., lines 199-200 combine into: `read STATUS DISPATCHED_AT <<< $(jq -r '[.status // "unknown", .dispatchedAt // "unknown"] | @tsv' "$DISPATCH_STATE")`
    6. Add `_lock_state()` and `_unlock_state()` functions using mkdir-based locking
    7. Wrap the `write_heartbeat()` function's jq+mv in lock/unlock
  - **Files**: `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: Path sanitization on all spec/team names. Counter file uses sanitized components. TOCTOU reduced. Heartbeat write locked.
  - **Verify**: `grep '_sanitize_name' plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh` shows usage. `grep '_lock_state\|_unlock_state' plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh` shows locking.
  - **Commit**: `fix(hooks): add locking, path sanitization to dispatch-coordinator.sh (H2, H3, H8, H9)`
  - _Requirements: FR-5, FR-6, FR-11, FR-12_
  - _Design: Component B, Component E_

- [ ] 1.6 Fix session-setup.sh: locking, reclaim race, rsync guard, quoting (H2, H5, H9, H10, M)
  - **Do**:
    1. Add `_sanitize_name()` function (same as 1.5)
    2. Guard rsync (lines 15-21): Add validation that `$DEV_SRC` is inside the git repo and `$CACHE_DIR` is under `~/.claude/plugins/cache/`. Add `[ -d "$DEV_SRC/.git" ] || [ -f "$DEV_SRC/hooks.json" ]` check before rsync to verify it's a real plugin source.
    3. Fix M: Line 32 `echo "export CLAUDE_SESSION_ID=$SESSION_ID"` -- quote the variable: `echo "export CLAUDE_SESSION_ID=\"$SESSION_ID\""`
    4. Add `_lock_state()` and `_unlock_state()` functions
    5. Wrap all jq+mv state writes (lines 142-143, 154-155, 175-178) in lock/unlock
    6. Fix H5: Add additional reclaim guard -- before reclaiming, verify the current session owns no OTHER active dispatches. Also ensure heartbeat check (line 112-135) is within the lock.
    7. Sanitize ACTIVE_SPEC after basename extraction (line 57): `ACTIVE_SPEC=$(_sanitize_name "$ACTIVE_SPEC" 2>/dev/null) || continue`
    8. Sanitize TEAM_SPEC in orphan cleanup (line 197): `TEAM_SPEC=$(_sanitize_name "$TEAM_SPEC" 2>/dev/null) || continue`
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: rsync source validated. SESSION_ID quoted. State writes locked. Reclaim race addressed. Names sanitized.
  - **Verify**: `grep -n 'sanitize_name' plugins/ralph-parallel/hooks/scripts/session-setup.sh` shows sanitization. `grep -n '_lock_state' plugins/ralph-parallel/hooks/scripts/session-setup.sh` shows locking. `grep 'CLAUDE_SESSION_ID=' plugins/ralph-parallel/hooks/scripts/session-setup.sh` shows quoted value.
  - **Commit**: `fix(hooks): harden session-setup.sh (H2, H5, H9, H10)`
  - _Requirements: FR-5, FR-8, FR-12, FR-13, FR-18_
  - _Design: Component B, Component E_

- [ ] 1.7 Fix teammate-idle-gate.sh: mktemp, path sanitize, quoting (H8, H9, M)
  - **Do**:
    1. Add `_sanitize_name()` function (same as 1.5)
    2. Sanitize SPEC_NAME after derivation (line 62): `SPEC_NAME=$(_sanitize_name "$SPEC_NAME") || exit 0`
    3. Fix M: Line 106 `for TASK_ID in $GROUP_TASKS` -- quote to prevent word splitting: use `while IFS= read -r TASK_ID; do ... done <<< "$GROUP_TASKS"` pattern instead
    4. Fix H8: Line 77 `COUNTER_FILE="/tmp/ralph-idle-${SPEC_NAME}-${TEAMMATE_NAME}"` -- sanitize TEAMMATE_NAME too: `TEAMMATE_NAME_SAFE=$(_sanitize_name "$TEAMMATE_NAME" 2>/dev/null) || TEAMMATE_NAME_SAFE="unknown"` then use in counter file path
  - **Files**: `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: Names sanitized. GROUP_TASKS iteration doesn't word-split. Counter file uses sanitized names.
  - **Verify**: `grep '_sanitize_name' plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh` shows usage. `grep 'while.*read.*TASK_ID' plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh` shows safe iteration.
  - **Commit**: `fix(hooks): harden teammate-idle-gate.sh (H8, H9)`
  - _Requirements: FR-11, FR-12, FR-18_
  - _Design: Component E_

- [ ] 1.8 Fix parse-and-partition.py: deep-copy deps, circular detection, duplicates (H6, H7, M)
  - **Do**:
    1. Fix H6: In `_build_groups_from_predefined()` (around line 730), deep-copy task dependencies before mutation: `task = {**task_map[tid], 'dependencies': list(task_map[tid]['dependencies'])}` instead of mutating in-place
    2. Fix H7: Add `_detect_circular_deps(tasks)` function using Kahn's algorithm (topological sort). Build adjacency list from task dependencies. If not all nodes processed, find and report cycle. Call from `main()` after parsing, before partitioning. Exit with code 4 if cycle detected.
    3. Fix M (duplicate task IDs): In `_parse_tasks()`, track seen task IDs. If duplicate found, print warning to stderr and skip the duplicate.
    4. Fix M (serial task deps): When groups exist but verify tasks don't, ensure serial tasks still get dependency on last parallel task.
    5. Wrap `main()` in try/except
  - **Files**: `plugins/ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Dependencies deep-copied. Circular deps detected (exit 4). Duplicates warned. main() wrapped.
  - **Verify**: `grep -c 'deepcopy\|list(.*dependencies' plugins/ralph-parallel/scripts/parse-and-partition.py` shows deep-copy. `grep 'circular\|cycle\|exit(4)' plugins/ralph-parallel/scripts/parse-and-partition.py` shows detection. `python3 plugins/ralph-parallel/scripts/parse-and-partition.py --help` exits 0.
  - **Commit**: `fix(scripts): deep-copy deps, add circular detection to parse-and-partition.py (H6, H7)`
  - _Requirements: FR-9, FR-10, FR-21_
  - _Design: Component F_

- [ ] 1.9 Add file locking to mark-tasks-complete.py (H4)
  - **Do**:
    1. Import `fcntl` (for file locking)
    2. Before reading tasks.md (line 90), acquire exclusive lock on tasks.md using `fcntl.flock(f, fcntl.LOCK_EX)`. Use a `with` block to ensure lock release.
    3. Hold lock through the read-modify-write cycle: lock, read content, modify, write back, release lock (close file).
    4. Add timeout: if lock not acquired in 10 seconds, print warning and proceed without lock (better than deadlock)
    5. Wrap `main()` in try/except
  - **Files**: `plugins/ralph-parallel/scripts/mark-tasks-complete.py`
  - **Done when**: tasks.md read-modify-write is locked. main() wrapped.
  - **Verify**: `grep 'fcntl\|LOCK_EX' plugins/ralph-parallel/scripts/mark-tasks-complete.py` shows locking.
  - **Commit**: `fix(scripts): add file locking to mark-tasks-complete.py (H4)`
  - _Requirements: FR-7_
  - _Design: Component B_

- [ ] 1.10 Fix merge.md step ordering and SKILL.md documentation (H11, H12)
  - **Do**:
    1. In merge.md: Move "Step 5: Pre-Merge Conflict Detection" to appear BEFORE "Step 4: Worktree Merge". Renumber: current Step 4 becomes Step 5, current Step 5 becomes Step 4. Current Step 6 becomes Step 6 (unchanged).
    2. In SKILL.md hooks table: Add `merge-guard.sh` row: `| merge-guard.sh | PreToolUse (Write/Edit) | Intercepts status="merged" writes, runs validate-pre-merge.py |`
    3. In SKILL.md hooks table: Add `teammate-idle-gate.sh` row: `| teammate-idle-gate.sh | TeammateIdle | Prevents teammates from going idle with uncompleted tasks |`
  - **Files**: `plugins/ralph-parallel/commands/merge.md`, `plugins/ralph-parallel/skills/parallel-workflow/SKILL.md`
  - **Done when**: Pre-merge check appears before worktree merge step. Both hooks documented.
  - **Verify**: `grep -n 'Step [45]' plugins/ralph-parallel/commands/merge.md` shows Pre-Merge before Worktree Merge. `grep -c 'merge-guard\|teammate-idle' plugins/ralph-parallel/skills/parallel-workflow/SKILL.md` returns 2+.
  - **Commit**: `fix(docs): reorder merge.md steps, add missing hooks to SKILL.md (H11, H12)`
  - _Requirements: FR-14, FR-15_
  - _Design: N/A_

- [ ] 1.11 Fix merge-guard.sh BASH_SOURCE inconsistency (M)
  - **Do**:
    1. Line 73: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd 2>/dev/null)" || true` -- this navigates from hooks/scripts/ up two levels to plugin root. Verify this is correct.
    2. Add fallback: if BASH_SOURCE is empty (sourced context), use `CLAUDE_PLUGIN_ROOT` env var: `SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd 2>/dev/null)}"`
    3. Add `|| true` after the `cd ... && pwd` to prevent set -e from killing script
  - **Files**: `plugins/ralph-parallel/hooks/scripts/merge-guard.sh`
  - **Done when**: SCRIPT_DIR resolution is robust with CLAUDE_PLUGIN_ROOT fallback.
  - **Verify**: `grep 'CLAUDE_PLUGIN_ROOT\|BASH_SOURCE' plugins/ralph-parallel/hooks/scripts/merge-guard.sh` shows both used.
  - **Commit**: `fix(hooks): fix BASH_SOURCE fallback in merge-guard.sh`
  - _Requirements: FR-18_

- [ ] 1.12 [VERIFY] Phase 1 checkpoint -- all critical and high fixes applied
  - **Do**: Verify all critical and high findings have been addressed
  - **Done when**: All C1-C4 and H1-H12 changes committed. No regressions.
  - **Verify**: `grep -r 'eval ' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/scripts/capture-baseline.sh | grep -v '_sanitize_cmd\|#\|function' | wc -l` returns 0 unguarded evals. `grep -c 'shell=True' plugins/ralph-parallel/scripts/validate-pre-merge.py` returns 0. `grep -c 'fsync' plugins/ralph-parallel/scripts/write-dispatch-state.py` returns 1+.
  - **Commit**: `fix(audit): complete critical and high fixes checkpoint`

## Phase 2: Refactoring (Medium Fixes)

After critical/high fixes verified, apply medium-priority fixes.

- [ ] 2.1 Fix Python KeyError guards in create-task-plan.py and build-teammate-prompt.py (M)
  - **Do**:
    1. In create-task-plan.py line 36: Change `partition['groups']` to `partition.get('groups', [])` (already done for verifyTasks and serialTasks -- just groups is unguarded)
    2. In build-teammate-prompt.py line 283: Change `partition['groups']` to `partition.get('groups', [])` in main()
    3. In build-teammate-prompt.py: Guard `group['name']` with `.get('name', 'unnamed')` where accessed
    4. In build-teammate-prompt.py: Guard `task["id"]`, `task["description"]` with `.get()` in build_prompt loop
    5. Guard `json.loads(args.quality_commands)` with try/except (line 293) -- on failure, default to empty dict
    6. Add try/except around both `main()` functions
  - **Files**: `plugins/ralph-parallel/scripts/create-task-plan.py`, `plugins/ralph-parallel/scripts/build-teammate-prompt.py`
  - **Done when**: All dict accesses use `.get()`. json.loads guarded. main() wrapped.
  - **Verify**: `grep -c "partition\['groups'\]" plugins/ralph-parallel/scripts/create-task-plan.py` returns 0. `grep "\.get(" plugins/ralph-parallel/scripts/build-teammate-prompt.py | wc -l` shows increased .get() usage.
  - **Commit**: `fix(scripts): add KeyError guards to create-task-plan.py, build-teammate-prompt.py`
  - _Requirements: FR-16, FR-17_

- [ ] 2.2 Fix remaining documentation issues (M-docs)
  - **Do**:
    1. In dispatch.md: Check `allowed-tools` header -- verify it lists `TaskCreate` (not just `Task`). Current line 4 shows `Task` -- confirm if this means TaskCreate or is a different tool name. If the platform tool is called `Task`, leave it. If audit says it should be `TaskCreate`, update.
    2. In SKILL.md: Add note that `verify-commit-provenance.py` exists but is not wired into any hook -- it's a standalone audit script run manually post-dispatch
    3. In SKILL.md: Document `qualityCommands.dev` as intentionally unused (discovered but not executed by quality gates)
    4. In SKILL.md: Add `.progress.md` template reference or note about its format
    5. In dispatch.md: If allowed-tools references `TaskGet` and it doesn't exist, note that `TaskList` is the correct tool
  - **Files**: `plugins/ralph-parallel/commands/dispatch.md`, `plugins/ralph-parallel/skills/parallel-workflow/SKILL.md`
  - **Done when**: Documentation matches code reality.
  - **Verify**: `grep -i 'verify-commit-provenance\|TaskCreate\|TaskGet\|progress.md\|qualityCommands.dev' plugins/ralph-parallel/skills/parallel-workflow/SKILL.md plugins/ralph-parallel/commands/dispatch.md` shows corrections.
  - **Commit**: `fix(docs): correct documentation inaccuracies (M-docs)`
  - _Requirements: FR-22_

- [ ] 2.3 Fix shell counter file race conditions and temp file leaks (M-shell, M-python)
  - **Do**:
    1. In dispatch-coordinator.sh and teammate-idle-gate.sh: The counter files use `echo > file` which is not atomic. Replace with: write to tmpfile then mv, same pattern as dispatch-state.
    2. In write-dispatch-state.py `_atomic_write`: Add try/except around the `os.replace` call. In except block, clean up tmp_path with `os.unlink(tmp_path)` before re-raising.
    3. In capture-baseline.sh: The `TMPFILE=$(mktemp ...)` pattern already has `|| rm -f "$TMPFILE"`. Verify all branches clean up. Check line 73-75 and 95-97 and 159-161 -- add `trap 'rm -f "$TMPFILE"' EXIT` before each mktemp block or wrap in function.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`, `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`, `plugins/ralph-parallel/scripts/write-dispatch-state.py`, `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: Counter writes use atomic pattern. Temp files cleaned on all error paths.
  - **Verify**: `grep -n 'mktemp\|TMPFILE' plugins/ralph-parallel/scripts/capture-baseline.sh` shows cleanup. `grep -A3 'os.replace' plugins/ralph-parallel/scripts/write-dispatch-state.py` shows try/except.
  - **Commit**: `fix(scripts): fix counter race conditions and temp file leaks`
  - _Requirements: FR-11_

- [ ] 2.4 Fix completedGroups name-matching and baselineSnapshot schema (M-integration)
  - **Do**:
    1. In task-completed-gate.sh and validate-pre-merge.py: completedGroups stores group names, but matching against group['name'] assumes exact string match. Add a note/comment that names are authoritative strings from dispatch-state.json, not derived.
    2. In task-completed-gate.sh: The baselineSnapshot access uses separate jq calls for `.baselineSnapshot.hardFail`, `.baselineSnapshot.exitCode`, `.baselineSnapshot.testCount` (lines 297-298, 313). Combine into single jq call to prevent TOCTOU.
    3. In SKILL.md dispatch state schema: Document that `baselineSnapshot` can be `null` (not captured) or an object with `{testCount, exitCode, hardFail, capturedAt, command, reason}`. Note that not all fields are present in all states.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`, `plugins/ralph-parallel/scripts/validate-pre-merge.py`, `plugins/ralph-parallel/skills/parallel-workflow/SKILL.md`
  - **Done when**: Baseline fields read in single jq call. Schema documented.
  - **Verify**: `grep -c 'baselineSnapshot' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh` shows fewer separate reads.
  - **Commit**: `fix(hooks): consolidate baselineSnapshot reads, document schema`
  - _Requirements: FR-6_

- [ ] 2.5 [VERIFY] Phase 2 checkpoint -- all medium fixes applied
  - **Do**: Verify all medium findings addressed
  - **Done when**: All medium fixes committed. Documentation accurate.
  - **Verify**: Run all existing Python tests: `cd plugins/ralph-parallel && python3 -m pytest scripts/test_*.py -v 2>&1 | tail -20`. All should pass.
  - **Commit**: `fix(audit): complete medium fixes checkpoint`

## Phase 3: Testing

- [ ] 3.1 Add tests for parse-and-partition.py: circular deps, duplicates, _parse_tasks_headers (H7, M)
  - **Do**:
    1. In test_parse_and_partition.py: Add test `test_circular_dependency_detection` -- create tasks.md where task A depends on B and B depends on A. Verify exit code 4.
    2. Add test `test_duplicate_task_ids` -- tasks.md with two `1.1` entries. Verify warning logged and second is skipped.
    3. Add test `test_parse_tasks_headers_edge_cases` -- test _parse_tasks_headers (or the function that extracts phase headers) with malformed headers, missing phases, empty phases.
    4. Add test `test_file_overlap_dependencies` -- two groups with overlapping files. Verify file ownership conflict resolution.
    5. Add test `test_multi_phase_partitioning` -- tasks.md with Phase 1 and Phase 2 [P] tasks. Verify correct grouping.
  - **Files**: `plugins/ralph-parallel/scripts/test_parse_and_partition.py`
  - **Done when**: 5 new test cases added and passing
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/test_parse_and_partition.py -v -k "circular or duplicate or headers or overlap or multi_phase" 2>&1 | tail -20`
  - **Commit**: `test(scripts): add parse-and-partition edge case tests`
  - _Requirements: AC-7.1, AC-7.4_

- [ ] 3.2 Add tests for write-dispatch-state.py: fsync verification (C4)
  - **Do**:
    1. In test_write_dispatch_state.py: Add test `test_atomic_write_calls_fsync` -- mock `os.fsync` and verify it's called during `_atomic_write`.
    2. Add test `test_atomic_write_cleans_up_on_failure` -- mock `os.replace` to raise, verify temp file is cleaned up.
    3. Add test `test_max_teammates_bounds` -- test that main() rejects max_teammates < 1 and > 20.
  - **Files**: `plugins/ralph-parallel/scripts/test_write_dispatch_state.py`
  - **Done when**: 3 new tests added and passing
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/test_write_dispatch_state.py -v -k "fsync or cleanup or bounds" 2>&1 | tail -20`
  - **Commit**: `test(scripts): add write-dispatch-state fsync and bounds tests`
  - _Requirements: AC-2.1_

- [ ] 3.3 Add tests for validate-pre-merge.py: no shell=True, typecheck (C3)
  - **Do**:
    1. In test_validate_pre_merge.py: Add test `test_run_command_no_shell_true` -- verify `_run_command` uses `shlex.split` not `shell=True`. Mock subprocess.run and check the call args.
    2. Add test `test_typecheck_included_in_quality_loop` -- create dispatch-state with `qualityCommands.typecheck` set. Run validation. Verify typecheck command is executed.
    3. Add test `test_malformed_command_handling` -- pass command with unmatched quotes to `_run_command`. Verify ValueError is caught.
  - **Files**: `plugins/ralph-parallel/scripts/test_validate_pre_merge.py`
  - **Done when**: 3 new tests added and passing
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/test_validate_pre_merge.py -v -k "shell_true or typecheck or malformed" 2>&1 | tail -20`
  - **Commit**: `test(scripts): add validate-pre-merge security and typecheck tests`
  - _Requirements: AC-1.3_

- [ ] 3.4 Add tests for build-teammate-prompt.py: KeyError, malformed input (M)
  - **Do**:
    1. In test_build_teammate_prompt.py: Add test `test_missing_group_keys` -- partition JSON with groups missing 'name' or 'taskDetails'. Verify no KeyError.
    2. Add test `test_malformed_quality_commands_json` -- pass invalid JSON string to --quality-commands. Verify graceful fallback.
    3. Add test `test_task_missing_fields` -- taskDetails entries missing 'id', 'description', 'files'. Verify prompt still builds.
  - **Files**: `plugins/ralph-parallel/scripts/test_build_teammate_prompt.py`
  - **Done when**: 3 new tests added and passing
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/test_build_teammate_prompt.py -v -k "missing or malformed" 2>&1 | tail -20`
  - **Commit**: `test(scripts): add build-teammate-prompt resilience tests`
  - _Requirements: AC-4.1_

- [ ] 3.5 Add tests for mark-tasks-complete.py: concurrent access (H4)
  - **Do**:
    1. In test_mark_tasks_complete.py: Add test `test_concurrent_write_locking` -- spawn two threads that both try to mark different tasks complete simultaneously. Verify both succeed without corruption.
    2. Add test `test_main_error_handling` -- invoke main() with missing files, verify it doesn't crash with unhandled exception.
  - **Files**: `plugins/ralph-parallel/scripts/test_mark_tasks_complete.py`
  - **Done when**: 2 new tests added and passing
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/test_mark_tasks_complete.py -v -k "concurrent or error_handling" 2>&1 | tail -20`
  - **Commit**: `test(scripts): add mark-tasks-complete concurrent access tests`
  - _Requirements: AC-3.2_

- [ ] 3.6 [VERIFY] All tests passing
  - **Do**: Run full test suite
  - **Done when**: All tests pass
  - **Verify**: `cd plugins/ralph-parallel && python3 -m pytest scripts/test_*.py -v 2>&1 | tail -30`
  - **Commit**: `test(audit): all audit fix tests passing`

## Phase 4: Quality Gates

- [ ] 4.1 Shellcheck validation on all modified shell scripts
  - **Do**: Run shellcheck on all modified shell scripts. Fix any new warnings introduced.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`, `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`, `plugins/ralph-parallel/hooks/scripts/session-setup.sh`, `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`, `plugins/ralph-parallel/hooks/scripts/merge-guard.sh`, `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Verify**: `shellcheck plugins/ralph-parallel/hooks/scripts/*.sh plugins/ralph-parallel/scripts/capture-baseline.sh 2>&1 | grep -c 'error' || echo 0` returns 0 errors
  - **Done when**: No shellcheck errors
  - **Commit**: `fix(scripts): address shellcheck warnings` (if needed)

- [ ] 4.2 Python linting on all modified Python scripts
  - **Do**: Run any available Python linter (ruff, flake8, or pyright) on modified files. Fix issues.
  - **Files**: `plugins/ralph-parallel/scripts/*.py`
  - **Verify**: `python3 -m py_compile plugins/ralph-parallel/scripts/validate-pre-merge.py plugins/ralph-parallel/scripts/write-dispatch-state.py plugins/ralph-parallel/scripts/parse-and-partition.py plugins/ralph-parallel/scripts/mark-tasks-complete.py plugins/ralph-parallel/scripts/create-task-plan.py plugins/ralph-parallel/scripts/build-teammate-prompt.py && echo "OK"` prints OK
  - **Done when**: All Python files compile without syntax errors
  - **Commit**: `fix(scripts): address linting issues` (if needed)

- [ ] 4.3 Create PR and verify
  - **Do**: Push branch, create PR referencing issue #8 with full audit finding coverage
  - **Verify**: `gh pr checks --watch` all green (or no CI configured)
  - **Done when**: PR ready for review

## Notes

- **POC shortcuts taken**: Command sanitizer is defense-in-depth, not a complete sandbox. Commands from qualityCommands and tasks.md are inherently trusted (set by the coordinator). The sanitizer catches accidental or tampered injection.
- **Production TODOs**: Consider moving to a proper command allowlist config file. Consider adding integration tests that exercise the full hook pipeline.
- **Scope boundary**: The audit mentions "Dynamic fields undocumented" and "Dead qualityCommands.dev" -- these are documentation-only fixes addressed in task 2.2 and 2.4.
