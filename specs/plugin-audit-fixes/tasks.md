# Tasks: Plugin Audit Fixes

## Quality Commands

- **Build**: N/A
- **Typecheck**: N/A
- **Lint**: N/A
- **Test**: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py`

## Phase 1: Make It Work (POC)

All 3 groups execute in parallel (no file conflicts). Groups are organized by file ownership to enable direct `/dispatch`.

### Group 1: python-fixes [Phase 1]
**Files owned**: `ralph-parallel/scripts/parse-and-partition.py`, `ralph-parallel/scripts/build-teammate-prompt.py`, `ralph-parallel/scripts/test_parse_and_partition.py`

- [ ] 1.1 [P] Add `_task_id_key` helper for numeric ID sorting
  - **Do**:
    1. Open `ralph-parallel/scripts/parse-and-partition.py`
    2. Insert `_task_id_key()` function after line 34 (after the `tomllib` import block, before `WEAK_PATTERNS`):
       ```python
       def _task_id_key(task_id: str) -> tuple[int, int]:
           """Convert 'X.Y' to (X, Y) for correct numeric comparison."""
           parts = task_id.split('.')
           return (int(parts[0]), int(parts[1]))
       ```
    3. Update 4 call sites:
       - Line ~440: `other['id'] < t['id']` -> `_task_id_key(other['id']) < _task_id_key(t['id'])`
       - Line ~445: `other['id'] > t['id']` -> `_task_id_key(other['id']) > _task_id_key(t['id'])`
       - Line ~611: `key=lambda t: (t['phase'], t['id'])` -> `key=lambda t: (t['phase'], _task_id_key(t['id']))`
       - Line ~628: `key=lambda t: (t['phase'], t['id'])` -> `key=lambda t: (t['phase'], _task_id_key(t['id']))`
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: All 4 string comparisons replaced with `_task_id_key()` calls
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py`
  - **Commit**: `fix(parser): add numeric task ID comparison to fix ordering for 10+ tasks`
  - _Requirements: FR-1, AC-1.1, AC-1.2, AC-1.3_
  - _Design: FR-1 Numeric Task ID Comparison_

- [ ] 1.2 [P] Rewrite QC parser for multi-format support
  - **Do**:
    1. Open `ralph-parallel/scripts/parse-and-partition.py`
    2. Replace `parse_quality_commands_from_tasks()` (lines 124-167) with multi-format parser from design.md
    3. Parser priority: bold markdown (`- **Build**: \`cmd\``) > code-fenced > bare dash
    4. Handle N/A exclusion for all formats (case-insensitive)
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Bold markdown, code-fenced, and bare dash formats all parse correctly; N/A excluded
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py`
  - **Commit**: `fix(parser): support bold markdown QC format as primary, keep code-fence backward compat`
  - _Requirements: FR-2, AC-2.1 through AC-2.5_
  - _Design: FR-2 Quality Commands Parser_

- [ ] 1.3 [P] Guard `_build_groups_worktree` against empty parallel_tasks
  - **Do**:
    1. Open `ralph-parallel/scripts/parse-and-partition.py`
    2. Add guard clause at top of `_build_groups_worktree` (line ~611, now uses `_task_id_key`):
       ```python
       if not parallel_tasks:
           return [], []
       ```
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Function returns early on empty input without crash
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py`
  - **Commit**: `fix(parser): guard worktree partitioning against empty parallel tasks`
  - _Requirements: FR-7, AC-7.1_
  - _Design: FR-7 Worktree Empty Guard_

