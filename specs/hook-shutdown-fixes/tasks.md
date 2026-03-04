# Tasks: hook-shutdown-fixes

## Quality Commands

- **Build**: N/A (shell scripts, no build step)
- **Typecheck**: N/A (bash scripts)
- **Lint**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
- **Test**: `cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh`

## Phase 1: Fix task-completed-gate.sh (Bug 1 — Sentinel File Values)

### Group 1: [task-completed-gate-fix]
**Files owned**: ralph-parallel/hooks/scripts/task-completed-gate.sh, ralph-parallel/hooks/scripts/test_gate.sh

- [x] 1.1 Add sentinel value check after TASK_FILES extraction in Stage 3
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Do**:
    - Open task-completed-gate.sh, locate Stage 3 (line ~218, after `done < "$SPEC_DIR/tasks.md"`)
    - Insert the following 4 lines between the `done` and the `if [ -n "$TASK_FILES" ]` guard:
      ```bash
      # Skip file check for sentinel values (none, n/a, -, empty)
      case "$(echo "$TASK_FILES" | tr '[:upper:]' '[:lower:]')" in
        none|n/a|n/a\ *|-|"") TASK_FILES="" ;;
      esac
      ```
    - This goes after line 218 (`done < "$SPEC_DIR/tasks.md"`) and before line 220 (`if [ -n "$TASK_FILES" ]`)
  - **Done when**: The sentinel case statement is present between TASK_FILES extraction and file existence check
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && echo "syntax ok"`
  - **Commit**: `fix(hooks): add sentinel value check for Files field in task-completed-gate.sh`
  - _Requirements: FR-1, AC-1.1 through AC-1.7_
  - _Design: Fix 1 — Sentinel File Values_

- [x] 1.2 Add sentinel test cases to test_gate.sh
  - **Files**: `ralph-parallel/hooks/scripts/test_gate.sh`
  - **Do**:
    - Add 3 new setup functions before the summary section in test_gate.sh:
      ```bash
      setup_files_none() {
        local dir="$1"
        cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
      - [x] 1.1 Test task
        - **Verify**: `true`
        - **Files**: none
      EOF
      }

      setup_files_na_with_note() {
        local dir="$1"
        cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
      - [x] 1.1 Test task
        - **Verify**: `true`
        - **Files**: N/A (validation only)
      EOF
      }

      setup_files_dash() {
        local dir="$1"
        cat > "$dir/specs/test-spec/tasks.md" <<'EOF'
      - [x] 1.1 Test task
        - **Verify**: `true`
        - **Files**: -
      EOF
      }
      ```
    - Add 3 new run_test invocations before the summary section:
      ```bash
      run_test "files sentinel: none"              0  ""  setup_files_none
      run_test "files sentinel: N/A (with note)"   0  ""  setup_files_na_with_note
      run_test "files sentinel: dash"              0  ""  setup_files_dash
      ```
  - **Done when**: test_gate.sh has 10 tests total (7 existing + 3 new sentinel tests), all passing
  - **Verify**: `cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh`
  - **Commit**: `test(hooks): add sentinel value test cases for Files field`
  - _Requirements: TR-1, TR-2, TR-3, AC-1.1 through AC-1.5_
  - _Design: Test Design — test_gate.sh Additions_

- [x] 1.3 [VERIFY] Quality checkpoint: syntax + tests for Phase 1
  - **Files**: none
  - **Do**:
    - Run bash syntax check on task-completed-gate.sh
    - Run full test_gate.sh suite (must run from /tmp to avoid git root interference)
    - Confirm all 10 tests pass (7 original + 3 sentinel)
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh`
  - **Done when**: Syntax valid and all 10 tests pass
  - **Commit**: `chore(hooks): pass Phase 1 quality checkpoint` (only if fixes needed)

## Phase 2: Fix teammate-idle-gate.sh (Bugs 2+3 — Safety Valve + completedGroups)

### Group 2: [teammate-idle-gate-fix]
**Files owned**: ralph-parallel/hooks/scripts/teammate-idle-gate.sh, ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh

