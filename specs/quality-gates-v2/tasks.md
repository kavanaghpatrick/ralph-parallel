---
spec: quality-gates-v2
phase: tasks
total_tasks: 17
created: 2026-02-22
generated: auto
---

# Tasks: quality-gates-v2

## Quality Commands
- Build: N/A
- Typecheck: N/A
- Lint: N/A
- Test: N/A

## Phase 1: Make It Work (POC)

Focus: Get all 3 fixes working end-to-end. Skip tests, accept rough edges.

- [x] 1.1 Add Stage 6 lint check to task-completed-gate.sh
  - **Do**:
    1. Read `ralph-parallel/hooks/scripts/task-completed-gate.sh`
    2. After Stage 5 (test suite regression check, ends around line 285), add Stage 6: Periodic lint check
    3. Read `LINT_CMD` from `jq -r '.qualityCommands.lint // empty'` on dispatch-state.json
    4. If empty: skip (no lint configured)
    5. Use `LINT_INTERVAL` env var (default 3), same periodic pattern as Stage 4 build
    6. Reuse `COMPLETED_COUNT` from earlier stages
    7. On failure: exit 2 with "SUPPLEMENTAL CHECK FAILED: lint" + last 30 lines of output
    8. On success: echo info message to stderr
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Stage 6 block exists, reads lint command from dispatch-state.json, blocks on non-zero exit
  - **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Commit**: `feat(quality): add periodic lint enforcement to task-completed-gate`

- [x] 1.2 Create mark-tasks-complete.py script
  - **Do**:
    1. Create `ralph-parallel/scripts/mark-tasks-complete.py`
    2. Add argparse: `--dispatch-state <path>` and `--tasks-md <path>`
    3. Read dispatch-state.json: extract `completedGroups` array and `groups` array
    4. For each group in `groups`: if group `name` is in `completedGroups`, collect its `tasks` array (list of task IDs like "1.1", "1.2")
    5. Read tasks.md content
    6. For each collected task ID, regex replace `- [ ] {task_id}` with `- [x] {task_id}` (match pattern `^- \[ \] {task_id}\b`)
    7. Write updated content back to tasks.md
    8. Output JSON to stdout: `{"marked": N, "alreadyComplete": N, "notFound": N}`
    9. Exit 0 always (informational, never blocks)
  - **Files**: `ralph-parallel/scripts/mark-tasks-complete.py`
  - **Done when**: Script reads dispatch-state.json, finds completed task IDs, updates tasks.md checkboxes
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/mark-tasks-complete.py').read())"`
  - **Commit**: `feat(quality): add mark-tasks-complete.py for automatic checkbox writeback`

- [x] 1.3 Add commit provenance convention to build-teammate-prompt.py
  - **Do**:
    1. Read `ralph-parallel/scripts/build-teammate-prompt.py`
    2. In `build_prompt()`, after the "## Rules" section (around line 136), add a new "## Commit Convention" section
    3. Content: "Every commit MUST include a git trailer for provenance tracking:" followed by example
    4. Format: `Signed-off-by: <group-name>` where group-name is the `name` variable already in scope
    5. Add example commit message showing the trailer format
    6. Add instruction: "Use `git commit -s` flag or manually append the trailer"
    7. Also update the existing commit instruction in the task blocks (line 105) to append the trailer reminder
  - **Files**: `ralph-parallel/scripts/build-teammate-prompt.py`
  - **Done when**: Generated teammate prompts include commit convention section with Signed-off-by trailer
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py').read())"`
  - **Commit**: `feat(quality): inject commit provenance trailer convention into teammate prompts`

- [ ] 1.4 Add lint to PHASE GATE and mark-tasks-complete to CLEANUP in dispatch.md
  - **Do**:
    1. Read `ralph-parallel/commands/dispatch.md`
    2. In Step 7 item 4 (PHASE GATE), after line "d. Run qualityCommands.test (if available)", add: "e. Run qualityCommands.lint (if available)"
    3. Update the failure condition (currently "If build/test FAIL") to "If build/test/lint FAIL"
    4. In Step 7 item 7 (CLEANUP), before "a. Shut down teammates", add new step: "a. Run mark-tasks-complete.py: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/mark-tasks-complete.py --dispatch-state specs/$specName/.dispatch-state.json --tasks-md specs/$specName/tasks.md`"
    5. Renumber subsequent CLEANUP steps (b, c, d, e, f)
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: PHASE GATE includes lint, CLEANUP invokes mark-tasks-complete.py
  - **Verify**: `grep -c 'lint' /Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md`
  - **Commit**: `feat(quality): add lint to phase gate and completion writeback to cleanup`

