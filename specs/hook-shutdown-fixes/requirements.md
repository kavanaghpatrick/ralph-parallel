---
spec: hook-shutdown-fixes
phase: requirements
created: 2026-03-04T23:10:00Z
---

# Requirements: Hook Shutdown Fixes

## Goal

Fix 5 interacting bugs in ralph-parallel hooks (task-completed-gate.sh, teammate-idle-gate.sh) that create a cascade shutdown deadlock where teammates loop indefinitely, burning tokens with no escape mechanism.

## User Stories

### US-1: Sentinel File Values Don't Block Task Completion

**As a** dispatch teammate
**I want** tasks with `**Files**: none` (or `N/A`, `-`) to pass the file existence check
**So that** I can mark tasks complete without being blocked by phantom filename checks

**Acceptance Criteria:**

- [ ] AC-1.1: Task with `**Files**: none` passes Stage 3 (exit 0)
- [ ] AC-1.2: Task with `**Files**: N/A` passes Stage 3 (exit 0)
- [ ] AC-1.3: Task with `**Files**: N/A (validation only)` passes Stage 3 (exit 0)
- [ ] AC-1.4: Task with `**Files**: -` passes Stage 3 (exit 0)
- [ ] AC-1.5: Case-insensitive (`None`, `NONE`, `n/a`) all pass
- [ ] AC-1.6: Task with `**Files**: real-file.ts` where file exists still passes (no regression)
- [ ] AC-1.7: Task with `**Files**: missing-file.ts` where file is absent still blocks (no regression)

### US-2: TeammateIdle Has a Safety Valve

**As a** dispatch teammate
**I want** the TeammateIdle hook to allow idle after repeated failed blocks
**So that** I don't loop forever burning tokens when stuck on an uncompletable task

**Acceptance Criteria:**

- [ ] AC-2.1: TeammateIdle blocks up to MAX_IDLE_BLOCKS (default 5) times
- [ ] AC-2.2: On block count >= MAX_IDLE_BLOCKS, teammate is allowed to idle (exit 0)
- [ ] AC-2.3: Safety valve trigger logs a warning to stderr
- [ ] AC-2.4: Block counter resets when dispatch identity changes (dispatchedAt mismatch)
- [ ] AC-2.5: MAX_IDLE_BLOCKS is configurable via `RALPH_MAX_IDLE_BLOCKS` env var
- [ ] AC-2.6: Counter file stored at `/tmp/ralph-idle-{SPEC_NAME}-{TEAMMATE_NAME}`
- [ ] AC-2.7: Counter file format matches dispatch-coordinator.sh pattern: `count:status:dispatchedAt`

### US-3: TeammateIdle Uses Authoritative Completion Source

**As a** dispatch teammate whose group is in completedGroups
**I want** the TeammateIdle hook to check dispatch state before tasks.md
**So that** I can idle when my group is done, even if tasks.md checkboxes are stale

**Acceptance Criteria:**

- [ ] AC-3.1: If teammate's group name is in completedGroups, allow idle immediately (exit 0)
- [ ] AC-3.2: completedGroups check happens BEFORE tasks.md checkbox scan
- [ ] AC-3.3: If completedGroups is absent or empty, falls through to tasks.md check (backward compat)
- [ ] AC-3.4: If dispatch state is unreadable, falls through to tasks.md check (defensive)
- [ ] AC-3.5: When group is NOT in completedGroups and tasks.md shows uncompleted tasks, still blocks (no regression)

### US-4: TaskCompleted Does Not Create Infinite Loops on Idle

**As a** dispatch teammate finishing my turn with in-progress tasks
**I want** TaskCompleted not to spuriously block on sentinel file values
**So that** the "TaskCompleted on idle" trigger doesn't create infinite retry loops

**Acceptance Criteria:**

- [ ] AC-4.1: Solved by US-1 (sentinel fix prevents false-positive blocks)
- [ ] AC-4.2: No additional code changes required beyond Bug 1 fix

### US-5: Cascade Shutdown Deadlock Is Broken

**As a** dispatch lead
**I want** all teammates to eventually shut down gracefully
**So that** dispatches complete without manual intervention or token waste

**Acceptance Criteria:**

- [ ] AC-5.1: Solved by combination of US-1, US-2, US-3
- [ ] AC-5.2: End-to-end scenario: teammate with `Files: none` task can complete and idle within MAX_IDLE_BLOCKS attempts
- [ ] AC-5.3: No teammate loops indefinitely under any combination of bugs

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | Add sentinel check after TASK_FILES extraction in Stage 3 of task-completed-gate.sh. Case-insensitive match for `none`, `n/a`, `n/a *`, `-`, empty. Set TASK_FILES="" to skip file check. | High | AC-1.1 through AC-1.7 |
| FR-2 | Port block counter pattern from dispatch-coordinator.sh to teammate-idle-gate.sh. Counter file at `/tmp/ralph-idle-{SPEC_NAME}-{TEAMMATE_NAME}`. Default MAX_IDLE_BLOCKS=5 via `RALPH_MAX_IDLE_BLOCKS` env var. | High | AC-2.1 through AC-2.7 |
| FR-3 | Add completedGroups check in teammate-idle-gate.sh BEFORE tasks.md loop. Read teammate's group name from dispatch state, check if in completedGroups array. Allow idle if found. | High | AC-3.1 through AC-3.5 |
| FR-4 | Add logging to teammate-idle-gate.sh: block count on each block, safety valve trigger warning, completedGroups bypass notice. | Medium | AC-2.3, visible in stderr during dispatch |
| FR-5 | Reuse `read_block_counter` / `write_block_counter` pattern from dispatch-coordinator.sh (same format: `count:status:dispatchedAt`). Do NOT extract into shared lib -- inline for hook isolation. | Medium | AC-2.7 |