- [x] 2.1 Rewrite teammate-idle-gate.sh with counter functions, completedGroups bypass, and safety valve
  - **Files**: `ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
  - **Do**:
    - Replace the entire file with the design.md "Complete Modified teammate-idle-gate.sh" section
    - Key additions over current code:
      1. `read_block_counter()` and `write_block_counter()` functions (inlined from dispatch-coordinator.sh pattern)
      2. `MAX_IDLE_BLOCKS` env var (default 5 via `RALPH_MAX_IDLE_BLOCKS`)
      3. Counter file at `/tmp/ralph-idle-${SPEC_NAME}-${TEAMMATE_NAME}`
      4. completedGroups bypass after dispatch state load, BEFORE tasks.md check
      5. Safety valve check between uncompleted-tasks detection and exit 2
      6. Block count logging in stderr feedback message
    - Ensure `set -euo pipefail` is first line after shebang
    - Ensure all jq calls have `2>/dev/null` fallbacks
    - Ensure counter file format is `count:status:dispatchedAt` (matches dispatch-coordinator.sh)
  - **Done when**: teammate-idle-gate.sh has counter functions, completedGroups check, safety valve, and block counter logging
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/teammate-idle-gate.sh && echo "syntax ok"`
  - **Commit**: `fix(hooks): add safety valve and completedGroups bypass to teammate-idle-gate.sh`
  - _Requirements: FR-2, FR-3, FR-4, FR-5, AC-2.1 through AC-2.7, AC-3.1 through AC-3.5_
  - _Design: Fix 2 + Fix 3 + Complete Modified teammate-idle-gate.sh_

- [x] 2.2 Create test_teammate_idle_gate.sh with full test suite
  - **Files**: `ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh`
  - **Do**:
    - Create new test file following the test_gate.sh `run_test()` pattern
    - Include `run_test()` helper with expected_exit + check_stderr
    - Add 7 setup functions and test cases from design.md:
      1. `setup_all_tasks_done` — all [x] checkboxes, allow idle (exit 0)
      2. `setup_uncompleted_tasks` — [ ] checkbox, fresh counter, block (exit 2, "uncompleted tasks")
      3. `setup_safety_valve` — counter pre-seeded at 5, allow idle (exit 0, "SAFETY VALVE")
      4. `setup_counter_reset` — counter=10 with old dispatchedAt, block (exit 2, "uncompleted tasks")
      5. `setup_completed_groups_bypass` — group in completedGroups, stale tasks.md, allow (exit 0, "completedGroups")
      6. `setup_no_dispatch_state` — no .dispatch-state.json, allow idle (exit 0)
      7. `run_test_non_dispatch` — team_name without `-parallel` suffix, allow (exit 0)
    - Each setup must clean stale counter files (`rm -f /tmp/ralph-idle-test-spec-test-group`)
    - Add summary section with pass/fail counts
    - Ensure cleanup of counter files after all tests
  - **Done when**: test_teammate_idle_gate.sh has 7 tests and all pass
  - **Verify**: `cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh`
  - **Commit**: `test(hooks): add test_teammate_idle_gate.sh with 7 test cases`
  - _Requirements: TR-4 through TR-11_
  - _Design: Test Design — test_teammate_idle_gate.sh_

