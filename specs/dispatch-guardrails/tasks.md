---
spec: dispatch-guardrails
phase: tasks
total_tasks: 11
created: 2026-02-22T22:30:00Z
generated: auto
---

# Tasks: dispatch-guardrails

## Phase 1: Make It Work (POC)

Focus: Get `--manual-groups` and validate-prompt.py working end-to-end. Skip edge cases, accept minimal validation.

- [ ] 1.1 [P] Add `--manual-groups` arg and `_build_groups_from_manual()` to parse-and-partition.py
  - **Do**:
    1. Add `--manual-groups` argument to `main()` argparse (type=str, default=None, help text)
    2. Create `_build_groups_from_manual(manual_json, all_tasks, parallel_tasks, max_teammates)` function:
       - Parse JSON string into dict: `{"group-name": ["1.1", "1.2"], ...}`
       - Build `task_map` from `all_tasks` by ID
       - For each group: collect incomplete tasks, compute `ownedFiles` as union of all task files
       - Unassigned incomplete non-VERIFY tasks go to `serial_tasks`
       - Return `(groups, serial_tasks)` tuple matching `_build_groups_automatic` signature
    3. In `partition_tasks()`, add `manual_groups=None` parameter. Check before predefined groups:
       ```python
       if manual_groups:
           groups, serial_tasks = _build_groups_from_manual(
               manual_groups, tasks, parallel_tasks, max_teammates)
       elif predefined:
           ...
       ```
    4. In `main()`, pass `manual_groups=args.manual_groups` to `partition_tasks()`
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: `python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md <test-tasks.md> --manual-groups '{"g1":["1.1"],"g2":["1.2"]}' | jq .groups` outputs 2 groups with correct ownedFiles
  - **Verify**: `python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md --manual-groups '{"infra":["1.1","1.2"],"api":["1.3"]}' 2>&1 | head -20`
  - **Commit**: `feat(parallel): add --manual-groups flag to parse-and-partition.py`
  - _Requirements: FR-1, FR-2, FR-3_
  - _Design: Component A_

- [ ] 1.2 [P] Create validate-prompt.py with required section checks
  - **Do**:
    1. Create `ralph-parallel/scripts/validate-prompt.py` following validate-tasks-format.py patterns
    2. Define REQUIRED_SECTIONS list:
       ```python
       REQUIRED_SECTIONS = [
           {"name": "File Ownership", "pattern": r"^## File Ownership"},
           {"name": "Quality Checks", "pattern": r"^## Quality Checks"},
           {"name": "Commit Convention", "pattern": r"^## Commit Convention"},
           {"name": "Signed-off-by", "pattern": r"Signed-off-by:"},
       ]
       ```
    3. Implement `validate_prompt(content: str, required_sections=None) -> dict` returning `{"valid": bool, "present": [...], "missing": [...], "warnings": [...]}`
    4. Add argparse with `--prompt-file` (or read stdin), `--json` flag, `--required-sections` override
    5. Exit code 0 = all present, exit code 1 = sections missing
    6. Add shebang and docstring matching validate-tasks-format.py style
  - **Files**: `ralph-parallel/scripts/validate-prompt.py`
  - **Done when**: `echo "## File Ownership\n## Quality Checks\n## Commit Convention\nSigned-off-by: test" | python3 ralph-parallel/scripts/validate-prompt.py` exits 0
  - **Verify**: `echo "no sections here" | python3 ralph-parallel/scripts/validate-prompt.py --json 2>&1`
  - **Commit**: `feat(parallel): add validate-prompt.py for post-dispatch validation`
  - _Requirements: FR-4, FR-5_
  - _Design: Component B_

