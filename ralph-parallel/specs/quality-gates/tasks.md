---
spec: quality-gates
phase: tasks
total_tasks: 8
created: 2026-02-22
generated: auto
---

# Tasks: quality-gates

## Phase 1: Make It Work (POC)

Focus: Get all four file modifications working. No tests (plugin has no test suite), verify via syntax checks and manual inspection.

- [ ] 1.1 Add verify anti-pattern mandatory block to task-planner.md
  - **Do**:
    1. Read `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md`
    2. After the `## [VERIFY] Task Format` section (after line 281), insert new `## Verify Command Anti-Patterns` section
    3. Use `<mandatory>` block containing:
       - Banned commands list: `cargo check`, `tsc --noEmit`, `go build` alone, `pnpm build` alone, `gcc`/`g++` alone
       - Required alternatives: `cargo test`, `pnpm test`, `pytest`, `go test ./...`, `bash -n` for shell, `python3 -c "import ast; ..."` for Python
       - Explanation: compile checks are supplemental (handled by quality gate hook), Verify must prove code WORKS
    4. After anti-patterns, insert `## Quality Commands Section` mandatory block requiring every tasks.md to start with `## Quality Commands` listing Build/Typecheck/Test/Lint commands (or "N/A")
  - **Files**: `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md`
  - **Done when**: task-planner.md contains both new mandatory sections with complete anti-pattern list and Quality Commands requirement
  - **Verify**: `grep -c "cargo check" ~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` returns at least 1, and `grep -c "Quality Commands Section" ~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` returns at least 1
  - **Commit**: `feat(quality): add verify anti-patterns and Quality Commands requirement to task-planner`
  - _Requirements: FR-1, FR-3, AC-1.1, AC-1.2, AC-1.3_
  - _Design: Component A_

- [ ] 1.2 Make Explore agent spawning mandatory in task-planner.md
  - **Do**:
    1. Read task-planner.md lines 119-145 (Use Explore for Context Gathering section)
    2. Change the description from advisory to mandatory: add "You MUST spawn at least one Explore subagent before writing any tasks. Skipping Explore results in guessed file paths and wrong verify commands. If you skip Explore, the generated tasks will have incorrect Files: and Verify: fields."
    3. Ensure this is within the existing `<mandatory>` block
  - **Files**: `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md`
  - **Done when**: Explore section contains "MUST spawn" language and explicit warning about skipping
  - **Verify**: `grep "MUST spawn" ~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` returns a match
  - **Commit**: `feat(quality): make Explore agent spawning mandatory in task-planner`
  - _Requirements: FR-2, AC-1.4_
  - _Design: Component A_

- [ ] 1.3 Add Step 4.5 baseline test snapshot to dispatch.md
  - **Do**:
    1. Read `commands/dispatch.md`
    2. Between Step 4 (Write Dispatch State) and Step 5 (Create Team), insert new `## Step 4.5: Capture Baseline Test Snapshot`
    3. Content:
       - Read `qualityCommands.test` from dispatch-state.json just written
       - If no test command: skip, leave baselineSnapshot null in state
       - Run test command, capture stdout+stderr
       - Parse test count using regex cascade (jest/vitest, pytest, cargo test, go test, generic fallback)
       - If test fails (pre-existing): set testCount to -1
       - If output unparseable: set testCount to -1
       - Update dispatch-state.json with: `"baselineSnapshot": { "testCount": N, "capturedAt": "ISO", "command": "cmd", "exitCode": N }`
    4. Include the regex patterns inline in the step description
    5. Add `"baselineSnapshot"` to the dispatch state schema in Step 4
  - **Files**: `commands/dispatch.md`
  - **Done when**: dispatch.md contains Step 4.5 with baseline capture logic and dispatch-state schema includes baselineSnapshot
  - **Verify**: `grep -c "Step 4.5" /Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` returns 1, and `grep -c "baselineSnapshot" /Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` returns at least 2
  - **Commit**: `feat(quality): add baseline test snapshot capture to dispatch flow`
  - _Requirements: FR-4, FR-5, AC-2.1, AC-2.2, AC-2.3_
  - _Design: Component B1_