- [ ] 1.5 [VERIFY] POC Checkpoint
  - **Do**: Verify all 3 fixes are structurally in place:
    1. task-completed-gate.sh has Stage 6 lint block
    2. mark-tasks-complete.py exists and parses
    3. build-teammate-prompt.py has commit convention section
    4. dispatch.md references lint in PHASE GATE and mark-tasks-complete in CLEANUP
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`, `ralph-parallel/scripts/mark-tasks-complete.py`, `ralph-parallel/scripts/build-teammate-prompt.py`, `ralph-parallel/commands/dispatch.md`
  - **Done when**: All 4 verification checks pass
  - **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh && python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/mark-tasks-complete.py').read())" && python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py').read())"`
  - **Commit**: `feat(quality-gates-v2): complete POC -- lint gate, completion writeback, commit provenance`

## Phase 2: Refactoring

After POC validated, clean up code and add the verification script.

- [x] 2.1 Create verify-commit-provenance.py script
  - **Do**:
    1. Create `ralph-parallel/scripts/verify-commit-provenance.py`
    2. Add argparse: `--dispatch-state <path>`, `--since <ISO-timestamp>` (optional, defaults to dispatchedAt from state)
    3. Read dispatch-state.json: extract group names and dispatchedAt timestamp
    4. Run `git log --format="%H %s%n%(trailers:key=Signed-off-by,valueonly)" --since="$since"` to get commits
    5. Parse output: for each commit, check if Signed-off-by trailer exists and matches a known group name
    6. Output JSON: `{"total": N, "attributed": N, "unattributed": N, "unknown_agent": N, "details": [...]}`
    7. Exit 0 always (audit tool, not a gate)
  - **Files**: `ralph-parallel/scripts/verify-commit-provenance.py`
  - **Done when**: Script audits git log and reports provenance coverage
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/verify-commit-provenance.py').read())"`
  - **Commit**: `feat(quality): add verify-commit-provenance.py audit script`

- [x] 2.2 Harden mark-tasks-complete.py edge cases
  - **Do**:
    1. Read `ralph-parallel/scripts/mark-tasks-complete.py`
    2. Handle edge case: dispatch-state.json has no `completedGroups` key (default to empty list)
    3. Handle edge case: dispatch-state.json has no `groups` key (exit 0 with empty result)
    4. Handle edge case: tasks.md doesn't exist (exit 1 with error message)
    5. Handle edge case: task ID appears in completedGroups but regex doesn't match in tasks.md (increment notFound)
    6. Add `--dry-run` flag that prints what would be changed without writing
    7. Ensure idempotency: already-marked `[x]` tasks increment alreadyComplete counter
  - **Files**: `ralph-parallel/scripts/mark-tasks-complete.py`
  - **Done when**: All edge cases handled, --dry-run works
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/mark-tasks-complete.py').read())"`
  - **Commit**: `refactor(quality): harden mark-tasks-complete.py edge cases`

- [x] 2.3 Add error handling to lint stage in task-completed-gate.sh
  - **Do**:
    1. Read `ralph-parallel/hooks/scripts/task-completed-gate.sh`
    2. In Stage 6: add `2>/dev/null || true` to the jq read for lint command (match pattern from Stage 4/5)
    3. Ensure LINT_INTERVAL defaults correctly when env var is unset: `LINT_INTERVAL=${LINT_INTERVAL:-3}`
    4. Add info logging: "ralph-parallel: Running periodic lint check ($COMPLETED_COUNT tasks done): $LINT_CMD"
    5. Verify the COMPLETED_COUNT reuse from Stage 4 works (add fallback recount if needed, matching Stage 5 pattern)
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Lint stage has same robustness as build/test stages
  - **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Commit**: `refactor(quality): harden lint stage error handling in task-completed-gate`