- [ ] 1.3 Add `--manual-groups` to dispatch.md arg parsing and Step 6.5 validation
  - **Do**:
    1. In dispatch.md "Parse Arguments" section, add `--manual-groups` to the argument list
    2. In Step 2 bash block, add `--manual-groups "$manualGroups"` to parse-and-partition.py invocation (only when flag provided)
    3. Add Step 6.5 between Step 6 (spawn) and Step 7 (coordination loop):
       ```text
       ## Step 6.5: Validate Teammate Prompts (via script)

       After spawning all teammates, validate that each generated prompt contains required sections:

       ```bash
       python3 ${CLAUDE_PLUGIN_ROOT}/scripts/validate-prompt.py \
         --prompt-file /tmp/$specName-group-$groupName-prompt.txt
       ```

       For each group prompt:
       - Exit 0: Prompt valid, continue
       - Exit 1: WARNING — missing sections detected. Display which sections are missing.
         Regenerate the prompt via build-teammate-prompt.py pipeline. Do NOT manually edit prompts.

       This is fail-open: warn loudly but do NOT shut down already-spawned teammates.
       ```
    4. In Step 6 bash block, add line to save each prompt to `/tmp/$specName-group-$groupName-prompt.txt` before spawning
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: dispatch.md contains `--manual-groups` in args section, Step 6.5 header exists, validate-prompt.py invocation present
  - **Verify**: `grep -c 'manual-groups\|validate-prompt\|Step 6.5' ralph-parallel/commands/dispatch.md`
  - **Commit**: `feat(parallel): wire manual-groups and prompt validation into dispatch flow`
  - _Requirements: FR-6_
  - _Design: Component C_

- [ ] 1.4 [VERIFY] POC Checkpoint
  - **Do**: Verify all three components work together end-to-end:
    1. Run parse-and-partition.py with `--manual-groups` against a real tasks.md
    2. Pipe output through build-teammate-prompt.py
    3. Pipe prompt through validate-prompt.py
    4. Confirm validate-prompt.py exits 0 for pipeline-generated prompts
    5. Confirm validate-prompt.py exits 1 for a manually-written prompt missing sections
  - **Done when**: Full pipeline (parse -> build-prompt -> validate) works with manual groups
  - **Verify**: `python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md --manual-groups '{"g1":["1.1","1.2"]}' > /tmp/test-partition.json && python3 ralph-parallel/scripts/build-teammate-prompt.py --partition-file /tmp/test-partition.json --group-index 0 --spec-name test --project-root /tmp --task-ids "#1,#2" | python3 ralph-parallel/scripts/validate-prompt.py`
  - **Commit**: `feat(parallel): complete dispatch-guardrails POC`

## Phase 2: Refactoring

After POC validated, harden edge cases and error handling.

- [ ] 2.1 Add error handling for `--manual-groups` edge cases
  - **Do**:
    1. In `_build_groups_from_manual()`: validate JSON parse (try/except json.JSONDecodeError → stderr + exit 1)
    2. Validate all task IDs exist in parsed tasks; report unknown IDs to stderr
    3. Skip completed tasks silently (same as predefined groups pattern)
    4. Enforce `--max-teammates`: if len(groups) > max_teammates, truncate and warn
    5. Handle empty groups (all tasks completed) — remove from output
    6. Handle duplicate task IDs across groups — error with clear message
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Invalid JSON, unknown task IDs, and duplicate assignments all produce clear error messages
  - **Verify**: `python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md --manual-groups 'invalid json' 2>&1 | grep -i error`
  - **Commit**: `refactor(parallel): add error handling for manual-groups edge cases`
  - _Requirements: AC-1.3_
  - _Design: Error Handling_

- [ ] 2.2 Add `--required-sections` override to validate-prompt.py
  - **Do**:
    1. Add `--required-sections` arg accepting comma-separated section names
    2. When provided, override default REQUIRED_SECTIONS (match by name, keep existing patterns)
    3. Add `format_report()` function for human-readable text output (matching validate-tasks-format.py pattern)
    4. Ensure stdin and `--prompt-file` both work cleanly
  - **Files**: `ralph-parallel/scripts/validate-prompt.py`
  - **Done when**: `--required-sections "File Ownership,Quality Checks"` validates only those 2 sections
  - **Verify**: `echo "## File Ownership" | python3 ralph-parallel/scripts/validate-prompt.py --required-sections "File Ownership" && echo "exit 0"`
  - **Commit**: `refactor(parallel): add --required-sections override to validate-prompt.py`
  - _Requirements: FR-8_
  - _Design: Component B_

## Phase 3: Testing

