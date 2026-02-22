---
spec: quality-gates-v2
phase: requirements
created: 2026-02-22
generated: auto
---

# Requirements: quality-gates-v2

## Summary

Fix 3 audit issues from v6 dispatch: lint not blocking at quality gates, tasks.md completion marks not written back, worktree commit provenance unclear. All fixes must be deterministic scripts, ecosystem-agnostic.

## User Stories

### US-1: Lint enforcement at task completion gate
As a dispatch lead, I want lint errors to block task completion so that clippy/eslint/ruff violations are caught before declaring tasks done.

**Acceptance Criteria**:
- AC-1.1: task-completed-gate.sh runs `qualityCommands.lint` (from dispatch-state.json) as a periodic stage
- AC-1.2: Lint failures produce exit code 2 with last 30 lines of output on stderr
- AC-1.3: Missing lint command (null/empty) is a no-op -- does not block
- AC-1.4: Lint runs at same periodic interval as build (every N tasks, configurable via LINT_INTERVAL env var)

### US-2: Automatic tasks.md completion writeback
As a dispatch lead, I want tasks.md checkboxes automatically updated from dispatch state so that post-dispatch the file reflects actual completion.

**Acceptance Criteria**:
- AC-2.1: New Python script reads completedGroups from dispatch-state.json
- AC-2.2: Maps group task IDs to tasks.md checkbox lines and marks them `[x]`
- AC-2.3: Only marks tasks whose groups are in completedGroups (handles partial completion)
- AC-2.4: dispatch.md CLEANUP step calls this script
- AC-2.5: Idempotent -- running twice produces same result

### US-3: Worktree commit provenance
As a merge reviewer, I want to know which agent made each commit so that post-merge audit is possible.

**Acceptance Criteria**:
- AC-3.1: build-teammate-prompt.py injects commit convention with agent name trailer
- AC-3.2: Commit messages include `Signed-off-by: <group-name>` git trailer
- AC-3.3: New verification script can audit commits for provenance tags
- AC-3.4: Works for both file-ownership and worktree strategies

## Functional Requirements

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| FR-1 | Add lint stage to task-completed-gate.sh reading from qualityCommands.lint | Must | US-1 |
| FR-2 | Lint stage runs periodically (configurable interval, default 3) | Must | US-1 |
| FR-3 | Create mark-tasks-complete.py script | Must | US-2 |
| FR-4 | Script reads dispatch-state.json completedGroups and partition groups | Must | US-2 |
| FR-5 | Script updates tasks.md `- [ ]` to `- [x]` for completed group tasks | Must | US-2 |
| FR-6 | dispatch.md CLEANUP invokes mark-tasks-complete.py | Must | US-2 |
| FR-7 | build-teammate-prompt.py adds commit trailer convention to prompt | Must | US-3 |
| FR-8 | Create verify-commit-provenance.py script | Should | US-3 |
| FR-9 | Phase gate in dispatch.md runs lint alongside build/test | Should | US-1 |

## Non-Functional Requirements

| ID | Requirement | Category |
|----|-------------|----------|
| NFR-1 | All scripts must be ecosystem-agnostic (read commands from qualityCommands) | Portability |
| NFR-2 | No new external dependencies beyond jq, python3, git | Simplicity |
| NFR-3 | Backward compatible -- existing dispatches without lint command must not break | Compatibility |
| NFR-4 | Scripts must exit 0 on missing/null commands (graceful no-op) | Robustness |

## Out of Scope

- Refactoring existing stages 1-5 in task-completed-gate.sh
- Adding new hooks (all fixes go into existing hook or standalone scripts)
- Worktree merge conflict resolution improvements
- UI/dashboard for dispatch status

## Dependencies

- Existing task-completed-gate.sh (Stage 1-5 pattern)
- Existing build-teammate-prompt.py (prompt generation)
- Existing dispatch-state.json schema (completedGroups, qualityCommands, groups)