- [ ] 2.4 [VERIFY] Refactoring checkpoint
  - **Do**: Verify refactoring didn't break anything:
    1. All Python scripts pass ast.parse
    2. All bash scripts pass bash -n
    3. verify-commit-provenance.py exists and parses
    4. mark-tasks-complete.py handles --dry-run flag
  - **Files**: `ralph-parallel/scripts/mark-tasks-complete.py`, `ralph-parallel/scripts/verify-commit-provenance.py`, `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: All validation commands pass
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/mark-tasks-complete.py').read())" && python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/verify-commit-provenance.py').read())" && bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Commit**: `refactor(quality-gates-v2): refactoring complete`

## Phase 3: Testing

- [x] 3.1 Test mark-tasks-complete.py with synthetic data
  - **Do**:
    1. Create test in `ralph-parallel/scripts/test_mark_tasks_complete.py`
    2. Test case 1: Normal completion -- 2 groups completed, 4 tasks marked
    3. Test case 2: Partial completion -- 1 of 2 groups completed
    4. Test case 3: Idempotency -- already-marked tasks stay marked
    5. Test case 4: Missing completedGroups key -- no changes
    6. Test case 5: --dry-run doesn't modify file
    7. Use tempfile for synthetic tasks.md and dispatch-state.json
  - **Files**: `ralph-parallel/scripts/test_mark_tasks_complete.py`
  - **Done when**: All 5 test cases pass
  - **Verify**: `python3 -m pytest /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_mark_tasks_complete.py -v`
  - **Commit**: `test(quality): add tests for mark-tasks-complete.py`

- [x] 3.2 Test verify-commit-provenance.py with synthetic git log
  - **Do**:
    1. Create test in `ralph-parallel/scripts/test_verify_commit_provenance.py`
    2. Test case 1: All commits have proper trailers
    3. Test case 2: Some commits missing trailers
    4. Test case 3: Unknown agent name in trailer
    5. Use unittest.mock to mock subprocess git calls
  - **Files**: `ralph-parallel/scripts/test_verify_commit_provenance.py`
  - **Done when**: All test cases pass
  - **Verify**: `python3 -m pytest /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_verify_commit_provenance.py -v`
  - **Commit**: `test(quality): add tests for verify-commit-provenance.py`

## Phase 4: Quality Gates

- [ ] 4.1 Validate all scripts and sync to plugin cache
  - **Do**:
    1. Validate all Python scripts: `python3 -c "import ast; ast.parse(open(f).read())"` for each .py file in ralph-parallel/scripts/
    2. Validate all bash scripts: `bash -n` for each .sh file in ralph-parallel/hooks/scripts/ and ralph-parallel/scripts/
    3. Run all tests: `python3 -m pytest ralph-parallel/scripts/test_mark_tasks_complete.py ralph-parallel/scripts/test_verify_commit_provenance.py -v`
    4. Sync to plugin cache: `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/`
  - **Files**: N/A (validation only)
  - **Done when**: All validation commands exit 0, cache synced
  - **Verify**: `python3 -c "import ast; [ast.parse(open(f).read()) for f in ['ralph-parallel/scripts/mark-tasks-complete.py', 'ralph-parallel/scripts/verify-commit-provenance.py', 'ralph-parallel/scripts/build-teammate-prompt.py', 'ralph-parallel/scripts/validate-tasks-format.py', 'ralph-parallel/scripts/parse-and-partition.py']]" && bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Commit**: `fix(quality): address lint/type issues` (if needed)

- [ ] 4.2 [VERIFY] Final quality checkpoint
  - **Do**: Full verification of all 3 fixes:
    1. Confirm task-completed-gate.sh has 6 stages (grep for "Stage 6")
    2. Confirm mark-tasks-complete.py handles all edge cases
    3. Confirm build-teammate-prompt.py generates Signed-off-by section
    4. Confirm verify-commit-provenance.py exists and parses
    5. Confirm dispatch.md references lint in PHASE GATE and mark-tasks-complete in CLEANUP
    6. Run full test suite
  - **Files**: All modified files
  - **Done when**: All checks pass, no regressions
  - **Verify**: `grep -c 'Stage 6' /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh && grep -c 'mark-tasks-complete' /Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md && grep -c 'Signed-off-by' /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py`
  - **Commit**: `feat(quality-gates-v2): all fixes verified`