- [ ] 1.4 [P] Fix rebalance to recompute ownedFiles from remaining tasks
  - **Do**:
    1. Open `ralph-parallel/scripts/parse-and-partition.py`
    2. In `_rebalance_groups`, replace line ~697 (`groups[largest]['ownedFiles'] -= task_files`) with:
       ```python
       remaining_files = set()
       for remaining_task in groups[largest]['tasks']:
           remaining_files.update(remaining_task['files'])
       groups[largest]['ownedFiles'] = remaining_files
       ```
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: ownedFiles recomputed from remaining tasks after rebalance move
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py`
  - **Commit**: `fix(parser): recompute ownedFiles from remaining tasks during rebalance`
  - _Requirements: FR-8, AC-8.1_
  - _Design: FR-8 Rebalance Fix_

- [ ] 1.5 [P] Remove `git commit -s` advice from build-teammate-prompt.py
  - **Do**:
    1. Open `ralph-parallel/scripts/build-teammate-prompt.py`
    2. Replace line 180:
       - Before: `lines.append('Use \`git commit -s\` flag or manually append the trailer to every commit.')`
       - After:
         ```python
         lines.append('Append the Signed-off-by trailer manually to every commit message.')
         lines.append('Do NOT use `git commit -s` -- it produces the wrong format for provenance tracking.')
         ```
  - **Files**: `ralph-parallel/scripts/build-teammate-prompt.py`
  - **Done when**: `-s` advice removed, explicit warning added
  - **Verify**: `python3 ralph-parallel/scripts/test_build_teammate_prompt.py`
  - **Commit**: `fix(prompt): remove git commit -s advice, add explicit warning`
  - _Requirements: FR-9, AC-9.1, AC-9.2_
  - _Design: FR-9 Commit Provenance_

- [ ] 1.6 [P] Add regression tests for FR-1, FR-2, FR-7, FR-8
  - **Do**:
    1. Open `ralph-parallel/scripts/test_parse_and_partition.py`
    2. Import additional functions at top (add to the existing import block after line 21):
       ```python
       _task_id_key = mod._task_id_key
       parse_quality_commands_from_tasks = mod.parse_quality_commands_from_tasks
       parse_tasks = mod.parse_tasks
       build_dependency_graph = mod.build_dependency_graph
       partition_tasks = mod.partition_tasks
       ```
    3. Add `TestTaskIdKey` class:
       - `test_basic_comparison`: assert `_task_id_key("1.10") > _task_id_key("1.2")`
       - `test_sort_order`: sort ["1.1","1.10","1.11","1.2","1.9","2.1"], verify correct order
       - `test_verify_dependency_ordering`: create 12-task tasks.md with VERIFY at 1.12, verify all 11 preceding tasks are dependencies
    4. Add `TestQualityCommandsParsing` class:
       - `test_bold_markdown_format`: parse `- **Build**: \`cargo build\`` etc.
       - `test_code_fenced_format`: parse code-fenced block (backward compat)
       - `test_bare_dash_format`: parse `- Build: \`cargo build\``
       - `test_na_excluded`: verify N/A values not in result
       - `test_bold_markdown_without_dash`: parse `**Build**: \`cmd\`` (no leading dash)
    5. Add `TestWorktreeEmptyGuard` class:
       - `test_all_verify_tasks`: tasks.md with only VERIFY tasks, call partition_tasks with worktree strategy, verify no crash
    6. Add `TestRebalanceOwnership` class:
       - `test_shared_files_preserved`: 5 tasks with overlapping files, 2 teammates, verify after partition every group owns all files its tasks reference
  - **Files**: `ralph-parallel/scripts/test_parse_and_partition.py`
  - **Done when**: All new tests pass; existing tests still pass
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py`
  - **Commit**: `test(parser): add regression tests for task ID sorting, QC parsing, worktree guard, rebalance`
  - _Requirements: NFR-1, AC-1.4, AC-2.4, AC-7.2, AC-8.2_
  - _Design: Test Strategy_

### Group 2: shell-fixes [Phase 1]
**Files owned**: `ralph-parallel/hooks/scripts/session-setup.sh`, `ralph-parallel/hooks/scripts/task-completed-gate.sh`, `ralph-parallel/hooks/scripts/file-ownership-guard.sh`, `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`

- [ ] 1.7 [P] Add `export` keyword to session-setup.sh env write
  - **Do**:
    1. Open `ralph-parallel/hooks/scripts/session-setup.sh`
    2. Replace line 19:
       - Before: `echo "CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true`
       - After: `echo "export CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true`
  - **Files**: `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: `export` keyword present in CLAUDE_SESSION_ID write
  - **Verify**: `grep 'export CLAUDE_SESSION_ID' ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `fix(hooks): add export keyword to CLAUDE_SESSION_ID env write`
  - _Requirements: FR-3, AC-3.1_
  - _Design: FR-3 Export Session ID_

