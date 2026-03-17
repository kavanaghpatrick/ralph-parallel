---
spec: deep-audit-fixes
phase: tasks
total_tasks: 26
created: 2026-03-17
generated: auto
---

# Tasks: deep-audit-fixes

## Phase 1: Make It Work (CRITICAL + HIGH fixes)

Focus: Fix all 3 critical and 5 high-severity findings. Skip tests first, verify existing tests still pass at checkpoint.

- [x] 1.1 Harden _sanitize_cmd() in task-completed-gate.sh (C1a)
  - **Do**: Add rejection for command separators (`;`, `&&`, `||`) and pipes (`|`) to `_sanitize_cmd()` function (lines 17-35). Add a new check after the existing command substitution check (line 28). The pattern should reject `;`, `|`, `&&`, `||` but NOT `--` (flag separators) or `=` (assignments).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: `_sanitize_cmd "echo hello; rm -rf /"` returns 1, `_sanitize_cmd "pnpm test"` returns 0
  - **Verify**: `bash -c 'source <(sed -n "17,35p" plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh) && _sanitize_cmd "pnpm test" && echo OK'`
  - **Commit**: `fix(security): harden _sanitize_cmd to reject command separators and pipes`
  - _Requirements: FR-1_
  - _Design: Component A_

- [x] 1.2 Harden _sanitize_cmd() in capture-baseline.sh (C1b)
  - **Do**: Apply identical changes to `_sanitize_cmd()` in capture-baseline.sh (lines 19-37). Both copies must match exactly.
  - **Files**: `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: Both `_sanitize_cmd` functions are identical between the two files
  - **Verify**: `diff <(sed -n '/^_sanitize_cmd/,/^}/p' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh) <(sed -n '/^_sanitize_cmd/,/^}/p' plugins/ralph-parallel/scripts/capture-baseline.sh)`
  - **Commit**: `fix(security): harden _sanitize_cmd in capture-baseline.sh to match gate`
  - _Requirements: FR-1_
  - _Design: Component A_

- [x] 1.3 Validate COMPLETED_SPEC_TASK format in task-completed-gate.sh (C2a)
  - **Do**: After line 98 where COMPLETED_SPEC_TASK is extracted, add validation that it matches `^[0-9]+\.[0-9]+$`. If not, exit 0 (allow through). This protects all subsequent grep -E and sed uses on lines 110, 151, 233. Also change `grep -qE "^\s*- \[ \] ${TASK_ID}\b"` to use `grep -F` where the TASK_ID is used as a fixed string in teammate-idle-gate.sh.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: A TASK_ID of `1.1` passes validation, a TASK_ID of `$(rm -rf /)` is rejected
  - **Verify**: `grep -c 'grep -qE.*COMPLETED_SPEC_TASK' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Commit**: `fix(security): validate COMPLETED_SPEC_TASK format before regex use`
  - _Requirements: FR-2_
  - _Design: Component B_

- [x] 1.4 Validate TASK_ID format in teammate-idle-gate.sh (C2b)
  - **Do**: In the while loop at line 130, after `TASK_ID` is read, validate it matches `^[0-9]+\.[0-9]+$` before using it in grep patterns on lines 133-134. If invalid, `continue` to skip. Also change `grep -qE "^\s*- \[ \] ${TASK_ID}\b"` on line 133 to use a validated fixed string approach, and fix the `sed` on line 134 that uses `${TASK_ID}` unescaped.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: TASK_ID values like `1.1` work, values with regex metacharacters are skipped
  - **Verify**: `grep -c 'grep -qE.*[0-9]' plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Commit**: `fix(security): validate TASK_ID format in teammate-idle-gate.sh`
  - _Requirements: FR-2_
  - _Design: Component B_

- [x] 1.5 Validate SESSION_ID before file path use (C3)
  - **Do**: In dispatch-coordinator.sh after SESSION_ID is parsed (around line 124), add validation: `if [ -n "$SESSION_ID" ] && ! printf '%s' "$SESSION_ID" | grep -qE '^[a-zA-Z0-9_-]+$'; then SESSION_ID=""; fi`. Apply the same validation in teammate-idle-gate.sh where SESSION_ID would be used in COUNTER_FILE path (line 101). Also apply in session-setup.sh after SESSION_ID is parsed (line 99).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`, `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`, `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: SESSION_ID with path traversal chars (e.g., `../etc/passwd`) is cleared to empty
  - **Verify**: `grep -c "grep -qE.*a-zA-Z0-9" plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `fix(security): validate SESSION_ID before use in file paths`
  - _Requirements: FR-3_
  - _Design: Component B_

