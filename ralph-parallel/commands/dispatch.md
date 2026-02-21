---
description: Analyze spec tasks and dispatch to Agent Teams for parallel execution
argument-hint: [spec-name] [--max-teammates 4] [--strategy file-ownership|worktree] [--dry-run] [--abort]
allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]
---

# Dispatch

Analyzes a ralph-specum spec's tasks.md, partitions tasks into parallelizable groups based on file ownership, and orchestrates parallel execution via Agent Teams.

## Parse Arguments

From `$ARGUMENTS`, extract:
- **spec-name**: Optional spec name (defaults to active spec from `.current-spec`)
- **--max-teammates N**: Maximum number of teammates to spawn (default: 4, max: 8)
- **--strategy**: Isolation strategy - `file-ownership` (default) or `worktree`
- **--dry-run**: Show partition plan without creating team
- **--abort**: Cancel active dispatch, shut down teammates, clean up state

## Step 1: Resolve Spec

```text
1. If spec-name provided:
   - Look for specs/$spec-name/tasks.md
   - Error if not found: "Spec '$spec-name' not found. Run /ralph-specum:status to see specs."

2. If no spec-name:
   - Read specs/.current-spec to get active spec
   - If no active spec: Error "No active spec. Provide spec name or run /ralph-specum:start first."

3. Validate tasks.md exists at resolved path
   - Error if missing: "No tasks.md found. Run /ralph-specum:tasks to generate task list."

4. Read .ralph-state.json if it exists
   - Check phase == "execution" or phase == "tasks"
   - Warn if phase is earlier: "Spec is still in $phase phase. Consider completing spec phases first."
```

## Step 2: Parse Tasks

Read tasks.md and extract all incomplete tasks (lines matching `- [ ]`).

```text
Task Parsing:

1. Read entire tasks.md content
2. For each task block (starts with "- [ ] X.Y"):
   - Extract task ID (X.Y format)
   - Extract task description
   - Extract **Files** list (paths that will be modified)
   - Extract **Do** steps
   - Extract **Verify** command
   - Extract **Commit** message
   - Extract markers: [P] parallel, [VERIFY] verification
   - Store as structured task object

3. Skip completed tasks (- [x])
4. Count remaining incomplete tasks
5. If zero incomplete: "All tasks complete. Nothing to dispatch."
```

### Task Object Structure

```json
{
  "id": "1.3",
  "description": "Add error handling",
  "files": ["src/handler.ts", "src/utils.ts"],
  "doSteps": ["Step 1...", "Step 2..."],
  "verify": "npm test",
  "commit": "feat: add error handling",
  "markers": ["P"],
  "phase": 1,
  "dependencies": []
}
```

## Step 3: Build Dependency Graph

Analyze task relationships by file overlap and phase ordering.

```text
Dependency Analysis:

1. FILE OVERLAP DETECTION:
   For each pair of tasks (A, B) where A.id < B.id:
   - Compute intersection of A.files and B.files
   - If intersection is non-empty:
     - B depends on A (lower-numbered task goes first)
     - Record: B.dependencies.push(A.id)
     - Record: conflictingFiles[A.id + ":" + B.id] = intersection

2. PHASE ORDERING:
   Tasks are numbered X.Y where X = phase.
   - All tasks in phase N must complete before phase N+1 starts
   - Within a phase, tasks with no file overlap can run in parallel

3. [VERIFY] TASKS:
   - [VERIFY] tasks are always sequential barriers
   - They depend on ALL tasks before them in the same phase
   - All tasks after them in the same phase depend on them

4. EXPLICIT [P] MARKERS:
   - Tasks marked [P] in tasks.md are pre-analyzed as parallel-safe
   - Still validate via file overlap (markers may be wrong)
   - If [P] tasks have file overlap, warn and serialize them
```

## Step 4: Partition Tasks into Groups

Assign tasks to teammate groups based on file ownership.