- [ ] 1.8 [P] Wrap eval commands in subshells in task-completed-gate.sh
  - **Do**:
    1. Open `ralph-parallel/hooks/scripts/task-completed-gate.sh`
    2. Remove standalone `cd "$PROJECT_ROOT"` at line 115
    3. Replace Stage 1 eval (line ~120):
       - Before: `VERIFY_OUTPUT=$(eval "$VERIFY_CMD" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?`
       - After: `VERIFY_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$VERIFY_CMD" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?`
    4. Replace Stage 2 typecheck eval (line ~136):
       - Before: `TC_OUTPUT=$(eval "$TYPECHECK_CMD" 2>&1) && TC_EXIT=0 || TC_EXIT=$?`
       - After: `TC_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$TYPECHECK_CMD" 2>&1) && TC_EXIT=0 || TC_EXIT=$?`
    5. Replace Stage 4 build eval (line ~189):
       - Before: `BUILD_OUTPUT=$(eval "$BUILD_CMD" 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?`
       - After: `BUILD_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$BUILD_CMD" 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?`
    6. Replace Stage 5 test eval (line ~243):
       - Before: `TEST_OUTPUT=$(eval "$TEST_CMD" 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?`
       - After: `TEST_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$TEST_CMD" 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?`
    7. Replace Stage 6 lint eval (line ~303):
       - Before: `LINT_OUTPUT=$(eval "$LINT_CMD" 2>&1) && LINT_EXIT=0 || LINT_EXIT=$?`
       - After: `LINT_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$LINT_CMD" 2>&1) && LINT_EXIT=0 || LINT_EXIT=$?`
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: All 5 eval calls wrapped in subshells; standalone `cd` removed
  - **Verify**: `grep -c 'cd "\$PROJECT_ROOT" && eval' ralph-parallel/hooks/scripts/task-completed-gate.sh | grep -q 5`
  - **Commit**: `fix(hooks): isolate eval commands in subshells to prevent CWD leakage`
  - _Requirements: FR-10, AC-10.1, AC-10.2_
  - _Design: FR-10 Eval Isolation_

- [ ] 1.9 [P] Quote `$PROJECT_ROOT` in file-ownership-guard.sh parameter expansion
  - **Do**:
    1. Open `ralph-parallel/hooks/scripts/file-ownership-guard.sh`
    2. Replace line 82:
       - Before: `REL_PATH="${FILE_PATH#$PROJECT_ROOT/}"`
       - After: `REL_PATH="${FILE_PATH#"$PROJECT_ROOT"/}"`
  - **Files**: `ralph-parallel/hooks/scripts/file-ownership-guard.sh`
  - **Done when**: `$PROJECT_ROOT` quoted in parameter expansion
  - **Verify**: `grep 'FILE_PATH#"' ralph-parallel/hooks/scripts/file-ownership-guard.sh`
  - **Commit**: `fix(hooks): quote PROJECT_ROOT in parameter expansion to prevent glob injection`
  - _Requirements: FR-11, AC-11.1_
  - _Design: FR-11 Quote PROJECT_ROOT_

- [ ] 1.10 [P] Standardize PROJECT_ROOT to `git rev-parse` in 3 hooks
  - **Do**:
    1. **file-ownership-guard.sh** (lines 39-44): Replace CWD-first block with:
       ```bash
       PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
         CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
         PROJECT_ROOT="${CWD:-$(pwd)}"
       }
       ```
    2. **task-completed-gate.sh** (lines 33-37): Replace CWD-first block with:
       ```bash
       PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"
       ```
    3. **dispatch-coordinator.sh** (lines 29-33): Replace CWD-first block with:
       ```bash
       PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"
       ```
  - **Files**: `ralph-parallel/hooks/scripts/file-ownership-guard.sh`, `ralph-parallel/hooks/scripts/task-completed-gate.sh`, `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: All 3 hooks use `git rev-parse --show-toplevel` as primary with CWD fallback
  - **Verify**: `for f in ralph-parallel/hooks/scripts/file-ownership-guard.sh ralph-parallel/hooks/scripts/task-completed-gate.sh ralph-parallel/hooks/scripts/dispatch-coordinator.sh; do grep -q 'git rev-parse --show-toplevel' "$f" || { echo "FAIL: $f"; exit 1; }; done && echo "PASS"`
  - **Commit**: `fix(hooks): standardize PROJECT_ROOT to git rev-parse --show-toplevel in all hooks`
  - _Requirements: FR-12, AC-12.1, AC-12.2_
  - _Design: FR-12 Standardize PROJECT_ROOT_

- [ ] 1.11 [P] Add mark-tasks-complete to stop hook re-injection
  - **Do**:
    1. Open `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
    2. Replace line 195 in the NEXT ACTIONS block:
       - Before: `4. When all tasks done: update dispatch-state.json status to "merged", shut down teammates, TeamDelete`
       - After: `4. When all tasks done: run mark-tasks-complete.py, set status="merged", shut down teammates, TeamDelete`
  - **Files**: `ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Done when**: Re-injection prompt includes mark-tasks-complete reminder
  - **Verify**: `grep 'mark-tasks-complete' ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
  - **Commit**: `fix(hooks): add mark-tasks-complete reminder to stop hook re-injection`
  - _Requirements: FR-16, AC-16.1_
  - _Design: FR-16 Stop Hook Re-injection_