- [x] 2.3 [VERIFY] Quality checkpoint: syntax + all tests for Phase 2
  - **Files**: none
  - **Do**:
    - Run bash syntax check on teammate-idle-gate.sh
    - Run test_teammate_idle_gate.sh (7 tests)
    - Run test_gate.sh to confirm no regressions (10 tests)
    - Both test files must run from /tmp to avoid git root interference
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/teammate-idle-gate.sh && cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh`
  - **Done when**: All syntax valid, 7 idle gate tests pass, 10 task gate tests pass
  - **Commit**: `chore(hooks): pass Phase 2 quality checkpoint` (only if fixes needed)

## Phase 3: Integration and Sync

### Group 3: [integration]
**Files owned**: none

- [x] 3.1 Run full local CI suite (all hook tests + syntax checks)
  - **Files**: none
  - **Do**:
    - Run bash syntax check on both modified scripts
    - Run test_gate.sh (10 tests, from /tmp)
    - Run test_teammate_idle_gate.sh (7 tests, from /tmp)
    - Run test_stop_hook.sh to confirm no regressions
    - Run test_session_isolation.sh to confirm no regressions
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/teammate-idle-gate.sh && cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_stop_hook.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All tests green, zero regressions across all hook test suites
  - **Commit**: `chore(hooks): pass full local CI suite` (only if fixes needed)
  - _Requirements: NFR-1, NFR-2, TR-12_

- [x] 3.2 Sync plugin to cache
  - **Files**: none
  - **Do**:
    - Run rsync to sync ralph-parallel/ to the plugin cache symlink target
    - Command: `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/`
    - Verify the symlink still resolves correctly
  - **Done when**: Plugin cache updated with all hook fixes
  - **Verify**: `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/ && ls -la ~/.claude/plugins/cache/ralph-parallel && test -f ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.2.0/hooks/scripts/teammate-idle-gate.sh && echo "sync ok"`
  - **Commit**: none (cache sync, not a code change)

## Phase 4: Quality Gates

- [x] 4.1 [VERIFY] Full local CI: syntax + all tests + regression check
  - **Files**: none
  - **Do**:
    - Run complete local CI suite:
      1. Bash syntax: `bash -n` on task-completed-gate.sh, teammate-idle-gate.sh
      2. Task gate tests: test_gate.sh (10 tests)
      3. Idle gate tests: test_teammate_idle_gate.sh (7 tests)
      4. Stop hook tests: test_stop_hook.sh
      5. Session isolation tests: test_session_isolation.sh
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/teammate-idle-gate.sh && cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_stop_hook.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_session_isolation.sh`
  - **Done when**: All tests pass, zero regressions
  - **Commit**: `chore(hooks): pass local CI` (if fixes needed)

- [ ] 4.2 Create PR and verify CI
  - **Files**: none
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. Push branch: `git push -u origin $(git branch --show-current)`
    3. Create PR: `gh pr create --title "fix(hooks): break cascade shutdown deadlock in task-completed-gate and teammate-idle-gate" --body "..."`
    4. PR body should reference all 5 bugs, 3 fixes, and test coverage (10 + 7 = 17 tests)
  - **Verify**: `gh pr checks --watch` (wait for CI)
  - **Done when**: PR created and CI passes
  - **Commit**: none

## Phase 5: PR Lifecycle

- [ ] 5.1 [VERIFY] CI pipeline passes
  - **Files**: none
  - **Do**: Check GitHub Actions status after push
  - **Verify**: `gh pr checks`
  - **Done when**: All CI checks show passing
  - **Commit**: none

- [ ] 5.2 [VERIFY] AC checklist
  - **Files**: none
  - **Do**: Programmatically verify each acceptance criterion:
    - AC-1.1 through AC-1.5: Confirmed by test_gate.sh sentinel tests (exit 0 for none, N/A, -)
    - AC-1.6: Confirmed by existing `file existence pass` test (real file, exit 0)
    - AC-1.7: Confirmed by existing `file existence fail` test (missing file, exit 2)
    - AC-2.1 through AC-2.7: Confirmed by test_teammate_idle_gate.sh safety valve + counter reset tests
    - AC-3.1 through AC-3.5: Confirmed by test_teammate_idle_gate.sh completedGroups + fallthrough tests
    - AC-4.1, AC-4.2: Solved by Bug 1 fix (no separate code change)
    - AC-5.1 through AC-5.3: Solved by combination of all fixes
    - NFR-1: All 7 original test_gate.sh tests pass unchanged
    - NFR-2: test_stop_hook.sh and test_session_isolation.sh pass
    - NFR-5: Counter functions are inlined, no shared lib
  - **Verify**: `cd /tmp && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh && bash /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && grep -c "read_block_counter\|write_block_counter" /Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/teammate-idle-gate.sh | grep -q "[2-9]" && echo "AC check passed"`
  - **Done when**: All acceptance criteria confirmed met via automated checks
  - **Commit**: none

## Notes

- **POC shortcuts taken**: None -- all fixes are production-quality (additive guards, no hacks)
- **Test environment note**: test_gate.sh and test_teammate_idle_gate.sh must run from `/tmp` (not inside the git repo) because `git rev-parse --show-toplevel` in the hook scripts would override the test tmpdir's CWD
- **Production TODOs**: None -- this is a bug fix spec, not a feature spec
- **File count**: 2 modified (task-completed-gate.sh, teammate-idle-gate.sh), 1 modified tests (test_gate.sh), 1 new test file (test_teammate_idle_gate.sh)
- **Risk**: Low -- all changes are additive guards before existing logic. No existing behavior removed.