- [x] 1.6 Fix pipeline failure in session-setup.sh orphan cleanup (H1)
  - **Do**: On line 270, change `TEAM_SPEC=$(basename "$team_dir" | sed 's/-parallel$//')` to `TEAM_SPEC=$(basename "$team_dir" | sed 's/-parallel$//') || continue`. This prevents the `set -eo pipefail` from crashing the entire script when basename/sed fails. The `|| continue` on line 271 already handles `_sanitize_name` failure, but the pipeline on 270 needs its own guard.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: Line 270 has `|| continue` at the end
  - **Verify**: `grep -n 'basename.*sed.*continue' plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `fix(robustness): guard pipeline failure in session-setup orphan cleanup`
  - _Requirements: FR-6_
  - _Design: Component D_

- [x] 1.7 Validate SHA before git rev-list --count (H2)
  - **Do**: In session-setup.sh `_ralph_update_check()` function, before line 87 (`behind=$(git -C "$mktplace_dir" rev-list ...)`), add a check: `if ! git -C "$mktplace_dir" cat-file -e "$installed_sha" 2>/dev/null; then return 0; fi`. This prevents rev-list from failing on orphaned/garbage-collected SHAs.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: An invalid SHA like `deadbeef1234` causes early return, not error
  - **Verify**: `grep -A2 'cat-file' plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `fix(robustness): validate SHA exists before rev-list count in update check`
  - _Requirements: FR-7_
  - _Design: Component D_

- [x] 1.8 Fix printf '%b' escape sequence injection (H3)
  - **Do**: In teammate-idle-gate.sh, change line 135 from `UNCOMPLETED="${UNCOMPLETED}  - ${TASK_ID}: ${DESC}\n"` to use a real newline (either via `$'\n'` or by breaking the string across lines). Change line 158 from `printf '%b\n' "$UNCOMPLETED"` to `printf '%s' "$UNCOMPLETED"`. The `\n` embedded in the string via `$'\n'` is already a real newline character, so `%s` will print it correctly.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: `printf '%b'` no longer appears in the file, and task descriptions with `\t` or `\n` are printed literally
  - **Verify**: `grep -c "printf '%b'" plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh | grep -q '^0$' && echo OK`
  - **Commit**: `fix(robustness): use printf %s to prevent escape sequence injection`
  - _Requirements: FR-8_
  - _Design: Component D_

- [x] 1.9 Replace here-strings with POSIX heredocs (H4a -- file-ownership-guard.sh)
  - **Do**: Replace `done <<< "$OWNED_FILES"` on line 89 with a POSIX heredoc. Since the while loop sets `ALLOWED=true` which must propagate outside the loop, use a heredoc (not a pipe, which creates a subshell). Replace with: `done <<EOF_OWNED\n${OWNED_FILES}\nEOF_OWNED`
  - **Files**: `plugins/ralph-parallel/hooks/scripts/file-ownership-guard.sh`
  - **Done when**: No `<<<` appears in the file, and the file ownership check still works
  - **Verify**: `grep -c '<<<' plugins/ralph-parallel/hooks/scripts/file-ownership-guard.sh | grep -q '^0$' && echo OK`
  - **Commit**: `fix(posix): replace here-string with heredoc in file-ownership-guard.sh`
  - _Requirements: FR-4_
  - _Design: Component C_

