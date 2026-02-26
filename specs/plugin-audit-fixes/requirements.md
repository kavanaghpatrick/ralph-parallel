---
spec: plugin-audit-fixes
phase: requirements
created: 2026-02-26T14:30:00Z
---

# Requirements: Plugin Audit Fixes

## Goal

Fix 17 confirmed bugs (6 CRITICAL, 11 HIGH) from the comprehensive ralph-parallel plugin audit. Covers Python code fixes, shell script hardening, dispatch documentation corrections, and prompt text updates -- with regression tests for all code-level changes.

## User Decisions

| Question | Decision |
|----------|----------|
| Issue #13 (TaskCreate vs Task naming) | NOT a bug -- skip entirely |
| Quality Commands format (#2) | Bold markdown (`- **Build**: \`cmd\``) as canonical; support both formats for backward compat |
| Partition file path (#5) | Explicit save to `/tmp/$specName-partition.json` |
| Stall detection recovery (#14) | Re-spawn stalled teammate, not "reassign to self" |
| Priority tradeoffs | Code quality and maintainability over speed |
| Success criteria | All 17 fixes landed, regression tests for code fixes, existing tests still pass |

## User Stories

### US-1: Correct Task Ordering for Large Specs

**As a** plugin user dispatching specs with 10+ tasks per phase
**I want** task IDs to sort numerically (1.1, 1.2, ... 1.10, 1.11)
**So that** dependency ordering and VERIFY checkpoints work correctly

**Acceptance Criteria:**
- [ ] AC-1.1: `_task_id_key("1.10")` returns `(1, 10)`, not lexicographic order
- [ ] AC-1.2: VERIFY dependency builder at lines 440/445 uses numeric comparison
- [ ] AC-1.3: Both `.sort()` calls at lines 611/628 use numeric key
- [ ] AC-1.4: Regression test: 12 tasks (1.1 through 1.12) with VERIFY -- correct ordering confirmed

### US-2: Reliable Quality Command Parsing

**As a** plugin user with tasks.md in bold markdown format
**I want** `parse_quality_commands_from_tasks()` to parse my Quality Commands section
**So that** dispatch uses correct build/test/lint commands instead of auto-discovered fallbacks

**Acceptance Criteria:**
- [ ] AC-2.1: Bold markdown format (`- **Build**: \`cmd\``) parsed correctly
- [ ] AC-2.2: Code-fenced format still supported (backward compat)
- [ ] AC-2.3: Bare dash format (`- Build: cmd`) parsed as fallback
- [ ] AC-2.4: Regression test: all three formats produce correct slot/command mappings
- [ ] AC-2.5: `N/A` values correctly excluded from commands

### US-3: Session Environment Propagation

**As a** plugin hook relying on `CLAUDE_SESSION_ID`
**I want** the env file to use `export` keyword
**So that** session ID propagates to subprocess environments

**Acceptance Criteria:**
- [ ] AC-3.1: `session-setup.sh` writes `export CLAUDE_SESSION_ID=...` (not bare assignment)
- [ ] AC-3.2: Existing test T-10 updated to verify `export` keyword presence

### US-4: Accurate Dispatch Plan Display

**As a** user running `/dispatch --strategy worktree`
**I want** Step 3 to include `--strategy $strategy`
**So that** the displayed plan matches the actual partition strategy

**Acceptance Criteria:**
- [ ] AC-4.1: `dispatch.md` Step 3 command includes `--strategy $strategy` flag

### US-5: Working Partition File Pipeline

**As a** dispatch coordinator running Step 6 (teammate prompt generation)
**I want** the partition JSON saved to a known path
**So that** `build-teammate-prompt.py --partition-file` can read it

**Acceptance Criteria:**
- [ ] AC-5.1: dispatch.md includes explicit save step: partition JSON to `/tmp/$specName-partition.json`
- [ ] AC-5.2: Step 6 `--partition-file` reference matches the save path

### US-6: Multi-Phase Dispatch Support

**As a** user dispatching specs with 3+ phases
**I want** coordination loop to iterate over ALL phases
**So that** serial tasks and verify checkpoints run after every phase, not just Phase 2

**Acceptance Criteria:**
- [ ] AC-6.1: "Phase 2" hardcoding removed from Step 7 items 5 and 6
- [ ] AC-6.2: Replaced with dynamic references ("last parallel phase", "final phase's verify")

### US-7: Robust Worktree Strategy Edge Case

**As a** user with a spec where all remaining tasks are VERIFY
**I want** `_build_groups_worktree` to handle empty parallel_tasks gracefully
**So that** no ZeroDivisionError or misleading error message occurs

**Acceptance Criteria:**
- [ ] AC-7.1: Guard clause returns `([], [])` for empty parallel_tasks
- [ ] AC-7.2: Regression test: all-VERIFY task list does not crash

### US-8: Correct File Ownership After Rebalancing

**As a** dispatch coordinator using automatic partitioning
**I want** rebalancing to preserve file ownership for remaining tasks
**So that** the file-ownership-guard hook doesn't block legitimate writes

**Acceptance Criteria:**
- [ ] AC-8.1: After moving a task, `ownedFiles` for source group recomputed from remaining tasks
- [ ] AC-8.2: Regression test: overlapping files, rebalancing triggered, ownership verified

### US-9: Correct Commit Provenance Convention

**As a** teammate following commit conventions
**I want** clear instructions to append trailers manually (not `git commit -s`)
**So that** `verify-commit-provenance.py` recognizes my commits

**Acceptance Criteria:**
- [ ] AC-9.1: `build-teammate-prompt.py` no longer recommends `git commit -s`
- [ ] AC-9.2: Prompt explicitly says "Do NOT use `git commit -s`"

### US-10: Isolated Verify Command Execution

**As a** dispatch coordinator running verify commands
**I want** each `eval` to execute in a subshell
**So that** directory changes in one verify command don't affect subsequent stages

**Acceptance Criteria:**
- [ ] AC-10.1: `task-completed-gate.sh` wraps verify `eval` in subshell or pushd/popd
- [ ] AC-10.2: Subsequent stages (typecheck, build, test, lint) execute from PROJECT_ROOT regardless of verify cmd side effects

### US-11: Safe Parameter Expansion

**As a** plugin running on projects with special characters in paths
**I want** `$PROJECT_ROOT` properly quoted in parameter expansion
**So that** glob characters in paths don't cause expansion bugs

**Acceptance Criteria:**
- [ ] AC-11.1: `file-ownership-guard.sh:82` uses `"$PROJECT_ROOT"` in parameter expansion

### US-12: Consistent PROJECT_ROOT Across All Hooks

**As a** teammate whose CWD may be a project subdirectory
**I want** all hooks to derive PROJECT_ROOT from `git rev-parse --show-toplevel`
**So that** spec directory lookups succeed regardless of CWD

**Acceptance Criteria:**
- [ ] AC-12.1: `file-ownership-guard.sh`, `task-completed-gate.sh`, `dispatch-coordinator.sh` all use `git rev-parse --show-toplevel` as primary
- [ ] AC-12.2: CWD used only as fallback when not in a git repo

### US-13: Correct Stall Recovery

**As a** dispatch coordinator handling a stalled teammate
**I want** instructions to re-spawn (not "reassign to self")
**So that** parallel execution model is preserved per critical rules

**Acceptance Criteria:**
- [ ] AC-13.1: "reassign tasks to self" removed from Step 7.3c
- [ ] AC-13.2: Replaced with "re-spawn stalled teammate with remaining tasks"

### US-14: Complete Allowed-Tools List

**As a** dispatch coordinator needing to send messages and manage teams
**I want** `SendMessage`, `TeamCreate`, `TeamDelete` in allowed-tools
**So that** teammate communication and lifecycle management work

**Acceptance Criteria:**
- [ ] AC-14.1: `dispatch.md` allowed-tools includes `SendMessage`
- [ ] AC-14.2: `TeamCreate` and `TeamDelete` also added

### US-15: Accurate Step References in Templates

**As a** plugin maintainer reading template documentation
**I want** step number references to match dispatch.md
**So that** cross-referencing is accurate

**Acceptance Criteria:**
- [ ] AC-15.1: `team-prompt.md` "Step 8" corrected to "Step 7"
- [ ] AC-15.2: `teammate-prompt.md` step references corrected (Step 7->6, Step 7->5)

### US-16: Task Writeback After Compaction

**As a** dispatch coordinator whose context was compacted
**I want** the stop hook re-injection to include mark-tasks-complete reminder
**So that** tasks.md checkboxes get updated before dispatch closes

**Acceptance Criteria:**
- [ ] AC-16.1: `dispatch-coordinator.sh` re-injection prompt includes mark-tasks-complete step

### US-17: Stale Dispatch Handling in Status/Merge

**As a** user checking status or merging a dispatch that became stale
**I want** clear messaging about stale state and recovery options
**So that** I don't get confusing errors or proceed incorrectly

**Acceptance Criteria:**
- [ ] AC-17.1: `status.md` handles "stale" status with notice, reason, and staleSince
- [ ] AC-17.2: `merge.md` handles "stale" status with re-dispatch/abort guidance

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria | Issue |
|----|-------------|----------|---------------------|-------|
| FR-1 | Add `_task_id_key()` helper for numeric ID comparison in parse-and-partition.py | CRITICAL | AC-1.1 through AC-1.4 | #1 |
| FR-2 | Rewrite `parse_quality_commands_from_tasks()` to parse bold markdown as primary format, keep code-fence as fallback | CRITICAL | AC-2.1 through AC-2.5 | #2 |
| FR-3 | Add `export` keyword to CLAUDE_SESSION_ID write in session-setup.sh | CRITICAL | AC-3.1, AC-3.2 | #3 |
| FR-4 | Add `--strategy $strategy` to dispatch.md Step 3 command | CRITICAL | AC-4.1 | #4 |
| FR-5 | Add partition JSON save step to dispatch.md after Step 2 | CRITICAL | AC-5.1, AC-5.2 | #5 |
| FR-6 | Replace "Phase 2" hardcoding with dynamic phase references in dispatch.md Step 7 | CRITICAL | AC-6.1, AC-6.2 | #6 |
| FR-7 | Guard `_build_groups_worktree` against empty parallel_tasks | HIGH | AC-7.1, AC-7.2 | #7 |
| FR-8 | Fix rebalance to recompute ownedFiles from remaining tasks | HIGH | AC-8.1, AC-8.2 | #8 |
| FR-9 | Remove `git commit -s` advice from build-teammate-prompt.py | HIGH | AC-9.1, AC-9.2 | #9 |
| FR-10 | Wrap eval commands in subshell in task-completed-gate.sh | HIGH | AC-10.1, AC-10.2 | #10 |
| FR-11 | Quote `$PROJECT_ROOT` in file-ownership-guard.sh parameter expansion | HIGH | AC-11.1 | #11 |
| FR-12 | Standardize PROJECT_ROOT derivation to `git rev-parse --show-toplevel` in 3 hooks | HIGH | AC-12.1, AC-12.2 | #12 |
| FR-13 | Replace "reassign to self" with "re-spawn stalled teammate" in dispatch.md | HIGH | AC-13.1, AC-13.2 | #14 |
| FR-14 | Add SendMessage, TeamCreate, TeamDelete to dispatch.md allowed-tools | HIGH | AC-14.1, AC-14.2 | #15 |
| FR-15 | Fix step number references in team-prompt.md and teammate-prompt.md | HIGH | AC-15.1, AC-15.2 | #16 |
| FR-16 | Add mark-tasks-complete to stop hook re-injection prompt | HIGH | AC-16.1 | #17 |
| FR-17 | Add stale dispatch handling to status.md and merge.md | HIGH | AC-17.1, AC-17.2 | #18 |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | Regression tests for all Python code fixes (#1, #2, #7, #8) | Test count | At least 1 new test per fix |
| NFR-2 | All existing tests pass after changes | Test suite pass rate | 100% |
| NFR-3 | Shell script fixes (#10, #12) have test coverage | Test verification | Manual or scripted verification |
| NFR-4 | No behavioral change for specs with <10 tasks | Backward compatibility | Existing dispatch results unchanged |
| NFR-5 | Bold markdown + code-fence QC formats both work | Format coverage | Both parsed correctly in tests |

## Glossary

- **Task ID**: Dot-separated identifier like `1.3` or `2.7` (phase.sequence)
- **Quality Commands (QC)**: Section in tasks.md defining build/test/lint commands for a spec
- **VERIFY task**: A checkpoint task that validates work from preceding tasks before moving to next phase
- **Partition**: Division of tasks into parallel groups for teammate assignment
- **Rebalancing**: Moving tasks between groups to equalize workload after initial partitioning
- **ownedFiles**: Set of file paths a group is allowed to write (enforced by file-ownership-guard hook)
- **Stop hook re-injection**: When context is compacted, dispatch-coordinator.sh re-injects coordination instructions
- **Stale dispatch**: A dispatch whose team was lost (e.g., session timeout) but wasn't completed
- **Bold markdown format**: `- **Build**: \`cmd\`` -- canonical QC format from task-planner
- **Code-fenced format**: QC commands inside triple-backtick blocks -- legacy format

## Out of Scope

- Architectural changes to the plugin (all fixes are surgical)
- Adding new features or capabilities
- Changing the tasks.md format specification (only fixing parsers to match existing spec)
- Worktree strategy Phase 2 implementation
- End-to-end dispatch integration tests (unit/regression tests only)
- Issue #13 (TaskCreate vs Task naming) -- confirmed NOT a bug

## Dependencies

- Existing test infrastructure: `test_parse_and_partition.py`, `test_build_teammate_prompt.py`, `test_mark_tasks_complete.py`, `test_verify_commit_provenance.py`
- `test_session_isolation.sh` for shell hook testing
- All fixes are to files within `ralph-parallel/` (no external dependencies)

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| QC format change (#2) breaks existing specs | Low | Medium | Support both formats; test with real tasks.md files |
| Rebalance fix (#8) changes partition output | Low | Low | Regression test with known input/output |
| PROJECT_ROOT change (#12) in non-git environments | Low | Medium | Keep CWD as fallback when git rev-parse fails |
| Stop hook text changes (#17) cause compaction issues | Very Low | Low | Keep re-injection text concise |

## Success Criteria

- All 17 issues fixed (skip #13)
- Regression tests added for FR-1, FR-2, FR-7, FR-8 (Python code fixes)
- All existing tests pass: `python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py`
- No behavioral regression for specs with <10 tasks per phase

## Unresolved Questions

- Should `eval` isolation (#10) use subshell `()` or pushd/popd? Subshell is safer (isolates all env changes), pushd/popd is simpler to debug. Recommend subshell.
- Should PROJECT_ROOT standardization (#12) also update session-setup.sh for consistency, even though it already uses the correct approach? Recommend: no change needed, it's already correct.

## Next Steps

1. Approve these requirements
2. Generate tasks.md with fix groups organized by file (minimizes merge conflicts)
3. Dispatch implementation -- Python fixes + tests as one group, shell fixes as another, documentation fixes as a third
