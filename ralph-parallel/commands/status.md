---
description: Show parallel dispatch status and team progress
argument-hint: [spec-name] [--json]
allowed-tools: [Read, Bash, Glob, Grep, TaskList, TaskGet]
---

# Status

Shows the current state of parallel dispatch — which groups are active, task completion per group, and overall progress.

## Parse Arguments

From `$ARGUMENTS`, extract:
- **spec-name**: Optional spec name (defaults to active spec)
- **--json**: Output raw JSON instead of formatted display
- **--watch**: Continuously poll and refresh status every 30 seconds

## Step 1: Resolve Spec and Load State

```text
1. Resolve spec (same logic as dispatch.md Step 1)
2. Read specs/$specName/.dispatch-state.json
   - If missing: "No parallel dispatch active for '$specName'.
     Run /ralph-parallel:dispatch to start parallel execution."
3. Read specs/$specName/tasks.md for current task states
4. Read specs/$specName/.ralph-state.json if exists
5. Read coordinatorSessionId from dispatch state
6. Compare against $CLAUDE_SESSION_ID env var:
   - Both present + match: isCoordinator = true, display "Coordinator: this session"
   - Both present + mismatch: isCoordinator = false, display "Coordinator: different session"
   - coordinatorSessionId missing/null: isCoordinator = null, display "Coordinator: unknown (legacy)"
   - $CLAUDE_SESSION_ID empty: isCoordinator = null, display "Coordinator: unknown (env unavailable)"
7. If status is "stale": Display stale notice:
   "Dispatch STALE for '$specName' (reason: $staleReason, since: $staleSince)."
   "Run /ralph-parallel:dispatch to re-dispatch, or /ralph-parallel:dispatch --abort to cancel."
   Include staleSince, staleReason from dispatch state. Skip Steps 2-3 (no live team to query).
```

## Step 2: Compute Progress

```text
Primary source: TaskList (most reliable, real-time status)
Secondary source: tasks.md checkboxes, git log (fallback/supplementary)

1. QUERY TASKLIST: Use TaskList to get all tasks.
   - Group tasks by owner (teammate name = group name)
   - For each task, check status: pending, in_progress, completed
   - Count completed vs total per group

2. CROSS-CHECK with tasks.md:
   - Read tasks.md, match each group's spec task IDs
   - Count [x] vs [ ] for group's tasks
   - If TaskList and tasks.md disagree, prefer TaskList

3. DETECT ACTIVE WORK (secondary signal):
   - Check git log for recent commits matching group's files
   - This is supplementary — use for "Current activity" display line

4. CHECK DEPENDENCIES:
   - Are blocking groups complete (via completedGroups in dispatch state)?
   - Is this group unblocked and ready?

5. HANDLE VERIFY TASKS:
   - verifyTasks may be objects {id, phase} or strings (legacy)
   - For objects: extract id field for display
   - For strings: use directly
```

## Step 3: Display Status

```text
Output Format:

Parallel Status: $specName
━━━━━━━━━━━━━━━━━━━━━━━━━━

Strategy: $strategy | Dispatched: $timestamp
Coordinator: this session | different session | unknown (legacy)
Overall: $completedTasks/$totalTasks tasks ($percentage%)

Group 1: api-layer
  Status: COMPLETE
  Tasks: 3/3 [████████████] 100%
  Files: src/api/auth.ts, src/api/middleware.ts

Group 2: ui-components
  Status: IN PROGRESS
  Tasks: 1/3 [████░░░░░░░░] 33%
  Files: src/components/Login.tsx, src/components/Register.tsx
  Current: 1.5 Add form validation

Group 3: data-layer
  Status: BLOCKED (waiting on Group 1)
  Tasks: 0/2 [░░░░░░░░░░░░] 0%
  Files: src/models/User.ts, src/db/migrations/
  Blocked by: api-layer

Serial: 0/2 (pending team completion)
Verify: 0/2 (pending)

Next steps:
  - Groups still running: wait for Agent Teams to complete
  - All groups done (file-ownership): dispatch completes automatically
  - All groups done (worktree): run /ralph-parallel:merge
```

## Watch Mode

When `--watch` flag is present:

```text
1. Run normal status display (Steps 1-3)
2. Wait 30 seconds
3. Re-query TaskList and tasks.md for updated status
4. Clear previous output and display updated status
5. Repeat until:
   - All tasks are completed → "All tasks complete. Watch mode ended."
   - Dispatch status changes to "merged" or "aborted" → stop
   - User interrupts
```

## JSON Output

When `--json` flag present, output the raw dispatch state merged with live progress:

```json
{
  "specName": "user-auth",
  "strategy": "file-ownership",
  "dispatchedAt": "2026-02-21T15:30:00Z",
  "overallProgress": {
    "completed": 4,
    "total": 12,
    "percentage": 33
  },
  "groups": [
    {
      "name": "api-layer",
      "status": "complete",
      "tasksCompleted": 3,
      "tasksTotal": 3,
      "tasks": ["1.1", "1.2", "1.4"]
    }
  ],
  "serialTasks": { "completed": 0, "total": 2 },
  "verifyTasks": { "completed": 0, "total": 2 },
  "coordinatorSessionId": "<value or null>",
  "isCoordinator": true | false | null
}
```