```text
Partitioning Algorithm:

1. INITIALIZE:
   - groups = [] (up to maxTeammates groups)
   - fileOwnership = {} (maps file path -> group index)

2. SORT tasks by phase (ascending), then by ID within phase

3. FOR EACH task (in order):
   a. Check if task has unresolved dependencies
      - If yes: defer to later (must wait for dependency group)

   b. Check task's files against fileOwnership map
      - If ALL files unowned: assign to least-loaded group, claim files
      - If ALL files owned by SAME group: assign to that group
      - If files split across groups: CONFLICT
        - Option 1: Assign to group owning majority of files
        - Option 2: Create dependency edge (task waits for prior group)
        - Choose option that minimizes total wait time

   c. Update fileOwnership for newly claimed files

4. BALANCE CHECK:
   a. Compute maxTasks = max task count across groups
   b. Compute minTasks = min task count across groups
   c. While maxTasks > 2 * minTasks:
      i.   Pick the LAST task in the largest group
      ii.  Check if its files conflict with the smallest group's ownedFiles
      iii. If NO conflict: move task to smallest group, update fileOwnership
      iv.  If conflict: skip this task, try previous task in largest group
      v.   If no movable tasks found: stop (file constraints prevent balance)
      vi.  Recompute maxTasks, minTasks
   d. Goal: roughly equal work per teammate

5. OUTPUT: Array of groups, each with:
   - groupIndex (0-based)
   - tasks: [task objects]
   - ownedFiles: [file paths]
   - dependencies: [other group indices that must complete first]
```

### Partition Result

```json
{
  "specName": "user-auth",
  "strategy": "file-ownership",
  "totalTasks": 12,
  "groups": [
    {
      "index": 0,
      "name": "api-layer",
      "tasks": ["1.1", "1.2", "1.4"],
      "ownedFiles": ["src/api/auth.ts", "src/api/middleware.ts"],
      "dependencies": []
    },
    {
      "index": 1,
      "name": "ui-components",
      "tasks": ["1.3", "1.5", "1.6"],
      "ownedFiles": ["src/components/Login.tsx", "src/components/Register.tsx"],
      "dependencies": []
    },
    {
      "index": 2,
      "name": "data-layer",
      "tasks": ["2.1", "2.2"],
      "ownedFiles": ["src/models/User.ts", "src/db/migrations/"],
      "dependencies": [0]
    }
  ],
  "serialTasks": ["1.7", "2.3"],
  "verifyTasks": [{"id": "1.8", "phase": 1}, {"id": "2.4", "phase": 2}]
}
```

## Step 5: Display Partition Plan

Show the user what will be dispatched.

```text
Output Format:

Dispatch Plan for '$specName'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Strategy: file-ownership
Teams: $groupCount teammates + 1 lead

Group 1: api-layer (3 tasks)
  Tasks: 1.1, 1.2, 1.4
  Files: src/api/auth.ts, src/api/middleware.ts
  Deps: none

Group 2: ui-components (3 tasks)
  Tasks: 1.3, 1.5, 1.6
  Files: src/components/Login.tsx, src/components/Register.tsx
  Deps: none

Group 3: data-layer (2 tasks)
  Tasks: 2.1, 2.2
  Files: src/models/User.ts, src/db/migrations/
  Deps: Group 1 must complete first

Serial tasks (lead handles): 1.7, 2.3
Verify checkpoints: 1.8, 2.4

Estimated speedup: ~2.5x (12 tasks across 3 parallel groups)
```

If `--dry-run` flag present, STOP here. Do not generate team prompt.

## Step 6: Clean Up Stale State and Write Dispatch State

Before creating a new dispatch, handle any existing dispatch state.

```text
Stale State Cleanup:

1. Check if specs/$specName/.dispatch-state.json already exists
2. If it exists:
   a. Read current status
   b. If "dispatched": Warn user "Previous dispatch found (from $dispatchedAt).
      Marking as superseded." Set status to "superseded".
   c. If "merging": Error "Merge in progress. Run /ralph-parallel:merge --abort first."
   d. If "merged" or "superseded": OK, overwrite.
3. Write NEW dispatch state:

Write specs/$specName/.dispatch-state.json:
{
  "dispatchedAt": "<ISO timestamp>",
  "strategy": "file-ownership",
  "maxTeammates": 4,
  "groups": [<partition result>],
  "serialTasks": ["1.7", "2.3"],
  "verifyTasks": [{"id": "1.8", "phase": 1}, {"id": "2.4", "phase": 2}],
  "status": "dispatched",
  "completedGroups": []
}
```

## Step 7: Create Team and Spawn Teammates

Directly orchestrate parallel execution using Agent Teams.

