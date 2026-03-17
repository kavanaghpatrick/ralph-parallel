# Tasks: Portability Fixes and Auto-Update

## Quality Commands

- **Build**: N/A
- **Typecheck**: N/A
- **Lint**: N/A
- **Test**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && python3 -m pytest plugins/ralph-parallel/scripts/`

## Phase 1: Make It Work (POC)

Focus: Apply all portability fixes and auto-update feature. Each task owns specific files to enable parallel dispatch.

- [ ] 1.1 Fix grep -qP and sed ANSI-C quoting in task-completed-gate.sh
  - **Do**:
    1. Replace `grep -qP '\x00'` (line 20) with POSIX byte-count comparison:
       ```bash
       if [ "$(printf '%s' "$cmd" | wc -c)" != "$(printf '%s' "$cmd" | tr -d '\0' | wc -c)" ]; then
       ```
    2. Before line 363, insert `ESC=$(printf '\033')`
    3. Replace line 363 `sed $'s/\x1b\\[[0-9;]*m//g'` with `sed "s/${ESC}\[[0-9;]*m//g"`
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: No `grep -qP` or `sed $'` in the file; `_sanitize_cmd` uses `wc -c`/`tr` comparison
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh 2>&1 | tail -5`
  - **Commit**: `fix(security): replace grep -qP and sed ANSI-C quoting in task-completed-gate.sh`
  - _Requirements: FR-1 (AC-1.1, AC-1.3), FR-8 (AC-5.1, AC-5.3)_
  - _Design: C1 Null Byte Sanitizer, C5 sed ANSI-C Quoting_

- [x] 1.2 Fix grep -qP, sed ANSI-C quoting, and [[ ]] in capture-baseline.sh
  - **Do**:
    1. Replace `grep -qP '\x00'` (line 21) with identical POSIX byte-count comparison as task 1.1
    2. Replace `while [[ $# -gt 0 ]]` (line 40) with `while [ $# -gt 0 ]`
    3. Before line 110, insert `ESC=$(printf '\033')`
    4. Replace line 110 `sed $'s/\x1b\\[[0-9;]*m//g'` with `sed "s/${ESC}\[[0-9;]*m//g"`
  - **Files**: `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: No `grep -qP`, `[[ ]]`, or `sed $'` in the file; `_sanitize_cmd` matches task-completed-gate.sh exactly
  - **Verify**: `diff <(grep -A 15 '_sanitize_cmd()' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh) <(grep -A 15 '_sanitize_cmd()' plugins/ralph-parallel/scripts/capture-baseline.sh) && echo "PASS: _sanitize_cmd identical" || echo "FAIL: _sanitize_cmd drift"`
  - **Commit**: `fix(portability): replace grep -qP, sed ANSI-C, and [[ ]] in capture-baseline.sh`
  - _Requirements: FR-1 (AC-1.2, AC-1.3, AC-1.4), FR-7 (AC-4.2), FR-8 (AC-5.2, AC-5.3)_
  - _Design: C1, C4, C5_

- [ ] 1.3 Fix /tmp, [[ ]], and echo -e in teammate-idle-gate.sh
  - **Do**:
    1. After line 12 (`set -euo pipefail`), add `_RALPH_TMP="${TMPDIR:-/tmp}"`
    2. Replace line 71 `if [ -z "$TEAM_NAME" ] || [[ "$TEAM_NAME" != *-parallel ]]; then` / `exit 0` / `fi` with:
       ```bash
       if [ -z "$TEAM_NAME" ]; then
         exit 0
       fi
       case "$TEAM_NAME" in
         *-parallel) ;;
         *) exit 0 ;;
       esac
       ```
    3. Replace line 92 `COUNTER_FILE="/tmp/ralph-idle-..."` with `COUNTER_FILE="$_RALPH_TMP/ralph-idle-..."`
    4. Replace line 149 `echo -e "$UNCOMPLETED" >&2` with `printf '%b\n' "$UNCOMPLETED" >&2`
  - **Files**: `plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Done when**: No `/tmp/ralph-`, `[[ ]]`, or `echo -e` in the file
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh 2>&1 | tail -5`
  - **Commit**: `fix(portability): replace /tmp, [[ ]], echo -e in teammate-idle-gate.sh`
  - _Requirements: FR-2 (AC-2.2, AC-2.3), FR-7 (AC-4.1), FR-9 (AC-6.1)_
  - _Design: C2, C4, C6_

- [x] 1.4 Fix /tmp and error comments in dispatch-coordinator.sh
  - **Do**:
    1. After line 15 (`set -euo pipefail`), add `_RALPH_TMP="${TMPDIR:-/tmp}"`
    2. Line 46 comment: change `This means /tmp permission denied` to `This means temp dir permission denied`
    3. Line 75 comment: change `if /tmp write fails` to `if temp dir write fails`
    4. Line 219: change `COUNTER_FILE="/tmp/ralph-stop-..."` to `COUNTER_FILE="$_RALPH_TMP/ralph-stop-..."`
  - **Files**: `plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: No `/tmp/ralph-` or `/tmp permission` in the file
  - **Verify**: `bash plugins/ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -5`
  - **Commit**: `fix(portability): replace /tmp with TMPDIR in dispatch-coordinator.sh`
  - _Requirements: FR-2 (AC-2.1, AC-2.3), FR-5 (AC-2.9)_
  - _Design: C2_

- [ ] 1.5 [VERIFY] Quality checkpoint: test suites pass after production script changes
  - **Do**: Run all 4 shell test suites + Python tests to catch regressions from tasks 1.1-1.4
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && python3 -m pytest plugins/ralph-parallel/scripts/`
  - **Done when**: All commands exit 0
  - **Commit**: `chore(portability): pass quality checkpoint` (only if fixes needed)

- [ ] 1.6 Fix /tmp in test_stop_hook.sh
  - **Do**:
    1. After `set -uo pipefail` (line 12), add `_RALPH_TMP="${TMPDIR:-/tmp}"`
    2. Replace all `/tmp/ralph-stop-` references with `$_RALPH_TMP/ralph-stop-`:
       - Lines 108-110: cleanup `rm -f` commands
       - Line 281: `local counter_file="/tmp/ralph-stop-test-spec-sess-A"`
       - Line 349: same
       - Line 622: same
       - Line 662: same
       - Line 697: same
       - Lines 739-760: test for empty SESSION_ID counter file path + assertion message
  - **Files**: `plugins/ralph-parallel/scripts/test_stop_hook.sh`
  - **Done when**: No `/tmp/ralph-` in the file
  - **Verify**: `bash plugins/ralph-parallel/scripts/test_stop_hook.sh 2>&1 | tail -5`
  - **Commit**: `fix(portability): replace /tmp with TMPDIR in test_stop_hook.sh`
  - _Requirements: FR-4 (AC-2.5, AC-2.8)_
  - _Design: C2_

- [x] 1.7 Fix /tmp in test_teammate_idle_gate.sh
  - **Do**:
    1. Near top of file (after set/unset lines), add `_RALPH_TMP="${TMPDIR:-/tmp}"`
    2. Replace all `/tmp/ralph-idle-` references with `$_RALPH_TMP/ralph-idle-`:
       - Line 77: cleanup `rm -f`
       - Line 92: write counter file
       - Line 107: write counter file
       - Line 121: cleanup `rm -f`
       - Line 160: final cleanup `rm -f`
  - **Files**: `plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh`
  - **Done when**: No `/tmp/ralph-` in the file
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh 2>&1 | tail -5`
  - **Commit**: `fix(portability): replace /tmp with TMPDIR in test_teammate_idle_gate.sh`
  - _Requirements: FR-4 (AC-2.6, AC-2.8)_
  - _Design: C2_

- [ ] 1.8 Fix /tmp in test_session_isolation.sh
  - **Do**:
    1. Near top of file (after set/unset lines), add `_RALPH_TMP="${TMPDIR:-/tmp}"`
    2. Line 84: replace `rm -f /tmp/ralph-stop-*` with `rm -f "$_RALPH_TMP"/ralph-stop-*`
  - **Files**: `plugins/ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: No `/tmp/ralph-` in the file
  - **Verify**: `bash plugins/ralph-parallel/scripts/test_session_isolation.sh 2>&1 | tail -5`
  - **Commit**: `fix(portability): replace /tmp with TMPDIR in test_session_isolation.sh`
  - _Requirements: FR-4 (AC-2.7, AC-2.8)_
  - _Design: C2_

- [x] 1.9 Fix /tmp in dispatch.md and bump marketplace.json version
  - **Do**:
    1. In `plugins/ralph-parallel/commands/dispatch.md`, replace `/tmp/$specName-partition.json` with `${TMPDIR:-/tmp}/$specName-partition.json` at 4 locations (lines 69, 96, 136, 178)
    2. In `.claude-plugin/marketplace.json`, change `"version": "0.2.3"` to `"version": "0.2.4"` (line 13)
  - **Files**: `plugins/ralph-parallel/commands/dispatch.md`, `.claude-plugin/marketplace.json`
  - **Done when**: No `/tmp/$specName` in dispatch.md; marketplace.json version is `0.2.4`
  - **Verify**: `diff <(jq -r '.plugins[0].version' .claude-plugin/marketplace.json) <(jq -r '.version' plugins/ralph-parallel/.claude-plugin/plugin.json) && echo "PASS: versions match" || echo "FAIL: version mismatch"`
  - **Commit**: `fix(portability): replace /tmp in dispatch.md, sync marketplace.json version`
  - _Requirements: FR-3 (AC-2.4), FR-6 (AC-3.1, AC-3.2)_
  - _Design: C2, C3_

- [ ] 1.10 [VERIFY] Quality checkpoint: all test suites pass after test script updates
  - **Do**: Run all test suites to verify tasks 1.6-1.9 didn't break anything
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && python3 -m pytest plugins/ralph-parallel/scripts/`
  - **Done when**: All commands exit 0
  - **Commit**: `chore(portability): pass quality checkpoint` (only if fixes needed)

- [ ] 1.11 Add auto-update notification to session-setup.sh
  - **Do**:
    1. Insert auto-update check block AFTER the dev-source rsync block (line 37) and BEFORE `INPUT=$(cat)` (line 41)
    2. Wrap in `if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then ... fi` guard
    3. Define `_ralph_update_check()` function with:
       - Cache dir: `${XDG_CACHE_HOME:-$HOME/.cache}/ralph-parallel`
       - 24-hour cache check using epoch seconds comparison
       - Read marketplace clone dir from `$HOME/.claude/plugins/known_marketplaces.json` via `jq`
       - Read installed SHA from `$HOME/.claude/plugins/installed_plugins.json` via `jq`
       - `timeout 15 git -C "$mktplace_dir" fetch origin --quiet 2>/dev/null`
       - Compare installed SHA (7-char prefix + full) against `git rev-parse origin/HEAD`
       - Count commits behind: `git rev-list --count "${installed_sha}..origin/HEAD"`
       - Print: `ralph-parallel: Update available (N commits behind). Run: claude plugin update ralph-parallel@ralph-parallel`
       - Update cache timestamp after fetch (regardless of result)
    4. Call: `_ralph_update_check 2>/dev/null || true`
    5. Cleanup: `unset -f _ralph_update_check`
    6. All failures must be silent (never block session start)
  - **Files**: `plugins/ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: session-setup.sh contains `_ralph_update_check` function; block is guarded by `CLAUDE_PLUGIN_ROOT`; `timeout 15` on git fetch; 24-hour cache logic present
  - **Verify**: `bash -n plugins/ralph-parallel/hooks/scripts/session-setup.sh && echo "PASS: syntax ok" || echo "FAIL: syntax error"`
  - **Commit**: `feat(auto-update): add git-fetch-based update notification to session-setup.sh`
  - _Requirements: FR-10 (AC-7.1 through AC-7.8)_
  - _Design: C7_

- [ ] 1.12 POC Checkpoint: negative grep assertions + full test suite
  - **Do**: Run all negative grep assertions from design.md and full test suite
  - **Verify**:
    ```
    # Negative assertions (each must print PASS)
    ! grep -r 'grep -qP' plugins/ralph-parallel/ && echo "PASS: no grep -qP" || echo "FAIL"
    ! grep -rn '/tmp/ralph-' plugins/ralph-parallel/hooks/scripts/*.sh plugins/ralph-parallel/scripts/*.sh && echo "PASS: no /tmp/ralph-" || echo "FAIL"
    ! grep -rn 'echo -e' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/session-setup.sh plugins/ralph-parallel/scripts/capture-baseline.sh && echo "PASS: no echo -e" || echo "FAIL"
    ! grep -rn '\[\[' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/session-setup.sh plugins/ralph-parallel/scripts/capture-baseline.sh && echo "PASS: no [[ ]]" || echo "FAIL"
    ! grep -rn "sed \$'" plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/scripts/capture-baseline.sh && echo "PASS: no sed ANSI-C" || echo "FAIL"
    diff <(jq -r '.plugins[0].version' .claude-plugin/marketplace.json) <(jq -r '.version' plugins/ralph-parallel/.claude-plugin/plugin.json) && echo "PASS: versions match" || echo "FAIL"
    # Full test suite
    bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && python3 -m pytest plugins/ralph-parallel/scripts/
    ```
  - **Done when**: All negative assertions print PASS; all test suites exit 0
  - **Commit**: `feat(portability): complete POC -- all portability fixes and auto-update`

## Phase 2: Refactoring

After POC validated, clean up code.

- [ ] 2.1 Verify _sanitize_cmd parity between files
  - **Do**:
    1. Extract `_sanitize_cmd` from both task-completed-gate.sh and capture-baseline.sh
    2. Diff them to confirm they are byte-identical
    3. If drift exists, copy the task-completed-gate.sh version to capture-baseline.sh
  - **Files**: `plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`, `plugins/ralph-parallel/scripts/capture-baseline.sh`
  - **Done when**: `diff` of both `_sanitize_cmd` implementations shows zero differences
  - **Verify**: `diff <(sed -n '/_sanitize_cmd()/,/^}/p' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh) <(sed -n '/_sanitize_cmd()/,/^}/p' plugins/ralph-parallel/scripts/capture-baseline.sh) && echo "PASS" || echo "FAIL"`
  - **Commit**: `refactor(portability): ensure _sanitize_cmd parity across files` (only if fix needed)
  - _Requirements: AC-1.4_
  - _Design: C1_

- [ ] 2.2 [VERIFY] Quality checkpoint: full test suite
  - **Do**: Run full test suite after refactoring
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && python3 -m pytest plugins/ralph-parallel/scripts/`
  - **Done when**: All commands exit 0
  - **Commit**: `chore(portability): pass quality checkpoint` (only if fixes needed)

## Phase 3: Testing

- [ ] 3.1 Verify auto-update logic with unit-style smoke tests
  - **Do**:
    1. Create a small inline test in bash that sources the auto-update function and verifies:
       - With `CLAUDE_PLUGIN_ROOT` unset, check is skipped (verify by absence of any output)
       - With `CLAUDE_PLUGIN_ROOT` set but no `known_marketplaces.json`, check exits silently
       - Cache file timestamp logic: write a cache file with current epoch, verify function skips fetch
       - Cache file timestamp logic: write a cache file with epoch 0, verify function attempts fetch
    2. Run as: `bash -c '...'` inline commands (no separate test file needed)
  - **Files**: (none -- inline bash verification)
  - **Done when**: All smoke tests pass
  - **Verify**: `CLAUDE_PLUGIN_ROOT="" bash -c 'source plugins/ralph-parallel/hooks/scripts/session-setup.sh < /dev/null 2>/dev/null; echo "PASS: no crash without CLAUDE_PLUGIN_ROOT"'`
  - **Commit**: None (verification only)
  - _Requirements: AC-7.6, AC-7.8_
  - _Design: C7 Error Handling_

- [ ] 3.2 [VERIFY] Full test suite regression check
  - **Do**: Run complete test suite to confirm no regressions
  - **Verify**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && bash plugins/ralph-parallel/scripts/test_session_isolation.sh && python3 -m pytest plugins/ralph-parallel/scripts/`
  - **Done when**: All test suites pass
  - **Commit**: `chore(portability): pass full test regression check` (only if fixes needed)

## Phase 4: Quality Gates

- [ ] 4.1 [VERIFY] Full local CI: all tests + negative grep assertions
  - **Do**: Run complete local CI suite
  - **Verify**: All commands must pass:
    ```
    bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && \
    bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && \
    bash plugins/ralph-parallel/scripts/test_stop_hook.sh && \
    bash plugins/ralph-parallel/scripts/test_session_isolation.sh && \
    python3 -m pytest plugins/ralph-parallel/scripts/ && \
    ! grep -r 'grep -qP' plugins/ralph-parallel/ && \
    ! grep -rn '/tmp/ralph-' plugins/ralph-parallel/hooks/scripts/*.sh plugins/ralph-parallel/scripts/*.sh && \
    ! grep -rn 'echo -e' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/session-setup.sh plugins/ralph-parallel/scripts/capture-baseline.sh && \
    ! grep -rn '\[\[' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/hooks/scripts/teammate-idle-gate.sh plugins/ralph-parallel/hooks/scripts/dispatch-coordinator.sh plugins/ralph-parallel/hooks/scripts/session-setup.sh plugins/ralph-parallel/scripts/capture-baseline.sh && \
    ! grep -rn "sed \$'" plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh plugins/ralph-parallel/scripts/capture-baseline.sh && \
    diff <(jq -r '.plugins[0].version' .claude-plugin/marketplace.json) <(jq -r '.version' plugins/ralph-parallel/.claude-plugin/plugin.json)
    ```
  - **Done when**: All tests pass, all negative assertions clean, versions match
  - **Commit**: `chore(portability): pass local CI` (if fixes needed)

- [ ] 4.2 Create PR and verify CI
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Push branch: `git push -u origin <branch-name>`
    4. Create PR: `gh pr create --title "fix(portability): POSIX fixes, TMPDIR, and auto-update notification" --body "..."`
    5. PR body should summarize: security fix (grep -qP), TMPDIR adoption (10 files), POSIX portability ([[ ]], sed $'', echo -e), version sync, auto-update notification
  - **Verify**: `gh pr checks --watch` -- all checks must show passing
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
    - AC-1.1: `! grep -qP 'grep -qP' plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
    - AC-1.2: `! grep -qP 'grep -qP' plugins/ralph-parallel/scripts/capture-baseline.sh`
    - AC-1.3: `grep -q "tr -d" plugins/ralph-parallel/hooks/scripts/task-completed-gate.sh`
    - AC-1.4: `diff _sanitize_cmd` between files
    - AC-2.1-2.9: `! grep '/tmp/ralph-'` across all files
    - AC-3.1: `jq '.plugins[0].version' .claude-plugin/marketplace.json` = `"0.2.4"`
    - AC-4.1: `! grep '\[\[' teammate-idle-gate.sh`
    - AC-4.2: `! grep '\[\[' capture-baseline.sh`
    - AC-5.1-5.4: `grep "ESC=\$(printf" task-completed-gate.sh` and `capture-baseline.sh`
    - AC-6.1: `! grep 'echo -e' teammate-idle-gate.sh`
    - AC-7.1-7.8: `grep '_ralph_update_check' session-setup.sh` and `grep 'CLAUDE_PLUGIN_ROOT' session-setup.sh` and `grep 'timeout 15' session-setup.sh` and `grep 'XDG_CACHE_HOME' session-setup.sh`
  - **Verify**: All grep/diff assertions exit successfully
  - **Done when**: All acceptance criteria confirmed met via automated checks
  - **Commit**: None

## Notes

- **POC shortcuts taken**: Auto-update check verified via `bash -n` syntax check only (no real marketplace clone available in dev); full SHA comparison not testable without real `installed_plugins.json` with SHA data
- **Production TODOs**: Consider adding a version-sync pre-commit hook to prevent marketplace.json drift; consider documenting `autoUpdate: true` in known_marketplaces.json as an alternative to the custom SessionStart hook
- **Parallel dispatch file ownership**:
  - Task 1.1: `task-completed-gate.sh` (exclusive)
  - Task 1.2: `capture-baseline.sh` (exclusive)
  - Task 1.3: `teammate-idle-gate.sh` (exclusive)
  - Task 1.4: `dispatch-coordinator.sh` (exclusive)
  - Task 1.6: `test_stop_hook.sh` (exclusive, depends on 1.4)
  - Task 1.7: `test_teammate_idle_gate.sh` (exclusive, depends on 1.3)
  - Task 1.8: `test_session_isolation.sh` (exclusive, depends on 1.4)
  - Task 1.9: `dispatch.md` + `marketplace.json` (exclusive)
  - Task 1.11: `session-setup.sh` (exclusive)
  - Tasks 1.1-1.4 can run in parallel (separate files)
  - Tasks 1.6-1.9 can run in parallel (separate files, after 1.5 checkpoint)
  - Task 1.11 can run in parallel with 1.6-1.9