- [x] 1.10 Replace here-strings with POSIX heredocs (H4b -- teammate-idle-gate.sh)
  - **Do**: Replace `done <<< "$GROUP_TASKS"` on line 137 with a POSIX heredoc. The loop sets `UNCOMPLETED` which must propagate, so use heredoc not pipe.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: No `<<<` appears in the file
  - **Verify**: `grep -c '<<<' plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh | grep -q '^0$' && echo OK`
  - **Commit**: `fix(posix): replace here-string with heredoc in teammate-idle-gate.sh`
  - _Requirements: FR-4_
  - _Design: Component C_

- [x] 1.11 Replace here-strings and bash arrays (H4c -- task-completed-gate.sh)
  - **Do**: Replace lines 250-251 which use `IFS=',' read -ra FILE_LIST <<< "$TASK_FILES"` and `for f in "${FILE_LIST[@]}"`. Replace with POSIX: save old IFS, set `IFS=','`, iterate with `for f in $TASK_FILES; do`, restore IFS. Or use `echo "$TASK_FILES" | tr ',' '\n'` piped to a while loop with heredoc to preserve MISSING variable. Since MISSING must propagate out of the loop, restructure to use a heredoc approach or a temp file.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: No `<<<`, `read -ra`, or `${FILE_LIST[@]}` in the file
  - **Verify**: `grep -cE '<<<|read -ra|\$\{FILE_LIST' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh | grep -q '^0$' && echo OK`
  - **Commit**: `fix(posix): replace bash arrays and here-string in task-completed-gate.sh`
  - _Requirements: FR-4, FR-5_
  - _Design: Component C_

- [x] 1.12 Add race condition documentation (H5)
  - **Do**: Add documentation comments to the counter file read/write functions in dispatch-coordinator.sh (lines 49-86) and teammate-idle-gate.sh (lines 30-62). Add a comment block explaining the known race condition: "NOTE: Counter read-modify-write is not atomic. Two concurrent sessions could read the same value and both increment to N+1 instead of N+2. This is acceptable because the counter is a safety valve, not a precise count. Worst case: one extra block cycle."
  - **Files**: `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`, `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: Both files have race condition documentation near counter functions
  - **Verify**: `grep -c 'not atomic' plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Commit**: `docs: document known race condition in counter file operations`
  - _Requirements: FR-9_
  - _Design: Component D_

- [x] 1.13 POC Checkpoint -- CRITICAL + HIGH
  - **Do**: Run ALL 5 test suites to verify no regressions from CRITICAL and HIGH fixes. All 328 tests must pass.
  - **Done when**: All test suites pass with 0 failures
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/ -q && bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh`
  - **Commit**: `fix(audit): complete CRITICAL and HIGH audit fixes`

## Phase 2: MEDIUM Priority Fixes

- [x] 2.1 Add timeout command fallback (M1)
  - **Do**: In session-setup.sh, before the `timeout 15 git ...` call on line 68, add a check: `if ! command -v timeout >/dev/null 2>&1; then timeout() { shift; "$@"; }; fi`. This creates a no-op timeout function that just runs the command without a time limit if `timeout` is not available (common on macOS without coreutils).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: Script works on systems without `timeout` command
  - **Verify**: `grep -c 'command -v timeout' plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `fix(compat): add timeout command fallback for macOS`
  - _Requirements: FR-10_
  - _Design: Component E_

- [x] 2.2 Query marketplace by name instead of [0] (M2)
  - **Do**: In session-setup.sh line 59, change `jq -r '.[0].path // empty'` to `jq -r '.[] | select(.name == "ralph-parallel-marketplace" or .name == "ralph-parallel") | .path // empty' | head -1`. This finds the correct marketplace entry by name rather than assuming it's the first entry.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: Marketplace lookup works regardless of entry position in array
  - **Verify**: `grep -c 'select(.name' plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `fix(robustness): query marketplace by name instead of array index`
  - _Requirements: FR-11_
  - _Design: Component E_

- [ ] 2.3 Anchor test count parsing patterns (M3)
  - **Do**: In the `parse_test_count()` functions in both task-completed-gate.sh and capture-baseline.sh, make patterns more specific to avoid false matches. Use `[[:space:]]` POSIX character classes instead of `\s`. For the "5 passed" pattern, anchor with word boundaries or preceding space to avoid matching "105 passed" as "5 passed" from substring. Change `grep -oE '[0-9]+ passed'` to `grep -oE '(^|[[:space:]])[0-9]+ passed'`.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`, `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: Both parse_test_count functions use anchored patterns with POSIX char classes
  - **Verify**: `grep -c '\[:space:\]' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Commit**: `fix(parsing): use anchored POSIX patterns for test count extraction`
  - _Requirements: FR-12_
  - _Design: Component E_