```text
Team Creation (direct orchestration):

1. Use TeamCreate to create team named "$specName-parallel"
   - description: "Parallel execution of $specName spec"

2. Create one TaskList task per spec task (1:1 mapping):
   - Subject format: "X.Y: task description" (spec task ID MUST be first)
   - Description: include the full task block from tasks.md
   - Set blockedBy dependencies:
     - [VERIFY] checkpoint tasks are blockedBy ALL preceding tasks in same phase
     - Serial tasks are blockedBy the verify checkpoint task
     - Phase 2 tasks are blockedBy the Phase 1 verify checkpoint task
   - This 1:1 mapping ensures the TaskCompleted hook can extract the spec
     task ID directly from the task subject for per-task verification.

3. Spawn teammates using Task tool (one per group, IN PARALLEL):
   For each group, spawn with subagent_type="general-purpose":
   - name: group name (e.g., "data-models")
   - team_name: "$specName-parallel"
   - mode: bypassPermissions
   - run_in_background: true
   - prompt: Build inline from the group's task data (see Teammate Prompt below)
   - Include the list of TaskList task IDs assigned to this teammate

4. Spawn ALL non-blocked teammates simultaneously.
   For groups with Phase 2 tasks: instruct teammate to complete Phase 1
   tasks first, then message lead and wait for Phase 1 verify before
   proceeding to Phase 2 tasks.
```

### Teammate Prompt Construction

For each teammate, construct the prompt inline (no template needed):

```text
You are the "$groupName" teammate for the $specName spec parallel execution.

## Your Tasks
You have $N individual TaskList tasks to complete. Claim each one via
TaskUpdate (set owner to your name, status to in_progress) as you start it,
and mark it completed when done.

Your TaskList task IDs: #$id1, #$id2, ...

Execute these spec tasks IN ORDER:

[For each task in group, include full task block from tasks.md:
  ### Task X.Y: description (TaskList #$taskId)
  - Files: ...
  - Do: ...
  - Done when: ...
  - Verify: ...
  - Commit: ...
]

[If group has Phase 2 tasks, add:]
NOTE: Task X.Y is Phase 2. After completing Phase 1 tasks, STOP and
message the lead: "Phase 1 $groupName tasks complete, awaiting verify."
Wait for the lead to confirm before proceeding.

## File Ownership — STRICTLY ENFORCED
You ONLY modify these files: [ownedFiles list]
You may read other files but NEVER write outside your ownership list.
Before writing ANY file, verify it is in your ownership list above.
If you need changes to a file you don't own, message the lead —
do NOT make the change yourself. Ownership violations will be
detected during merge verification and may require rework.

## Rules
- For each task: implement → verify → commit → mark [x] in specs/$specName/tasks.md
- Claim each TaskList task as you start it, complete it when done
- After ALL tasks done, message the lead:
  "Group $groupName complete. All N tasks verified."
- Working directory: $projectRoot
```

## Step 8: Lead Coordination Loop

After spawning teammates, the lead coordinates the execution.

```text
Lead Coordination:

1. MONITOR: Wait for teammate messages reporting completion.
   - Teammates go idle after sending messages — this is normal.
   - Track which groups have completed Phase 1 tasks.

2. TRACK GROUP COMPLETION: When a teammate reports all their tasks are done,
   or when TaskList shows all tasks owned by a group are completed:
   a. Add group name to completedGroups array in .dispatch-state.json
   b. Write updated state file to specs/$specName/.dispatch-state.json
   c. Log: "Group $groupName marked complete ($completedCount/$totalGroups)"

3. STALL DETECTION: While waiting for teammate messages:
   a. If no message from a teammate for 10+ minutes, send them a status
      check message: "Status check — are you blocked? Report progress."
   b. Wait 5 more minutes for response.
   c. If still no response, mark teammate as stalled:
      - Options: (1) Reassign remaining tasks to self or another teammate,
        (2) Shut down stalled teammate and serialize their tasks,
        (3) Message user for guidance
      - Log stall event: update .dispatch-state.json with
        stalledTeammates: [{name, stalledAt, remainingTasks}]
   d. Prefer option (1) if lead has capacity; otherwise use (2).

4. PHASE GATE: When ALL Phase 1 group tasks are done:
   a. Find the Phase 1 [VERIFY] checkpoint from verifyTasks
      (the one with phase: 1 in verifyTasks array)
   b. Run its verify command yourself (e.g., npm test && npm run typecheck)
   c. Mark the verify TaskList entry as completed
   d. Message teammates with Phase 2 tasks: "Phase 1 verified. Proceed."
   e. Phase 2 TaskList entries auto-unblock via blockedBy dependencies.

5. SERIAL TASKS: After all parallel Phase 2 tasks complete:
   a. Execute serial tasks yourself (these span file ownership boundaries)
   b. For each: implement → verify → commit → mark [x] in tasks.md

6. FINAL VERIFY: Run final [VERIFY] checkpoint (phase: 2 verify task).

7. CLEANUP:
   a. Shut down remaining idle teammates via SendMessage shutdown_request
   b. For file-ownership strategy: update dispatch-state.json status = "merged"
      (dispatch handles the full lifecycle — no /merge step needed)
   c. For worktree strategy: leave status as "dispatched"
      (requires /ralph-parallel:merge for branch integration)
   d. Delete team via TeamDelete
   e. Output: "ALL_PARALLEL_COMPLETE — $totalTasks tasks done."
```

