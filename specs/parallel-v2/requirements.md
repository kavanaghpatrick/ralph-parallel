---
spec: parallel-v2
phase: requirements
created: 2026-02-21
generated: auto
---

# Requirements: parallel-v2

## Summary

Fix 11 improvements to ralph-parallel plugin based on lessons from two demo runs. All changes target existing plugin files (markdown commands, bash hooks, skill docs). No application code changes.

## User Stories

### US-1: Reliable task-to-TaskList mapping
As a dispatch lead, I want each spec task to have its own TaskList entry so that the task-completed hook can reliably find the verify command without regex guessing.

**Acceptance Criteria**:
- AC-1.1: dispatch.md Step 7 creates one TaskList task per spec task (not per group)
- AC-1.2: Each TaskList task subject includes the spec task ID (e.g., "1.1: Add auth endpoint")
- AC-1.3: task-completed-gate.sh extracts spec task ID directly from task_subject without regex fallback
- AC-1.4: Teammate prompt references individual TaskList task IDs, not group-level IDs
- AC-1.5: Backward compat: hook still allows through if task ID not found

### US-2: Accurate dispatch state tracking
As a dispatch lead, I want completedGroups updated during execution so that status and merge commands reflect reality.

**Acceptance Criteria**:
- AC-2.1: dispatch.md Step 8 includes explicit instruction to update completedGroups when all tasks in a group are done
- AC-2.2: dispatch-state.json is written with updated completedGroups array

### US-3: Stuck teammate recovery
As a dispatch lead, I want timeout detection for stuck teammates so that I can recover without waiting forever.

**Acceptance Criteria**:
- AC-3.1: dispatch.md Step 8 includes a timeout guideline (e.g., 10 min no message = check)
- AC-3.2: Recovery actions defined: message teammate, reassign task, or shut down and handle manually
- AC-3.3: Stall detection based on TaskList task age (not wall clock)

### US-4: Phase-aware verify tasks
As a dispatch lead, I want verify tasks to include phase metadata so that I know which verify to run when.

**Acceptance Criteria**:
- AC-4.1: verifyTasks in dispatch-state.json changes from `["1.8"]` to `[{"id": "1.8", "phase": 1}]`
- AC-4.2: dispatch.md Step 6 writes the new format
- AC-4.3: status.md and merge.md handle both old (array of strings) and new (array of objects) formats

### US-5: TaskList-based status
As a user, I want /status to check TaskList first so that progress reporting is accurate and real-time.

**Acceptance Criteria**:
- AC-5.1: status.md Step 2 queries TaskList as primary progress source
- AC-5.2: git log used only as secondary/supplementary info
- AC-5.3: Status output shows per-task completion (not just per-group)

### US-6: Clear merge flow documentation
As a user, I want clear docs on when /merge is needed vs not so that I don't run unnecessary commands.

**Acceptance Criteria**:
- AC-6.1: dispatch.md states file-ownership completes in dispatch (no /merge needed)
- AC-6.2: merge.md intro clarifies it's primarily for worktree strategy
- AC-6.3: SKILL.md workflow section updated with clear conditional
- AC-6.4: merge.md file-ownership section reframed as "optional consistency check"

### US-7: Dispatch abort mechanism
As a user, I want to abort a running dispatch so that I can clean up if something goes wrong.

**Acceptance Criteria**:
- AC-7.1: dispatch.md accepts `--abort` flag
- AC-7.2: Abort shuts down active team via SendMessage shutdown_request
- AC-7.3: Abort updates dispatch-state.json status to "aborted"
- AC-7.4: Abort cleans up TaskList entries

### US-8: Defined rebalancing algorithm
As a dispatch lead, I want the partition rebalancing to either work or not be promised.

**Acceptance Criteria**:
- AC-8.1: dispatch.md Step 4 either defines a concrete rebalancing algorithm or removes the claim
- AC-8.2: If defined: algorithm moves tasks with no file conflicts to smaller groups

### US-9: Real-time file ownership enforcement
As a dispatch lead, I want optional file write enforcement so that ownership violations are caught immediately.

**Acceptance Criteria**:
- AC-9.1: New hook guidance added for optional PreToolUse:Write check
- AC-9.2: Hook checks file path against group's ownedFiles list
- AC-9.3: Documented as optional (not enabled by default)

### US-10: Status watch mode
As a user, I want `--watch` mode for status so that I can monitor live progress.

**Acceptance Criteria**:
- AC-10.1: status.md accepts `--watch` flag
- AC-10.2: Watch mode re-runs status check every 30 seconds
- AC-10.3: Clear instruction on how to exit watch mode

### US-11: End-to-end worked example
As a new user, I want a concrete example so that I understand the full dispatch workflow.

**Acceptance Criteria**:
- AC-11.1: Example shows a 3-task spec being dispatched
- AC-11.2: Example covers: partition plan, teammate prompts, completion flow
- AC-11.3: Example included in SKILL.md or a new examples section

## Functional Requirements

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| FR-1 | Create one TaskList task per spec task in dispatch Step 7 | Must | US-1 |
| FR-2 | Simplify task-completed-gate.sh to use direct task_subject parsing | Must | US-1 |
| FR-3 | Update teammate prompt to reference individual task IDs | Must | US-1 |
| FR-4 | Add completedGroups update logic to dispatch Step 8 | Must | US-2 |
| FR-5 | Add timeout detection and recovery to dispatch Step 8 | Must | US-3 |
| FR-6 | Change verifyTasks to array of objects with phase field | Must | US-4 |
| FR-7 | Make status.md query TaskList as primary source | Must | US-5 |
| FR-8 | Clarify file-ownership vs worktree merge docs | Should | US-6 |
| FR-9 | Add --abort flag to dispatch command | Should | US-7 |
| FR-10 | Define or remove partition rebalancing algorithm | Should | US-8 |
| FR-11 | Add optional PreToolUse:Write hook guidance | Could | US-9 |
| FR-12 | Add --watch flag to status command | Could | US-10 |
| FR-13 | Add end-to-end worked example to SKILL.md | Could | US-11 |

## Non-Functional Requirements

| ID | Requirement | Category |
|----|-------------|----------|
| NFR-1 | Backward compat with existing dispatch-state.json files | Compatibility |
| NFR-2 | Hook scripts must complete within 120s timeout | Performance |
| NFR-3 | All changes confined to ralph-parallel/ plugin directory | Scope |

## Out of Scope
- Programmatic Claude API integration (plugin uses natural language prompts)
- New commands beyond dispatch/status/merge
- Worktree strategy implementation (Phase 2, already documented)
- Application-level code changes

## Dependencies
- Existing ralph-parallel plugin at v0.1.0
- jq available for bash hook JSON parsing
- Claude Code Agent Teams feature (TeamCreate, Task, SendMessage tools)