- [x] 2.4 Add counter file cleanup on terminal status (M4)
  - **Do**: In teammate-idle-gate.sh, when the teammate's group is found in `completedGroups` (line 108-111), add `rm -f "$COUNTER_FILE" 2>/dev/null` before `exit 0` to clean up the block counter file. Also add cleanup when all tasks are complete (line 139-141).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: Counter file is cleaned up when group is complete or all tasks done
  - **Verify**: `grep -c 'rm -f.*COUNTER_FILE' plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Commit**: `fix(cleanup): remove idle counter file on terminal status`
  - _Requirements: FR-13_
  - _Design: Component E_

- [x] 2.5 Add encoding='utf-8' to Python file operations (M6)
  - **Do**: In all production Python files, add `encoding='utf-8'` to `open()` calls that don't have it. Also add to `read_text()` and `write_text()` calls. Files: validate-pre-merge.py (lines 86, 93), write-dispatch-state.py (line 50, 142), build-teammate-prompt.py (line 276), create-task-plan.py (line 116), mark-tasks-complete.py (lines 40, 95, 99, 146), verify-commit-provenance.py (line 169), validate-tasks-format.py (line 386), parse-and-partition.py (lines 68, 96, 117, 134, 1184).
  - **Files**: `plugins/ralph-parallel/scripts/validate-pre-merge.py`, `plugins/ralph-parallel/scripts/write-dispatch-state.py`, `plugins/ralph-parallel/scripts/build-teammate-prompt.py`, `plugins/ralph-parallel/scripts/create-task-plan.py`, `plugins/ralph-parallel/scripts/mark-tasks-complete.py`, `plugins/ralph-parallel/scripts/verify-commit-provenance.py`, `plugins/ralph-parallel/scripts/validate-tasks-format.py`, `plugins/ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: All `open()` calls in production Python files have `encoding='utf-8'`
  - **Verify**: `grep -n "open(" plugins/ralph-parallel/scripts/{validate-pre-merge,write-dispatch-state,build-teammate-prompt,create-task-plan,mark-tasks-complete,verify-commit-provenance,parse-and-partition}.py | grep -v encoding | grep -v test_ | grep -v '#' | wc -l | tr -d ' '`
  - **Commit**: `fix(encoding): add explicit utf-8 encoding to all Python file operations`
  - _Requirements: FR-15_
  - _Design: Component E_

- [ ] 2.6 Add BASH_SOURCE fallback in test scripts (M8)
  - **Do**: In test_stop_hook.sh line 26 and test_session_isolation.sh line 27, change `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` to `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"`. merge-guard.sh already has this fallback pattern.
  - **Files**: `plugins/ralph-parallel/scripts/test_stop_hook.sh`, `plugins/ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: Both test scripts use `${BASH_SOURCE[0]:-$0}` pattern
  - **Verify**: `grep -c 'BASH_SOURCE\[0\]:-\$0' plugins/ralph-parallel/scripts/test_stop_hook.sh plugins/ralph-parallel/scripts/test_session_isolation.sh`
  - **Commit**: `fix(compat): add $0 fallback for BASH_SOURCE in test scripts`
  - _Requirements: FR-17_
  - _Design: Component E_

- [ ] 2.7 Replace .tmp.$$ with mktemp (M9)
  - **Do**: In session-setup.sh, replace all `"${DISPATCH_FILE}.tmp.$$"` patterns (lines 215, 227, 250) with `$(mktemp "${DISPATCH_FILE}.XXXXXX")`. Same for dispatch-coordinator.sh line 100 (`"${state_file}.tmp.$$"` to `$(mktemp "${state_file}.XXXXXX")`). Use a local variable for the temp file and ensure cleanup on failure (`|| rm -f "$tmpfile"`).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`, `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: No `.tmp.$$` patterns remain in these files
  - **Verify**: `grep -c 'tmp\.\$\$' plugins/ralph-parallel/hooks/scripts/session-setup.sh plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh | grep -q ':0$' || echo 'STILL HAS tmp.$$'`
  - **Commit**: `fix(security): replace predictable temp files with mktemp`
  - _Requirements: FR-18_
  - _Design: Component E_

- [ ] 2.8 Fix verify command backtick stripping (M10)
  - **Do**: In task-completed-gate.sh line 120, the `sed 's/` `//g'` strips ALL backticks from the verify command, but should only strip the outer pair (if present). Change to strip only leading/trailing backticks: `sed 's/^` `//;s/` `$//'` or use a more targeted approach. Example: `` `pnpm test` `` should become `pnpm test`, but `echo \`date\`` should keep its backticks (though this would be rejected by sanitizer anyway).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Outer backtick pairs are stripped but internal backticks preserved
  - **Verify**: `grep -c "s/\`//g" plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh | grep -q '^0$' && echo OK`
  - **Commit**: `fix(parsing): strip only outer backtick delimiters from verify commands`
  - _Requirements: FR-19_
  - _Design: Component E_

