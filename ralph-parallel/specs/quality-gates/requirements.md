---
spec: quality-gates
phase: requirements
created: 2026-02-22
generated: auto
---

# Requirements: quality-gates

## Summary

Strengthen verify command generation in the task-planner agent and add baseline test snapshot capture at dispatch time to enable test count regression detection during parallel execution.

## User Stories

### US-1: Enforce test-runner verify commands

As a spec author, I want the task-planner to require actual test runner commands (not compile-only checks) in Verify fields, so that task verification proves correctness rather than just compilability.

**Acceptance Criteria**:
- AC-1.1: task-planner.md contains explicit anti-pattern list banning `cargo check`, `tsc --noEmit`, `go build` as standalone verify commands
- AC-1.2: task-planner.md mandates test runner commands (`cargo test`, `pnpm test`, `pytest`, etc.) for feature tasks
- AC-1.3: task-planner.md requires a `## Quality Commands` section at the top of generated tasks.md
- AC-1.4: Explore agent spawning is marked MANDATORY (not advisory) before task generation

### US-2: Capture baseline test snapshot at dispatch

As a dispatch coordinator, I want to capture the passing test count before spawning teammates, so that test count regressions can be detected during execution.

**Acceptance Criteria**:
- AC-2.1: dispatch.md contains Step 4.5 that runs the test command and captures baseline count
- AC-2.2: `dispatch-state.json` stores `baselineSnapshot: { testCount, capturedAt, command, rawOutput }`
- AC-2.3: Edge cases handled: no test command (skip), pre-existing failures (store -1), unparseable output (store -1)

### US-3: Baseline comparison in quality gate

As a quality gate, I want to compare current test count against the baseline to detect test deletion or count regression during teammate execution.

**Acceptance Criteria**:
- AC-3.1: Stage 5 in task-completed-gate.sh reads `baselineSnapshot.testCount` from dispatch-state.json
- AC-3.2: If current test count drops below baseline by >10%, exit 2 with regression warning
- AC-3.3: If baseline is -1 or missing, fall back to current pass/fail behavior (no regression check)
- AC-3.4: Test count parsing uses multi-runner regex cascade (jest, pytest, cargo test, go test, generic)

## Functional Requirements

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| FR-1 | Add anti-pattern list to task-planner.md banning compile-only verify commands | Must | US-1 |
| FR-2 | Make Explore spawning mandatory in task-planner.md | Must | US-1 |
| FR-3 | Require `## Quality Commands` section in generated tasks.md | Must | US-1 |
| FR-4 | Add Step 4.5 to dispatch.md for baseline test capture | Must | US-2 |
| FR-5 | Store baselineSnapshot in dispatch-state.json schema | Must | US-2 |
| FR-6 | Enhance Stage 5 with baseline comparison logic | Must | US-3 |
| FR-7 | Implement multi-runner test count parser function | Must | US-3 |
| FR-8 | Update build-teammate-prompt.py quality section with baseline info | Should | US-2 |

## Non-Functional Requirements

| ID | Requirement | Category |
|----|-------------|----------|
| NFR-1 | Baseline capture must not add >30s to dispatch startup | Performance |
| NFR-2 | Test count parsing must handle unknown runners gracefully (return -1) | Robustness |
| NFR-3 | All bash changes must pass `bash -n` syntax check | Quality |

## Out of Scope

- Rewriting the full task-planner agent
- Adding a test suite for the plugin itself
- Worktree strategy modifications
- Changes to parse-and-partition.py
- Changes to validate-tasks-format.py

## Dependencies

- ralph-specum plugin at `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/`
- ralph-parallel plugin at `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/`
