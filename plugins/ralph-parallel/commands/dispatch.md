---
description: Analyze spec tasks and dispatch to Agent Teams for parallel execution
argument-hint: [spec-name] [--max-teammates 4] [--strategy file-ownership|worktree] [--dry-run] [--abort]
allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]
---

# Dispatch

Orchestrates parallel spec execution via Agent Teams. Scripts handle parsing and partitioning; this command handles team creation and coordination.

## Parse Arguments

From `$ARGUMENTS`, extract:
- **spec-name**: Optional spec name (defaults to active spec from `.current-spec`)
- **--max-teammates N**: Maximum number of teammates to spawn (default: 4, max: 8)
- **--strategy**: Isolation strategy - `file-ownership` (default) or `worktree`
- **--dry-run**: Show partition plan without creating team
- **--abort**: Cancel active dispatch, shut down teammates, clean up state
- **--reclaim**: Reclaim coordinator ownership for this session

If `--abort`: skip to Abort Handler section below.
If `--reclaim`: skip to Reclaim Handler section below.

## Step 1: Resolve Spec

```text
1. If spec-name provided: look for specs/$spec-name/tasks.md
2. If no spec-name: read specs/.current-spec
3. Validate tasks.md exists
4. Read .ralph-state.json — warn if not in execution/tasks phase
```

## Step 1.5: Validate Task Format (via script)

Before partitioning, validate that tasks.md is in the expected format:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/validate-tasks-format.py \
  --tasks-md specs/$specName/tasks.md \
  --check-verify-commands \
  --require-quality-commands
```

**Exit codes**:
- 0: Valid — continue to Step 2
- 1: File not found or empty — "Run /ralph-specum:tasks to generate task list first."
- 2: Format errors — display the diagnostic output to the user. The script reports exact line numbers and fix suggestions. Do NOT proceed to Step 2. Common causes:
  - `## Task N:` headers instead of `- [ ] X.Y` checkboxes
  - Verify commands that match build/typecheck but not test (proves compilation, not correctness)