- [ ] 1.4 Add parse_test_count function and baseline comparison to task-completed-gate.sh
  - **Do**:
    1. Read `hooks/scripts/task-completed-gate.sh`
    2. Before Stage 5 (around line 200), add `parse_test_count()` function:
       - Takes test output as $1
       - Regex cascade: jest/vitest `Tests:\s+(\d+) passed`, pytest `(\d+) passed`, cargo test `test result:.*(\d+) passed`, go test count `^ok\s+` lines, generic count pass/ok/checkmark lines
       - Returns count via echo, -1 if unparseable
    3. In Stage 5, after `TEST_EXIT == 0` path (after line 213 currently), add baseline comparison:
       - Read `baselineSnapshot.testCount` from dispatch-state.json
       - If baseline > 0: parse current count via `parse_test_count "$TEST_OUTPUT"`
       - If current < baseline * 90 / 100: exit 2 with regression message
       - If baseline is -1 or missing: skip comparison (backward compatible)
    4. Add informational log line showing baseline vs current count
  - **Files**: `hooks/scripts/task-completed-gate.sh`
  - **Done when**: Script contains `parse_test_count` function and baseline comparison logic in Stage 5
  - **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh` exits 0 (syntax valid), and `grep -c "parse_test_count" /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh` returns at least 2
  - **Commit**: `feat(quality): add test count regression detection to quality gate`
  - _Requirements: FR-6, FR-7, AC-3.1, AC-3.2, AC-3.3, AC-3.4_
  - _Design: Component B2_

- [ ] 1.5 Update build-teammate-prompt.py quality section with baseline info
  - **Do**:
    1. Read `scripts/build-teammate-prompt.py`
    2. Add optional `baseline_test_count` parameter to `build_quality_section()` and `build_prompt()`
    3. In `build_quality_section()`, if baseline_test_count > 0, append line: `"Baseline: {N} tests passing at dispatch. Do not delete tests — the quality gate detects test count regression."`
    4. In `main()`, read baseline from partition JSON or quality_commands if available (add `--baseline-test-count` CLI arg, default 0)
    5. Pass through to `build_prompt()`
  - **Files**: `scripts/build-teammate-prompt.py`
  - **Done when**: Script accepts `--baseline-test-count` arg and includes baseline info in quality section when > 0
  - **Verify**: `python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py').read())"` exits 0, and `grep -c "baseline" /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py` returns at least 3
  - **Commit**: `feat(quality): add baseline test count info to teammate prompts`
  - _Requirements: FR-8_
  - _Design: Component B3_

- [ ] 1.6 POC Checkpoint
  - **Do**: Verify all four files are modified correctly:
    1. `bash -n hooks/scripts/task-completed-gate.sh` — syntax valid
    2. `python3 -c "import ast; ast.parse(open('scripts/build-teammate-prompt.py').read())"` — syntax valid
    3. `grep "cargo check" ~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` — anti-patterns present
    4. `grep "Step 4.5" commands/dispatch.md` — baseline step present
    5. `grep "parse_test_count" hooks/scripts/task-completed-gate.sh` — parser function present
  - **Done when**: All 5 checks pass
  - **Verify**: `bash -n /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh && python3 -c "import ast; ast.parse(open('/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py').read())"` exits 0
  - **Commit**: `feat(quality): complete POC for quality gate improvements`

## Phase 2: Polish and Quality Gates

- [ ] 2.1 Add dispatch.md Step 4.5 baseline read to teammate spawn (Step 6)
  - **Do**:
    1. Read dispatch.md Step 6 (Spawn Teammates)
    2. After extracting `QUALITY_COMMANDS_JSON`, add extraction of baseline test count from dispatch-state.json
    3. Pass `--baseline-test-count $BASELINE_COUNT` to build-teammate-prompt.py invocation
    4. Ensure backward compatibility: if baselineSnapshot is null/missing, pass 0
  - **Files**: `commands/dispatch.md`
  - **Done when**: Step 6 passes baseline count to build-teammate-prompt.py
  - **Verify**: `grep "baseline-test-count" /Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` returns a match
  - **Commit**: `feat(quality): wire baseline count through dispatch to teammate prompts`
  - _Requirements: FR-8, AC-2.2_
  - _Design: Component B1, B3_

- [ ] 2.2 [VERIFY] Final quality check
  - **Do**: Run all verification commands:
    1. `bash -n hooks/scripts/task-completed-gate.sh`
    2. `python3 -c "import ast; ast.parse(open('scripts/build-teammate-prompt.py').read())"`
    3. `bash -n hooks/scripts/dispatch-coordinator.sh`
    4. `bash -n hooks/scripts/file-ownership-guard.sh`
    5. `bash -n hooks/scripts/session-setup.sh`
    6. `python3 -c "import ast; ast.parse(open('scripts/parse-and-partition.py').read())"`
    7. Verify no syntax errors in any script
  - **Verify**: All 6 commands exit 0
  - **Done when**: All plugin scripts pass syntax validation
  - **Commit**: `chore(quality): pass quality checkpoint` (only if fixes needed)

## Notes

- **No test suite**: This plugin has no automated tests. Verification relies on `bash -n` syntax checks, `python3 ast.parse` syntax checks, and grep-based content verification.
- **External file**: task-planner.md is in the ralph-specum plugin cache, not this repo. It needs to be committed separately or the user needs to sync it.
- **Backward compatible**: All changes are additive. Old dispatch-state.json files without baselineSnapshot will still work (gate falls back to pass/fail only).
- **POC shortcuts**: No integration test of the full dispatch->gate->baseline flow. Verified at file level only.