- [ ] 1.12 [VERIFY] Quality checkpoint: run all Python tests
  - **Do**: Run full test suite to verify Groups 1 and 2 haven't introduced regressions
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py`
  - **Done when**: All tests pass with exit 0
  - **Commit**: `chore(plugin-audit): pass quality checkpoint` (only if fixes needed)

### Group 3: doc-fixes [Phase 1]
**Files owned**: `ralph-parallel/commands/dispatch.md`, `ralph-parallel/commands/status.md`, `ralph-parallel/commands/merge.md`, `ralph-parallel/templates/team-prompt.md`, `ralph-parallel/templates/teammate-prompt.md`

- [ ] 1.13 [P] Add `--strategy $strategy` to dispatch.md Step 3
  - **Do**:
    1. Open `ralph-parallel/commands/dispatch.md`
    2. In Step 3 code block (lines 82-87), add `--strategy $strategy \` before `--format`:
       ```bash
       python3 ${CLAUDE_PLUGIN_ROOT}/scripts/parse-and-partition.py \
         --tasks-md specs/$specName/tasks.md \
         --max-teammates $maxTeammates \
         --strategy $strategy \
         --format
       ```
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Step 3 command includes `--strategy $strategy`
  - **Verify**: `grep -A5 'Step 3' ralph-parallel/commands/dispatch.md | grep -q 'strategy'`
  - **Commit**: `fix(dispatch): add --strategy flag to Step 3 display plan command`
  - _Requirements: FR-4, AC-4.1_
  - _Design: FR-4 Strategy Flag_

- [ ] 1.14 [P] Add partition JSON save step to dispatch.md
  - **Do**:
    1. Open `ralph-parallel/commands/dispatch.md`
    2. Replace line 69 text:
       - Before: `- 0: Success — JSON partition on stdout. Save to a variable.`
       - After: `- 0: Success — JSON partition on stdout. Save to a variable AND save to /tmp/$specName-partition.json for use by build-teammate-prompt.py in Step 6.`
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Explicit save path documented for partition JSON
  - **Verify**: `grep 'partition.json' ralph-parallel/commands/dispatch.md`
  - **Commit**: `fix(dispatch): document partition JSON save path for teammate prompt generation`
  - _Requirements: FR-5, AC-5.1, AC-5.2_
  - _Design: FR-5 Partition File Save_

- [ ] 1.15 [P] Replace "Phase 2" hardcoding with dynamic phase references
  - **Do**:
    1. Open `ralph-parallel/commands/dispatch.md`
    2. Replace line 235:
       - Before: `5. SERIAL TASKS: After Phase 2, execute serial tasks yourself`
       - After: `5. SERIAL TASKS: After ALL parallel groups complete (all phases), execute serial tasks yourself`
    3. Replace line 237:
       - Before: `6. FINAL VERIFY: Run Phase 2 verify checkpoint`
       - After: `6. FINAL VERIFY: Run the last phase's verify checkpoint`
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: No "Phase 2" hardcoding in Step 7 items 5-6
  - **Verify**: `! grep -n 'After Phase 2' ralph-parallel/commands/dispatch.md && ! grep -n 'Phase 2 verify' ralph-parallel/commands/dispatch.md && echo "PASS"`
  - **Commit**: `fix(dispatch): replace Phase 2 hardcoding with dynamic phase references`
  - _Requirements: FR-6, AC-6.1, AC-6.2_
  - _Design: FR-6 Dynamic Phase References_

- [ ] 1.16 [P] Replace "reassign to self" with "re-spawn" in stall recovery
  - **Do**:
    1. Open `ralph-parallel/commands/dispatch.md`
    2. Replace line 223:
       - Before: `c. If still no response: reassign tasks to self or serialize`
       - After: `c. If still no response: re-spawn the stalled teammate with remaining tasks. If re-spawn fails, serialize remaining tasks and warn user.`
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: "reassign to self" removed, "re-spawn" documented
  - **Verify**: `! grep -q 'reassign tasks to self' ralph-parallel/commands/dispatch.md && grep -q 're-spawn' ralph-parallel/commands/dispatch.md && echo "PASS"`
  - **Commit**: `fix(dispatch): replace reassign-to-self with re-spawn in stall recovery`
  - _Requirements: FR-13, AC-13.1, AC-13.2_
  - _Design: FR-13 Stall Recovery_