- 3: Valid with warnings — display warnings, then continue to Step 2. Common warnings:
  - Missing `## Quality Commands` section (older specs won't have it — not blocking)
  - No test command declared (baseline snapshot will be skipped)
  - Tasks missing **Files**/**Verify**/**Do** fields

**Note on --check-verify-commands**: This flag compares each task's Verify command against the project's declared Quality Commands. When the Quality Commands section is missing, the verify check is safely skipped (cannot compare without declared commands). This is by design — `--require-quality-commands` handles the missing section as a warning.

## Step 2: Analyze and Partition (via script)

Run the analysis script — it handles task parsing, dependency graphs, and partitioning:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/parse-and-partition.py \
  --tasks-md specs/$specName/tasks.md \
  --max-teammates $maxTeammates \
  --strategy $strategy
```

**Exit codes**:
- 0: Success — JSON partition on stdout. Save to a variable.
- 1: tasks.md format error → Display stderr diagnostics (parse-and-partition.py now reports specific format issues with line numbers and fix suggestions). Do NOT just say "Run /ralph-specum:tasks" — the diagnostics will indicate the actual problem.
- 2: All complete → "All tasks complete. Nothing to dispatch."
- 3: Single task → "Only 1 task remaining. Run /ralph-specum:implement instead."
- 4: Circular deps → Offer the user a choice:
  - **Option A**: Re-run with `--strategy worktree` (each teammate gets isolated branch, requires /merge after)
  - **Option B**: Serialize the overlapping tasks (run them sequentially, not in parallel)
  - If the user chooses worktree: re-run parse-and-partition.py with `--strategy worktree`, then update $strategy to "worktree" and continue from Step 3. The dispatch-state.json MUST reflect the actual strategy used.

## Step 3: Display Partition Plan

Run with `--format` flag to get human-readable output:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/parse-and-partition.py \
  --tasks-md specs/$specName/tasks.md \
  --max-teammates $maxTeammates \
  --format
```

Display the output to the user. If `--dry-run`: STOP here.

## Step 4: Write Dispatch State

```text
1. Check specs/$specName/.dispatch-state.json:
   - If status "dispatched": warn, set to "superseded"
   - If status "stale": OK (team was lost), overwrite
   - If status "merging": error, run /ralph-parallel:merge --abort first
   - If "merged"/"superseded"/"aborted": OK, overwrite

2. Write dispatch state from the partition JSON:
   {
     "dispatchedAt": "<ISO timestamp>",
     "coordinatorSessionId": "$CLAUDE_SESSION_ID",
     "strategy": "$strategy",
     "maxTeammates": $maxTeammates,
     "groups": <from partition JSON>,
     "serialTasks": <from partition JSON>,
     "verifyTasks": <from partition JSON>,
     "qualityCommands": <from partition JSON>,
     "baselineSnapshot": null,
     "status": "dispatched",
     "completedGroups": []
   }

   Read `$CLAUDE_SESSION_ID` from the environment. If empty or unset, write `"coordinatorSessionId": null` and output a warning: "Warning: CLAUDE_SESSION_ID not available — session isolation disabled for this dispatch. Auto-reclaim on next SessionStart will fix this."
```

## Step 4.5: Capture Baseline Test Snapshot (via script)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/capture-baseline.sh \
  --dispatch-state specs/$specName/.dispatch-state.json
```

The script reads `qualityCommands.test` from dispatch-state.json, runs it, parses the test count, and updates dispatch-state.json with a `baselineSnapshot` field. It handles all edge cases (no test command, failing tests, unparseable output) and never blocks dispatch.

If the script reports pre-existing test failures, warn the user but continue.

## Step 5: Create Team and TaskList

<mandatory>
You MUST create one TaskCreate call for EVERY individual spec task in the partition JSON.
Do NOT summarize multiple tasks into a single TaskList item. The total number of TaskCreate
calls must equal the total number of tasks across ALL groups plus verify tasks.
</mandatory>

```text
1. TeamCreate: name "$specName-parallel"

2. For EVERY task in EVERY group in the partition JSON, call TaskCreate:

   FOR each group in partition.groups:
     FOR each task in group.taskDetails:
       TaskCreate:
         subject: "{task.id}: {task.description}"
         description: task.rawBlock
         activeForm: "Implementing {task.id}"

   ALSO for each verify task in partition.verifyTasks:
     TaskCreate:
       subject: "{verifyTask.id}: {verifyTask.description}"
       description: verifyTask.rawBlock
       activeForm: "Running {verifyTask.id} verify"
       blockedBy: [IDs of all same-phase tasks]

   Phase 2+ tasks: set blockedBy to include the preceding phase's verify task ID.

3. Record the TaskList ID → spec task ID mapping for use in Step 6.
```

**Example**: If partition has 2 groups with 3 tasks each + 2 verify tasks = 8 TaskCreate calls:
```
TaskCreate: "1.1: Add types header"       → TaskList #1
TaskCreate: "1.2: Implement allocator"     → TaskList #2
TaskCreate: "1.3: Wire dispatch table"     → TaskList #3
TaskCreate: "1.4: [VERIFY] Phase 1"        → TaskList #4 (blockedBy: #1, #2, #3)
TaskCreate: "2.1: Add error handling"      → TaskList #5 (blockedBy: #4)
TaskCreate: "2.2: Add fallback paths"      → TaskList #6 (blockedBy: #4)
TaskCreate: "2.3: Integration tests"       → TaskList #7 (blockedBy: #4)
TaskCreate: "2.4: [VERIFY] Phase 2"        → TaskList #8 (blockedBy: #5, #6, #7)
```

Do NOT create summary tasks like "Phase 2: all remaining work" — each spec task gets its own entry.

## Step 6: Spawn Teammates

For each group in the partition, generate a prompt and spawn:

Extract `QUALITY_COMMANDS_JSON` from the partition JSON's `qualityCommands` field (as a JSON string).

Extract `BASELINE_TEST_COUNT` from dispatch-state.json's `baselineSnapshot.testCount` field (default 0 if missing or null):

```bash
BASELINE_TEST_COUNT=$(jq -r '.baselineSnapshot.testCount // 0' specs/$specName/.dispatch-state.json 2>/dev/null || echo 0)
```

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build-teammate-prompt.py \
  --partition-file /tmp/$specName-partition.json \
  --group-index $i \
  --spec-name $specName \
  --project-root $projectRoot \
  --task-ids "#$id1,#$id2,..." \
  --quality-commands "$QUALITY_COMMANDS_JSON" \
  --baseline-test-count $BASELINE_TEST_COUNT \
  --strategy $strategy
```

Spawn via Task tool with the script's stdout as the prompt:
- subagent_type: "general-purpose"
- name: group name from partition JSON
- team_name: "$specName-parallel"
- mode: bypassPermissions
- run_in_background: true
- **isolation parameter**: Read `strategy` from dispatch-state.json:
  - If `"file-ownership"`: **DO NOT** set `isolation: "worktree"`. All teammates work in the same project root directory. Worktree isolation would create divergent branches that never get merged.
  - If `"worktree"`: **DO** set `isolation: "worktree"`. Each teammate gets an isolated git worktree branch. Requires `/ralph-parallel:merge` after all agents complete.

Spawn ALL non-blocked groups simultaneously (parallel Task calls).

## Step 7: Lead Coordination Loop

```text
1. MONITOR: Wait for teammate messages. Idle after sending is normal.

2. TRACK COMPLETION: When a group finishes:
   a. Add group name to completedGroups in .dispatch-state.json
   b. Write updated state

3. STALL DETECTION: No message for 10+ minutes?
   a. Send status check message
   b. Wait 5 more minutes
   c. If still no response: reassign tasks to self or serialize

4. PHASE GATE: When ALL Phase N tasks done:
   a. Run Phase N verify checkpoint task
   b. Read qualityCommands from .dispatch-state.json
   c. Run qualityCommands.build (if available)
   d. Run qualityCommands.test (if available)
   e. Run qualityCommands.lint (if available)
   f. If build/test/lint FAIL: message affected teammates with error output.
      Do NOT mark phase complete. Teammates must fix.
   g. If all pass: mark verify task completed, message Phase N+1 teammates: "Proceed"

5. SERIAL TASKS: After Phase 2, execute serial tasks yourself

6. FINAL VERIFY: Run Phase 2 verify checkpoint

7. CLEANUP:
   a. Mark completed tasks in tasks.md:
      `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/mark-tasks-complete.py --dispatch-state specs/$specName/.dispatch-state.json --tasks-md specs/$specName/tasks.md`
   b. Shut down teammates (SendMessage shutdown_request)
   c. File-ownership: set status = "merged" (no /merge needed)
   d. Worktree: leave as "dispatched" (needs /merge)
   e. TeamDelete
   f. "ALL_PARALLEL_COMPLETE — $totalTasks tasks done."
```

The dispatch-coordinator.sh Stop hook will re-inject this context if compaction occurs.

## Abort Handler

When `--abort` flag is present:

```text
1. Read .dispatch-state.json — error if missing or status not in ("dispatched", "stale")
2. Read ~/.claude/teams/$specName-parallel/config.json for teammates
3. SendMessage shutdown_request to each teammate (30s timeout)
4. TeamDelete
5. Set status = "aborted", abortedAt = ISO timestamp
6. Output abort summary
```

## Reclaim Handler

When `--reclaim` flag is present:

```text
1. Resolve spec (same as Step 1)
2. Read specs/$specName/.dispatch-state.json
   - If missing: "No dispatch state found for '$specName'."
   - If status != "dispatched": "No active dispatch to reclaim (status: $status)."
3. Read $CLAUDE_SESSION_ID env var
   - If empty: "Session ID unavailable. Restart Claude to get a fresh session ID."
4. Update via jq:
   jq --arg sid "$CLAUDE_SESSION_ID" '.coordinatorSessionId = $sid' "$stateFile" > tmp && mv tmp "$stateFile"
5. Output: "Reclaimed dispatch for '$specName' -- this session is now coordinator."
```

<mandatory>
## CRITICAL: Delegation Rules

Analysis is done by scripts (parse-and-partition.py, build-teammate-prompt.py).
Orchestration is done by this command using TeamCreate and Task tools.

Do NOT:
- Generate a prompt for the user to copy-paste (NEVER)
- Manually parse tasks.md or compute partitions (scripts do this)
- Execute spec tasks yourself during dispatch (teammates do that)
- Skip the partition display (user must see the plan)

Do:
- Run scripts via Bash tool for analysis
- Use TeamCreate to create the team
- Use Task tool to spawn teammates with script-generated prompts
- Coordinate the execution loop as lead
- Save dispatch state for tracking
</mandatory>

## Error Handling

**validate-tasks-format.py** (Step 1.5):

| Exit Code | Action |
|-----------|--------|
| 0 | Valid — continue to Step 2 |
| 1 | File not found / empty — "Run /ralph-specum:tasks to generate task list first." |
| 2 | Format errors — show diagnostics, do NOT proceed. Ask user to fix tasks.md |
| 3 | Valid with warnings — show warnings, continue to Step 2 |

**parse-and-partition.py** (Step 2):

| Exit Code | Action |
|-----------|--------|
| 0 | Success — JSON partition on stdout |
| 1 | Format error — show stderr diagnostics (line numbers and fixes) |
| 2 | "All tasks already complete. Nothing to dispatch." |
| 3 | "Only 1 task remaining. Run /ralph-specum:implement instead." |
| 4 | "Circular file dependencies. Consider serializing or splitting files." |

| General Error | Action |
|---------------|--------|
| Script not found | "Plugin scripts missing. Reinstall ralph-parallel." |

## Worktree Strategy (Phase 2)

When `--strategy worktree`:
- Each teammate gets its own git worktree branch
- All files available (no ownership restrictions)
- Partition by logical grouping, not file overlap
- Requires /ralph-parallel:merge after completion

```text
Setup: git config gc.auto 0 && git worktree add .worktrees/$groupName -b parallel/$specName/$groupName
Merge: /ralph-parallel:merge integrates branches, resolves conflicts, restores gc.auto
```