## Phase 3: Testing

- [ ] 3.1 Add sanitizer tests to test_gate.sh
  - **Do**: Add test cases to test_gate.sh for C1 (command separator rejection). Test that verify commands containing `;`, `&&`, `||`, `|` are rejected. Test that clean commands like `pnpm test`, `python3 -m pytest` still pass.
  - **Files**: `plugins/ralph-parallel/hooks/scripts/test_gate.sh`
  - **Done when**: At least 4 new test cases for sanitizer (one per separator type)
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh`
  - **Commit**: `test(gate): add command sanitizer injection tests`
  - _Requirements: AC-1.1, AC-1.3_

- [ ] 3.2 Add TASK_ID validation tests to test_teammate_idle_gate.sh
  - **Do**: Add test case where GROUP_TASKS contains a malformed task ID with regex metacharacters. Verify the hook handles it gracefully (skip or allow, not crash).
  - **Files**: `plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh`
  - **Done when**: Test covers malformed TASK_ID scenario
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh`
  - **Commit**: `test(idle): add malformed TASK_ID handling test`
  - _Requirements: AC-2.1_

- [ ] 3.3 Run full test suite regression check
  - **Do**: Run all 5 test suites to verify all medium fixes maintain backward compatibility. Compare test count to baseline (328).
  - **Done when**: All 328+ tests pass
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/ -q && bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh`
  - **Commit**: `test(audit): verify all tests pass after medium fixes`

## Phase 4: Quality Gates

- [ ] 4.1 Local quality check
  - **Do**: Run shellcheck on all modified shell scripts. Run Python type checks. Verify no regressions.
  - **Verify**: `command -v shellcheck >/dev/null && shellcheck plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh plugins/ralph-parallel/hooks/scripts/session-setup.sh plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/file-ownership-guard.sh plugins/ralph-parallel/scripts/capture-baseline.sh || echo 'shellcheck not available'`
  - **Done when**: No shellcheck errors (or shellcheck not available), all tests pass
  - **Commit**: `fix(audit): address shellcheck/lint findings` (if needed)

- [ ] 4.2 [VERIFY] Final verification and PR
  - **Do**: Run complete test suite one final time. Verify all 18 audit findings are addressed. Create PR referencing issue #11.
  - **Verify**: `python3 -m pytest plugins/ralph-parallel/scripts/ -q && bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh`
  - **Done when**: All tests pass, PR created with issue reference

## Notes

- **POC shortcuts taken**: Documentation-only fix for H5 (race conditions), skip M7 (Python __future__ annotations not needed on 3.11+), skip M5 (already addressed by test-isolation spec)
- **Production TODOs**: Consider extracting `_sanitize_cmd()` into a shared sourced file to eliminate duplication
- **Test baseline**: 328 tests (155 pytest + 10 gate + 7 idle + 43 session + 113 stop)