- [ ] 1.17 [P] Add SendMessage, TeamCreate, TeamDelete to allowed-tools
  - **Do**:
    1. Open `ralph-parallel/commands/dispatch.md`
    2. Replace line 4:
       - Before: `allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]`
       - After: `allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep, SendMessage, TeamCreate, TeamDelete]`
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: All 3 tools added to allowed-tools list
  - **Verify**: `head -5 ralph-parallel/commands/dispatch.md | grep -q 'SendMessage' && head -5 ralph-parallel/commands/dispatch.md | grep -q 'TeamCreate' && head -5 ralph-parallel/commands/dispatch.md | grep -q 'TeamDelete' && echo "PASS"`
  - **Commit**: `fix(dispatch): add SendMessage, TeamCreate, TeamDelete to allowed-tools`
  - _Requirements: FR-14, AC-14.1, AC-14.2_
  - _Design: FR-14 Allowed-Tools_

- [ ] 1.18 [P] Fix step number references in team-prompt.md and teammate-prompt.md
  - **Do**:
    1. Open `ralph-parallel/templates/team-prompt.md`
    2. Line 3: Replace `Step 8` with `Step 7`
    3. Open `ralph-parallel/templates/teammate-prompt.md`
    4. Line 3: Replace `Step 7` with `Step 6`
    5. Line 39: Replace `Step 7` with `Step 5`
  - **Files**: `ralph-parallel/templates/team-prompt.md`, `ralph-parallel/templates/teammate-prompt.md`
  - **Done when**: All step references match dispatch.md numbering
  - **Verify**: `! grep -q 'Step 8' ralph-parallel/templates/team-prompt.md && ! grep 'Step 7' ralph-parallel/templates/teammate-prompt.md && echo "PASS"`
  - **Commit**: `fix(templates): correct step number references to match dispatch.md`
  - _Requirements: FR-15, AC-15.1, AC-15.2_
  - _Design: FR-15 Step References_

- [ ] 1.19 [P] Add stale dispatch handling to status.md and merge.md
  - **Do**:
    1. Open `ralph-parallel/commands/status.md`
    2. After line 32 (the session comparison block in Step 1), insert stale handling:
       ```text
       7. If status is "stale": Display stale notice:
          "Dispatch STALE for '$specName' (reason: $staleReason, since: $staleSince)."
          "Run /ralph-parallel:dispatch to re-dispatch, or /ralph-parallel:dispatch --abort to cancel."
          Include staleSince, staleReason from dispatch state. Skip Steps 2-3 (no live team to query).
       ```
    3. Open `ralph-parallel/commands/merge.md`
    4. After line 31 (the "merging" status check), insert:
       ```text
       - "stale" -> "This dispatch is stale (team lost at $staleSince). Run /ralph-parallel:dispatch to re-dispatch or /ralph-parallel:dispatch --abort to cancel."
       ```
  - **Files**: `ralph-parallel/commands/status.md`, `ralph-parallel/commands/merge.md`
  - **Done when**: Both files handle "stale" status with user guidance
  - **Verify**: `grep -q 'stale' ralph-parallel/commands/status.md && grep -q 'stale' ralph-parallel/commands/merge.md && echo "PASS"`
  - **Commit**: `fix(commands): add stale dispatch handling to status and merge commands`
  - _Requirements: FR-17, AC-17.1, AC-17.2_
  - _Design: FR-17 Stale Handling_

- [ ] 1.20 [VERIFY] Quality checkpoint: verify all doc changes
  - **Do**: Verify dispatch.md, status.md, merge.md, templates all have correct content
  - **Verify**: `grep -q 'strategy \$strategy' ralph-parallel/commands/dispatch.md && grep -q 'partition.json' ralph-parallel/commands/dispatch.md && grep -q 'SendMessage' ralph-parallel/commands/dispatch.md && grep -q 'stale' ralph-parallel/commands/status.md && grep -q 'stale' ralph-parallel/commands/merge.md && echo "PASS"`
  - **Done when**: All doc fixes verified present
  - **Commit**: `chore(plugin-audit): pass doc fixes quality checkpoint` (only if fixes needed)

## Phase 2: Verification

Final verification across all groups after parallel execution completes.

