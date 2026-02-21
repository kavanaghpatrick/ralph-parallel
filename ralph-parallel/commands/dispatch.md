---
description: Analyze spec tasks and dispatch to Agent Teams for parallel execution
argument-hint: [spec-name] [--max-teammates 4] [--strategy file-ownership|worktree] [--dry-run]
allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]
---

# Dispatch

Analyzes a ralph-specum spec's tasks.md, partitions tasks into parallelizable groups based on file ownership, and generates an Agent Teams creation prompt for simultaneous execution.

## Parse Arguments

From `$ARGUMENTS`, extract:
- **spec-name**: Optional spec name (defaults to active spec from `.current-spec`)
- **--max-teammates N**: Maximum number of teammates to spawn (default: 4, max: 8)
- **--strategy**: Isolation strategy - `file-ownership` (default) or `worktree`
- **--dry-run**: Show partition plan without creating team

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
   - If any group has > 2x tasks of smallest group:
     - Try to redistribute non-conflicting tasks
   - Goal: roughly equal work per teammate

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
  "verifyTasks": ["1.8", "2.4"]
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

## Step 6: Generate Team Creation Prompt

Build the natural-language prompt that creates the Agent Team.

```text
Team Prompt Generation:

1. Read team prompt template from:
   ${CLAUDE_PLUGIN_ROOT}/templates/team-prompt.md

2. Read teammate prompt template from:
   ${CLAUDE_PLUGIN_ROOT}/templates/teammate-prompt.md

3. For each group, populate teammate template with:
   - Group name
   - Task list (full task blocks from tasks.md)
   - Owned files list
   - Dependencies on other groups
   - Verify commands

4. Assemble full team prompt:
   - Lead instructions (coordination, quality gates)
   - Per-teammate spawn instructions
   - Completion criteria
```

### Write Dispatch State

Save dispatch state for status tracking and merge:

```text
Write specs/$specName/.dispatch-state.json:
{
  "dispatchedAt": "<ISO timestamp>",
  "strategy": "file-ownership",
  "maxTeammates": 4,
  "groups": [<partition result>],
  "serialTasks": ["1.7", "2.3"],
  "verifyTasks": ["1.8", "2.4"],
  "status": "dispatched",
  "completedGroups": []
}
```

## Step 7: Output Team Creation Prompt

Display the generated prompt for the user to paste into a new Claude Code session with Agent Teams enabled.

```text
Output:

Team prompt generated! To start parallel execution:

1. Open a NEW Claude Code session
2. Paste the following prompt:

━━━ COPY BELOW THIS LINE ━━━

[Generated team prompt content]

━━━ COPY ABOVE THIS LINE ━━━

3. The lead will spawn teammates and coordinate execution
4. Run /ralph-parallel:status to monitor progress
5. When complete, run /ralph-parallel:merge to integrate results
```

<mandatory>
## CRITICAL: Delegation Rules

This command does ALL analysis itself (no subagent needed for task parsing/partitioning).
The output is a PROMPT, not programmatic team creation — Agent Teams are created via natural language.

Do NOT:
- Try to programmatically create Agent Teams (there is no API)
- Modify tasks.md (read-only analysis)
- Execute any tasks (that's what the team does)
- Skip the partition display (user must see and approve)

Do:
- Read and analyze tasks.md thoroughly
- Detect file conflicts and dependencies accurately
- Generate clear, actionable teammate prompts
- Save dispatch state for tracking
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
