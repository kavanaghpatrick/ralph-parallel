---
spec: quality-gates
phase: execution
total_tasks: 11
created: 2026-02-22
generated: auto
---

# Tasks: quality-gates

## Phase 1: Make It Work (POC) — COMPLETE

- [x] 1.1 Add verify anti-pattern mandatory block to task-planner.md
- [x] 1.2 Make Explore agent spawning mandatory in task-planner.md
- [x] 1.3 Add Step 4.5 baseline test snapshot to dispatch.md
- [x] 1.4 Add parse_test_count function and baseline comparison to task-completed-gate.sh
- [x] 1.5 Update build-teammate-prompt.py quality section with baseline info
- [x] 1.6 POC Checkpoint
- [x] 2.1 Add dispatch.md Step 4.5 baseline read to teammate spawn (Step 6)
- [x] 2.2 [VERIFY] Final quality check

## Phase 3: Code Enforcement (replace prose with scripts)

Focus: Move anti-pattern enforcement from prose instructions to code that blocks dispatch.

- [x] 3.1 Add --check-verify-commands to validate-tasks-format.py
  - **Do**:
    1. Read `scripts/validate-tasks-format.py`
    2. Add constant `COMPILE_ONLY_PATTERNS` — list of regexes matching compile-only commands:
       - `^cargo check`, `^tsc --noEmit`, `^go build$`, `^pnpm build$`, `^npm run build$`, `^gcc `, `^g\+\+ `, `^make$`
    3. Add `validate_verify_commands(task_blocks)` function:
       - For each task block, extract the **Verify** field value (strip backticks)
       - Split on `&&` to get individual commands
       - If ALL commands match COMPILE_ONLY_PATTERNS (and none match test patterns), flag as error
       - Test patterns: `test`, `pytest`, `jest`, `vitest`, `spec`, `check.*test`
       - Exception: [VERIFY] checkpoint tasks and tasks with "config"/"docs" in description are exempt
       - Return list of `{task_id, line, verify_cmd, message}` errors
    4. Add `--check-verify-commands` flag to argparse
    5. When flag is set, run `validate_verify_commands` and add results to errors list
    6. Include fix suggestions: "Replace `cargo check` with `cargo test`" etc.
  - **Files**: `scripts/validate-tasks-format.py`
  - **Done when**: `python3 scripts/validate-tasks-format.py --tasks-md /dev/stdin --check-verify-commands` correctly rejects a tasks.md with `cargo check` as sole verify and accepts one with `cargo test`
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py').read())"` exits 0, and `echo '- [ ] 1.1 Test\n  - **Verify**: \x60cargo check\x60' | python3 /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py --tasks-md /dev/stdin --check-verify-commands; test $? -eq 2`
  - **Commit**: `feat(quality): add verify command validation to reject compile-only checks`

- [ ] 3.2 Add --require-quality-commands to validate-tasks-format.py
  - **Do**:
    1. Add `validate_quality_commands_section(content)` function:
       - Check for `## Quality Commands` section in content
       - If missing: return error
       - If present: extract Build/Typecheck/Lint/Test values
       - If Test is "N/A" or missing: return warning (not error — some projects have no tests)
       - Return parsed quality commands dict and any errors/warnings
    2. Add `--require-quality-commands` flag to argparse
    3. When flag is set, run validation and add results to errors/warnings
  - **Files**: `scripts/validate-tasks-format.py`
  - **Done when**: Script rejects tasks.md without `## Quality Commands` section when flag is passed
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py').read())"` exits 0, and `echo '# Tasks\n- [ ] 1.1 Foo\n  - **Verify**: \x60cargo test\x60' | python3 /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py --tasks-md /dev/stdin --require-quality-commands; test $? -eq 2`
  - **Commit**: `feat(quality): require Quality Commands section in tasks.md`

- [x] 3.3 Create capture-baseline.sh standalone script
  - **Do**:
    1. Create `scripts/capture-baseline.sh` — standalone script replacing dispatch.md Step 4.5 prose:
       - Input: `--dispatch-state <path>` (reads qualityCommands.test from it)
       - Reads test command from dispatch-state.json via jq
       - If no test command: output `{"testCount": -1, "reason": "no_test_command"}` and exit 0
       - Runs test command, captures output
       - Calls parse_test_count logic (same regex cascade as task-completed-gate.sh — extract to shared function or duplicate)
       - If test fails: output `{"testCount": -1, "exitCode": N, "reason": "tests_failing"}`
       - If parseable: output `{"testCount": N, "capturedAt": "ISO", "command": "cmd", "exitCode": 0}`
       - Updates dispatch-state.json in-place with baselineSnapshot field via jq
    2. Make executable: chmod +x
    3. Script is self-contained, no dependencies beyond jq and bash
  - **Files**: `scripts/capture-baseline.sh`
  - **Done when**: Script runs, captures baseline, writes to dispatch-state.json
  - **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/capture-baseline.sh` exits 0
  - **Commit**: `feat(quality): add deterministic baseline capture script`

## Notes

- **No test suite**: This plugin has no automated tests. Verification relies on `bash -n` syntax checks, `python3 ast.parse` syntax checks, and grep-based content verification.
- **External file**: task-planner.md is in the ralph-specum plugin cache, not this repo.
- **Backward compatible**: All changes are additive.
- **Code enforcement**: Tasks 3.1-3.3 replace prose instructions with scripts that block dispatch on violations.