- [ ] 2.1 [VERIFY] Full test suite: all Python tests pass
  - **Do**: Run complete test suite to confirm no regressions across all code changes
  - **Verify**: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py`
  - **Done when**: All 4 test files pass with exit 0
  - **Commit**: `chore(plugin-audit): pass full test suite` (only if fixes needed)

- [ ] 2.2 [VERIFY] Shell script static checks
  - **Do**: Verify all shell script changes are syntactically correct and contain expected patterns
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/session-setup.sh && bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/file-ownership-guard.sh && bash -n ralph-parallel/hooks/scripts/dispatch-coordinator.sh && echo "Syntax OK" && grep -q 'export CLAUDE_SESSION_ID' ralph-parallel/hooks/scripts/session-setup.sh && grep -c 'cd "\$PROJECT_ROOT" && eval' ralph-parallel/hooks/scripts/task-completed-gate.sh | grep -q 5 && grep -q 'FILE_PATH#"' ralph-parallel/hooks/scripts/file-ownership-guard.sh && echo "All patterns verified"`
  - **Done when**: All 4 hooks pass syntax check and contain expected fix patterns
  - **Commit**: `chore(plugin-audit): pass shell script verification` (only if fixes needed)

- [ ] 2.3 [VERIFY] AC checklist: programmatically verify all acceptance criteria
  - **Do**: Check each AC by inspecting code/docs
  - **Verify**: `python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('m', 'ralph-parallel/scripts/parse-and-partition.py')
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
# AC-1.1
assert mod._task_id_key('1.10') == (1, 10), 'AC-1.1 fail'
# AC-2.1
r = mod.parse_quality_commands_from_tasks('## Quality Commands\n- **Build**: \`cargo build\`\n- **Test**: \`cargo test\`\n')
assert r.get('build') == 'cargo build', 'AC-2.1 fail'
# AC-2.2
r2 = mod.parse_quality_commands_from_tasks('## Quality Commands\n\`\`\`\nbuild: cargo build\n\`\`\`\n')
assert r2.get('build') == 'cargo build', 'AC-2.2 fail'
# AC-2.5
r3 = mod.parse_quality_commands_from_tasks('## Quality Commands\n- **Build**: N/A\n- **Test**: \`cargo test\`\n')
assert 'build' not in r3, 'AC-2.5 fail'
print('All Python ACs pass')
" && grep -q 'export CLAUDE_SESSION_ID' ralph-parallel/hooks/scripts/session-setup.sh && echo "AC-3.1 pass" && grep -q 'SendMessage' ralph-parallel/commands/dispatch.md && echo "AC-14 pass" && ! grep -q 'reassign tasks to self' ralph-parallel/commands/dispatch.md && echo "AC-13 pass"`
  - **Done when**: All testable ACs confirmed satisfied
  - **Commit**: None

## Phase 3: Quality Gates

- [ ] 3.1 Create PR and verify
  - **Do**:
    1. Verify on feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Stage all changed files: `git add ralph-parallel/`
    4. Create final commit if uncommitted changes remain
    5. Push branch: `git push -u origin $(git branch --show-current)`
    6. Create PR: `gh pr create --title "fix(ralph-parallel): fix 17 audit issues" --body "..."`
  - **Verify**: `gh pr checks` shows all green (or no CI configured)
  - **Done when**: PR created and CI passes
  - **Commit**: None (PR creation only)

## Phase 4: PR Lifecycle

- [ ] 4.1 Monitor CI and fix failures
  - **Do**: If CI fails, read failure details, fix locally, push fixes
  - **Verify**: `gh pr checks` all passing
  - **Done when**: All CI checks green

- [ ] 4.2 Address review comments
  - **Do**: Check for review comments, address each one
  - **Verify**: `gh pr view --json reviews | jq '.reviews | length'`
  - **Done when**: All review comments addressed or no reviews pending

## Notes

- **POC shortcuts**: None -- all fixes are surgical (1-20 lines each), no shortcuts needed
- **Production TODOs**: None -- these are final production fixes
- **Dispatch grouping**: 3 groups with zero file overlap, all Phase 1 parallel
- **Key risk**: QC parser rewrite (FR-2) is the largest change (~40 lines). Mitigated by comprehensive test coverage (5 test cases)
- **Backward compat**: Code-fenced QC format still supported alongside new bold markdown primary format
- **Skipped**: Issue #13 (TaskCreate vs Task naming) confirmed NOT a bug per user decision