## Test Requirements

| ID | Requirement | Priority | Location |
|----|-------------|----------|----------|
| TR-1 | Add test to test_gate.sh: `**Files**: none` sentinel passes Stage 3 | High | hooks/scripts/test_gate.sh |
| TR-2 | Add test to test_gate.sh: `**Files**: N/A (validation only)` sentinel passes | High | hooks/scripts/test_gate.sh |
| TR-3 | Add test to test_gate.sh: `**Files**: -` sentinel passes | Medium | hooks/scripts/test_gate.sh |
| TR-4 | Create test_teammate_idle_gate.sh with test harness matching test_gate.sh pattern | High | hooks/scripts/test_teammate_idle_gate.sh |
| TR-5 | Test: teammate with all tasks complete allowed to idle | High | test_teammate_idle_gate.sh |
| TR-6 | Test: teammate with uncompleted tasks is blocked | High | test_teammate_idle_gate.sh |
| TR-7 | Test: safety valve triggers after MAX_IDLE_BLOCKS | High | test_teammate_idle_gate.sh |
| TR-8 | Test: block counter resets on dispatchedAt change | Medium | test_teammate_idle_gate.sh |
| TR-9 | Test: completedGroups bypass allows idle even with stale tasks.md | High | test_teammate_idle_gate.sh |
| TR-10 | Test: non-dispatch team (no `-parallel` suffix) allowed to idle | Medium | test_teammate_idle_gate.sh |
| TR-11 | Test: no dispatch state file allows idle | Medium | test_teammate_idle_gate.sh |
| TR-12 | Bash syntax check passes: `bash -n` on both modified scripts | High | CI validation |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | Backward compatibility | Existing test_gate.sh tests | All 7 existing tests pass unchanged |
| NFR-2 | No regressions in other hooks | test_stop_hook.sh, test_session_isolation.sh | All existing tests pass |
| NFR-3 | Hook execution time | teammate-idle-gate.sh wall time | < 1 second (current ~0.1s with jq) |
| NFR-4 | Counter file cleanup | /tmp lifecycle | OS /tmp cleanup handles it (no manual cleanup needed) |
| NFR-5 | No shared library extraction | Hook isolation | Each hook script is self-contained (inline counter functions) |

## Glossary

- **Sentinel value**: A `**Files**:` field value indicating no real files (e.g., `none`, `N/A`, `-`)
- **Safety valve**: A block counter that allows escape after MAX attempts (prevents infinite loops)
- **Block counter**: A file-based counter tracking how many times a hook has blocked (exit 2) for a given dispatch
- **completedGroups**: Array in `.dispatch-state.json` listing group names whose work is done
- **Dispatch identity**: Combination of status + dispatchedAt that uniquely identifies a dispatch run (counter resets on change)
- **Stage 3**: The file existence check stage in task-completed-gate.sh (lines 206-236)
- **Cascade deadlock**: Chain reaction where Bug 1 triggers Bug 4 triggers Bug 2/3, trapping all teammates indefinitely

## Out of Scope

- Extracting shared counter functions into a common library (inline for hook isolation)
- Changing Claude Code's TaskCompleted dual-trigger behavior (by design)
- Modifying dispatch-coordinator.sh (no changes needed, already has safety valve)
- Modifying file-ownership-guard.sh or merge-guard.sh (unrelated)
- Counter file cleanup automation (OS /tmp cleanup is sufficient)
- Changing MAX_IDLE_BLOCKS default from 5 to match Stop hook's 3 (5 is intentionally higher -- teammates should try harder)

## Dependencies

- dispatch-coordinator.sh block counter pattern (reference for porting, no modification)
- jq (already a dependency of both scripts)
- `/tmp` filesystem (already used by dispatch-coordinator.sh counter files)
- Existing test infrastructure: test_gate.sh `run_test()` pattern

## Success Criteria

- All 7 existing test_gate.sh tests pass (no regression)
- New sentinel tests pass in test_gate.sh (TR-1 through TR-3)
- New test_teammate_idle_gate.sh passes all tests (TR-4 through TR-11)
- `bash -n` syntax check passes on both modified scripts
- Full CI: `bash -n task-completed-gate.sh && bash -n teammate-idle-gate.sh && bash test_gate.sh && bash test_teammate_idle_gate.sh`

## Unresolved Questions

- Should the safety valve log to a persistent file (beyond /tmp counter) for post-dispatch audit? Current recommendation: no, stderr logging is sufficient.
- Should completedGroups bypass also skip the safety valve counter increment? Current recommendation: yes, because if the group is done, there's no reason to track blocks.

## Next Steps

1. Review and approve requirements
2. Create design.md with implementation details for each fix
3. Create tasks.md with ordered, verifiable tasks
4. Implement fixes (Bug 1 first, then Bugs 2+3 in parallel)
5. Run full test suite to verify no regressions
