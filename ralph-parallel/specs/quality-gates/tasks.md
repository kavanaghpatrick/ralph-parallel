---
spec: quality-gates
phase: execution
total_tasks: 18
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

- [x] 3.2 Add --require-quality-commands to validate-tasks-format.py
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

## Quality Commands

**Build**: N/A
**Typecheck**: N/A
**Lint**: N/A
**Test**: N/A

## Phase 4: Audit Fixes (harden scripts from parallel audit)

Focus: Fix all CRITICAL and HIGH issues found by 5 parallel audit agents. No new features — only correctness fixes.

- [x] 4.1 Fix _cmds_overlap prefix matching and command splitting in validate-tasks-format.py
  **Do**:
  1. Read `scripts/validate-tasks-format.py`
  2. Fix `_cmds_overlap()`: Replace prefix matching (`a.startswith(b)`) with exact first-token matching — split both commands on whitespace, compare first tokens for equality. Only match if the base command is identical (e.g., `cargo build` should NOT match `cargo build --release` as "overlapping" in the wrong direction — but `cargo build --release` SHOULD match against declared `cargo build`)
  3. Fix `validate_verify_commands()`: Split verify commands on `&&`, `||`, `;`, and `|` (not just `&&`). For piped commands, only check the first command in the pipe (the one that actually runs the tool)
  4. Add case-insensitive matching for `N/A` in `validate_quality_commands_section()` (match `n/a`, `N/a`, `N/A`)
  5. Handle empty/whitespace-only verify commands: if extracted verify is blank, add a warning (not error)
  **Files**: `scripts/validate-tasks-format.py`
  **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py').read())"` exits 0

- [x] 4.2 Fix ANSI stripping and temp file safety in capture-baseline.sh
  **Do**:
  1. Read `scripts/capture-baseline.sh`
  2. Add ANSI escape code stripping before parse_test_count: `TEST_OUTPUT=$(echo "$TEST_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g')`
  3. Fix temp file safety: use `mktemp` instead of predictable `.tmp` suffix: `TMPFILE=$(mktemp "${DISPATCH_STATE}.XXXXXX")` then `mv "$TMPFILE" "$DISPATCH_STATE"`. Apply to all 4 jq update sites.
  4. Add `cd "$PROJECT_ROOT"` validation: check directory exists before cd
  **Files**: `scripts/capture-baseline.sh`
  **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/capture-baseline.sh` exits 0

- [x] 4.3 Fix jq null handling, baseline threshold, and ANSI stripping in task-completed-gate.sh
  **Do**:
  1. Read `hooks/scripts/task-completed-gate.sh`
  2. Fix jq null handling: change `jq -r '.baselineSnapshot.testCount // empty'` — add explicit null/string check: `BASELINE_COUNT=$(jq -r '.baselineSnapshot.testCount // empty' ... || true)` then validate with `[ "$BASELINE_COUNT" != "null" ]`
  3. Fix baseline threshold for small counts: when baseline <= 10, use `THRESHOLD=$((BASELINE_COUNT - 1))` instead of percentage (prevents integer truncation making threshold 0)
  4. Add ANSI stripping before parse_test_count: `TEST_OUTPUT=$(echo "$TEST_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g')`
  **Files**: `hooks/scripts/task-completed-gate.sh`
  **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh` exits 0

- [x] 4.4 Fix dispatch.md error table and --check-verify-commands silent no-op
  **Do**:
  1. Read `commands/dispatch.md`
  2. Update Step 1.5 error handling: Add exit code 3 behavior (valid with warnings — display and continue). Currently only exit 0 and 2 are documented.
  3. Update error table to include validate-tasks-format.py exit codes (0, 1, 2, 3) separately from parse-and-partition.py exit codes (0, 1, 2, 3, 4)
  4. Add note to Step 1.5: when --check-verify-commands runs but Quality Commands section is missing, the verify check is safely skipped (by design — cannot compare without declared commands). This is NOT a silent failure; --require-quality-commands handles the missing section warning.
  **Files**: `commands/dispatch.md`
  **Verify**: `grep -c 'exit.*3' /Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` returns at least 1

- [x] 4.5 Sync to plugin cache and validate all scripts
  **Do**:
  1. Run `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/`
  2. Validate all Python scripts: `python3 -c "import ast; ast.parse(open('ralph-parallel/scripts/validate-tasks-format.py').read())"`
  3. Validate all bash scripts: `bash -n ralph-parallel/scripts/capture-baseline.sh && bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh`
  4. Run validate-tasks-format.py against all existing specs to confirm no regressions
  **Files**: N/A (validation only)
  **Verify**: All 3 validation commands exit 0

- [x] 4.6 [VERIFY] Audit fixes checkpoint
  **Do**: Verify all audit fix tasks produced correct changes:
  1. Confirm _cmds_overlap uses token matching (not prefix)
  2. Confirm verify split handles `|`, `;`, `||`
  3. Confirm ANSI stripping present in both bash scripts
  4. Confirm jq null handling fixed in task-completed-gate.sh
  5. Confirm baseline threshold handles small counts
  6. Confirm dispatch.md error table is complete
  **Files**: All modified files
  **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py').read())"` && `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/capture-baseline.sh` && `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`

## Notes

- **No test suite**: This plugin has no automated tests. Verification relies on `bash -n` syntax checks, `python3 ast.parse` syntax checks, and grep-based content verification.
- **External file**: task-planner.md is in the ralph-specum plugin cache, not this repo.
- **Backward compatible**: All changes are additive.
- **Code enforcement**: Tasks 3.1-3.3 replace prose instructions with scripts that block dispatch on violations.
- **Audit fixes**: Tasks 4.1-4.6 fix issues found by parallel audit agents (no new features).