## Phase 5: Marketplace Polish

- [ ] 5.1 Add LICENSE file to marketplace repo root
  - **Do**:
    1. Create `LICENSE` at `/Users/patrickkavanagh/ralph-parallel-marketplace/LICENSE` with MIT license text
    2. Author: "Patrick Kavanagh", year: 2026
  - **Files**: `/Users/patrickkavanagh/ralph-parallel-marketplace/LICENSE`
  - **Done when**: LICENSE file exists with MIT text
  - **Verify**: `head -1 /Users/patrickkavanagh/ralph-parallel-marketplace/LICENSE`
  - **Commit**: `docs: add MIT LICENSE file`

- [ ] 5.2 Add CHANGELOG.md to marketplace repo root
  - **Do**:
    1. Create `CHANGELOG.md` at `/Users/patrickkavanagh/ralph-parallel-marketplace/CHANGELOG.md`
    2. Start with `# Changelog` header
    3. Add `## [0.2.0] - 2026-02-22` section with grouped changes: Added (baseline snapshot, validate-tasks-format, worktree strategy, lint gate, task writeback, commit provenance), Fixed (stale cache symlink, worktree isolation bug, INVALID display bug, --strategy flag wiring)
    4. Add `## [0.1.0] - 2026-02-20` section: Initial release with dispatch, status, merge commands
  - **Files**: `/Users/patrickkavanagh/ralph-parallel-marketplace/CHANGELOG.md`
  - **Done when**: CHANGELOG exists with both versions documented
  - **Verify**: `grep -c '0.2.0' /Users/patrickkavanagh/ralph-parallel-marketplace/CHANGELOG.md`
  - **Commit**: `docs: add CHANGELOG.md`

- [ ] 5.3 Enrich plugin.json and add plugin-level README
  - **Do**:
    1. Read `/Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/.claude-plugin/plugin.json`
    2. Add `"homepage"` and `"repository"` fields
    3. Create `/Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/README.md` with: overview, commands table (dispatch/status/merge), hooks table (4 hooks), scripts table (8 scripts), quick start example
  - **Files**: `/Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/.claude-plugin/plugin.json`, `/Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/README.md`
  - **Done when**: plugin.json has homepage/repository, README exists with commands/hooks/scripts tables
  - **Verify**: `python3 -c "import json; d=json.load(open('/Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/.claude-plugin/plugin.json')); assert 'homepage' in d"`
  - **Commit**: `docs: enrich plugin.json and add plugin-level README`

- [ ] 5.4 [VERIFY] Marketplace polish checkpoint
  - **Do**: Verify all marketplace files:
    1. LICENSE exists at repo root
    2. CHANGELOG.md exists with 0.2.0 section
    3. plugin.json has homepage field
    4. Plugin README exists
    5. Push to GitHub
  - **Files**: All marketplace files
  - **Done when**: All files verified and pushed
  - **Verify**: `ls /Users/patrickkavanagh/ralph-parallel-marketplace/LICENSE /Users/patrickkavanagh/ralph-parallel-marketplace/CHANGELOG.md /Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/README.md`
  - **Commit**: `chore(marketplace): polish for public distribution`

## Notes

- **POC shortcuts taken**: verify-commit-provenance.py deferred to Phase 2; edge case hardening deferred to Phase 2
- **Production TODOs**: Consider making lint blocking (not periodic) in a future version if teams want stricter enforcement
- **No automated test suite for plugin**: Verification relies on ast.parse, bash -n, and grep-based content checks. Phase 3 adds targeted unit tests for new scripts only.
- **Backward compatibility**: All 3 fixes are additive. Dispatches without lint commands, without completedGroups, or without Signed-off-by trailers continue to work.
- **Marketplace polish**: LICENSE, CHANGELOG, plugin.json enrichment, plugin README. Skipped agents/ and schemas/ directories (see audit evaluation).