- [ ] 3.1 Add unit tests for `_build_groups_from_manual()` in test_parse_and_partition.py
  - **Do**:
    1. Import `_build_groups_from_manual` via importlib pattern (existing in test file)
    2. Also import `parse_tasks`, `build_dependency_graph`, `partition_tasks`
    3. Add `TestManualGroups` class with tests:
       - `test_basic_manual_groups`: 2 groups, correct task assignment and ownedFiles
       - `test_unassigned_tasks_become_serial`: tasks not in any group → serial_tasks
       - `test_invalid_json_exits`: bad JSON string raises SystemExit
       - `test_unknown_task_id_exits`: non-existent task ID raises SystemExit
       - `test_completed_tasks_skipped`: completed tasks filtered out
       - `test_max_teammates_truncation`: groups beyond limit truncated
       - `test_duplicate_task_ids_error`: same task in 2 groups raises error
       - `test_manual_overrides_predefined`: manual groups take priority over `### Group` annotations
    4. Use pytest fixtures for sample tasks.md content
  - **Files**: `ralph-parallel/scripts/test_parse_and_partition.py`
  - **Done when**: All 8 tests pass
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/test_parse_and_partition.py -v -k "manual" 2>&1 | tail -15`
  - **Commit**: `test(parallel): add unit tests for manual-groups partitioning`
  - _Requirements: NFR-4_

- [ ] 3.2 Create test_validate_prompt.py with section validation tests
  - **Do**:
    1. Create `ralph-parallel/scripts/test_validate_prompt.py` using importlib pattern
    2. Import `validate_prompt` function
    3. Add `TestValidatePrompt` class with tests:
       - `test_all_sections_present`: full prompt from build-teammate-prompt.py → valid
       - `test_missing_file_ownership`: prompt without section → missing list contains it
       - `test_missing_quality_checks`: prompt without section → detected
       - `test_missing_commit_convention`: prompt without section → detected
       - `test_missing_signed_off_by`: prompt without trailer → detected
       - `test_custom_required_sections`: override list works
       - `test_empty_prompt`: empty string → all missing
    4. Add `TestValidatePromptCLI` class:
       - `test_valid_prompt_exits_0`: subprocess with full prompt → exit 0
       - `test_invalid_prompt_exits_1`: subprocess with empty prompt → exit 1
       - `test_json_output`: subprocess with `--json` → parseable JSON
  - **Files**: `ralph-parallel/scripts/test_validate_prompt.py`
  - **Done when**: All 10 tests pass
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/test_validate_prompt.py -v 2>&1 | tail -15`
  - **Commit**: `test(parallel): add tests for validate-prompt.py`
  - _Requirements: NFR-4_

- [ ] 3.3 Add integration test: manual-groups through full pipeline
  - **Do**:
    1. In test_parse_and_partition.py, add `TestManualGroupsIntegration` class
    2. Test: write a sample tasks.md to tmp_path, run parse-and-partition.py with `--manual-groups` via subprocess, verify JSON output schema matches auto-partition output schema
    3. Test: pipe partition JSON to build-teammate-prompt.py, pipe output to validate-prompt.py, assert exit 0
    4. This tests the full pipeline: parse → partition → build-prompt → validate
  - **Files**: `ralph-parallel/scripts/test_parse_and_partition.py`
  - **Done when**: Integration test passes end-to-end
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/test_parse_and_partition.py -v -k "integration" 2>&1 | tail -15`
  - **Commit**: `test(parallel): add integration test for manual-groups pipeline`

## Phase 4: Quality Gates

- [ ] 4.1 Local quality check
  - **Do**: Run all quality checks locally
    1. Run full test suite: `python3 -m pytest ralph-parallel/scripts/ -v`
    2. Check all Python scripts for syntax: `python3 -m py_compile ralph-parallel/scripts/validate-prompt.py`
    3. Verify no import errors in all modified scripts
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/ -v 2>&1 | tail -5`
  - **Done when**: All tests pass, no syntax errors
  - **Commit**: `fix(parallel): address any lint/type issues` (if needed)

- [ ] 4.2 [VERIFY] Final verification and PR
  - **Do**:
    1. Run full test suite one more time
    2. Verify parse-and-partition.py `--help` shows `--manual-groups`
    3. Verify validate-prompt.py `--help` shows all options
    4. Push branch, create PR with `gh pr create`
  - **Verify**: `python3 ralph-parallel/scripts/parse-and-partition.py --help 2>&1 | grep manual-groups && python3 ralph-parallel/scripts/validate-prompt.py --help 2>&1 | grep prompt-file`
  - **Done when**: PR created, all checks pass

## Notes

- **POC shortcuts taken**: Minimal error handling in Phase 1; no `--required-sections` override until Phase 2
- **Production TODOs**: Phase 2 adds error handling for all edge cases
- **Key risk**: dispatch.md changes are advisory (prose) — the real enforcement is validate-prompt.py detecting bypasses post-spawn