## Abort Handler

When `--abort` flag is present, cancel the active dispatch:

```text
Abort Steps:

1. Read specs/$specName/.dispatch-state.json
   - Error if missing: "No active dispatch found for '$specName'."
   - Error if status != "dispatched": "Dispatch is '$status', not active."

2. Read team config ~/.claude/teams/$specName-parallel/config.json
   - Extract list of active teammates from members array

3. For each teammate: send shutdown_request via SendMessage
   - Wait up to 30 seconds for shutdown confirmations

4. Delete team via TeamDelete

5. Update .dispatch-state.json:
   - status = "aborted"
   - abortedAt = ISO timestamp

6. Output:
   "Dispatch aborted for '$specName'.
    Teammates shut down: $count
    State: aborted (dispatch-state.json updated)
    To re-dispatch: /ralph-parallel:dispatch $specName"
```

<mandatory>
## CRITICAL: Delegation Rules

This command does ALL analysis itself (no subagent needed for task parsing/partitioning).
Dispatch creates and orchestrates Agent Teams DIRECTLY using TeamCreate and Task tools.

Do NOT:
- Generate a prompt for the user to copy-paste (NEVER)
- Modify tasks.md during analysis (read-only until execution)
- Execute spec tasks yourself during dispatch (teammates do that)
- Skip the partition display (user must see the plan)

Do:
- Read and analyze tasks.md thoroughly
- Detect file conflicts and dependencies accurately
- Use TeamCreate to create the team
- Use Task tool to spawn teammates with inline prompts
- Coordinate the execution loop as lead (verify checkpoints, serial tasks)
- Save dispatch state for tracking
- Clean up stale dispatch states before creating new ones
</mandatory>

## Error Handling

| Error | Action |
|-------|--------|
| No tasks.md | "Run /ralph-specum:tasks to generate task list first." |
| All tasks complete | "All tasks already complete. Nothing to dispatch." |
| Single task remaining | "Only 1 task remaining — no parallelism benefit. Run /ralph-specum:implement instead." |
| File conflicts unresolvable | "Tasks have circular file dependencies. Consider serializing phases or splitting files." |
| Too few tasks for teammates | Reduce teammate count to match available parallel groups |

## Worktree Strategy (Phase 2)

When `--strategy worktree` is specified:

```text
Worktree Strategy Differences:

1. Each teammate gets its own git worktree instead of file ownership
2. All files are available to all teammates (no ownership restrictions)
3. Partition by logical grouping rather than file overlap
4. Each worktree gets its own branch: parallel/$specName/$groupName

Setup:
- git config gc.auto 0  (MANDATORY: prevent object deletion)
- git worktree add .worktrees/$groupName -b parallel/$specName/$groupName

Teammate instructions include:
- Work ONLY in assigned worktree directory
- Commit and push to worktree branch
- Do NOT modify files outside worktree

Merge (after completion):
- Integration branch: merge all worktree branches
- Conflict resolution via /ralph-parallel:merge
- Cleanup: git worktree remove .worktrees/$groupName
- Restore: git config gc.auto 1
```

Note: Worktree strategy requires merge step. File-ownership strategy avoids this complexity.
