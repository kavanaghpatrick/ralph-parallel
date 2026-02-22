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

If `--abort`: skip to Abort Handler section below.

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
  --tasks-md specs/$specName/tasks.md
```

**Exit codes**:
- 0: Valid — continue to Step 2
- 1: File not found or empty — "Run /ralph-specum:tasks to generate task list first."
- 2: Format errors — display the diagnostic output to the user. The script reports exact line numbers and fix suggestions. Do NOT proceed to Step 2.
- 3: Valid with warnings — display warnings, then continue to Step 2

**On exit code 2**: The most common cause is the task-planner generating `## Task N:` headers instead of `- [ ] X.Y` checkboxes. The script will detect this and suggest the fix. Show the user the full diagnostic output and ask if they want to fix tasks.md before proceeding.

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
- 4: Circular deps → "Unresolvable circular file dependencies."

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
   - If status "merging": error, run /ralph-parallel:merge --abort first
   - If "merged"/"superseded"/"aborted": OK, overwrite

2. Write dispatch state from the partition JSON:
   {
     "dispatchedAt": "<ISO timestamp>",
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
```

## Step 4.5: Capture Baseline Test Snapshot

Before spawning teammates, capture the current test state for regression detection:

```text
1. Read qualityCommands.test from the dispatch-state.json just written
2. If no test command (empty/null): skip — leave baselineSnapshot as null
3. If test command exists:
   a. Run the test command from project root, capture stdout+stderr
   b. Record the exit code
   c. Parse test count from output using this regex cascade:
      - Jest/Vitest: /Tests:\s+(\d+) passed/ or /(\d+) passed/
      - Pytest: /(\d+) passed/
      - Cargo test: /test result:.*(\d+) passed/
      - Go test: count lines matching /^ok\s+/
      - Generic fallback: count lines containing "pass", "ok", or "✓"
   d. If test command FAILS (exit != 0):
      - WARN user: "⚠ Baseline tests failing — teammates will inherit broken tests"
      - Set testCount to -1 (signals pre-existing failure)
      - Continue dispatch (do NOT block)
   e. If output is unparseable (no count extracted):
      - Set testCount to -1
      - Log: "Could not parse test count from output"
   f. Update dispatch-state.json:
      "baselineSnapshot": {
        "testCount": N,
        "capturedAt": "<ISO timestamp>",
        "command": "<test command>",
        "exitCode": N
      }
```

## Step 5: Create Team and TaskList

```text
1. TeamCreate: name "$specName-parallel"

2. Create one TaskList task per spec task (1:1 mapping):
   - Subject: "X.Y: description" (spec task ID MUST start the subject)
   - Description: full task block from partition JSON's taskDetails.rawBlock
   - blockedBy: [VERIFY] tasks blocked by all preceding same-phase tasks,
     Phase 2 tasks blocked by Phase 1 verify task
```

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
  --baseline-test-count $BASELINE_TEST_COUNT
```

Spawn via Task tool with the script's stdout as the prompt:
- subagent_type: "general-purpose"
- name: group name from partition JSON
- team_name: "$specName-parallel"
- mode: bypassPermissions
- run_in_background: true

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
   e. If build/test FAIL: message affected teammates with error output.
      Do NOT mark phase complete. Teammates must fix.
   f. If all pass: mark verify task completed, message Phase N+1 teammates: "Proceed"

5. SERIAL TASKS: After Phase 2, execute serial tasks yourself

6. FINAL VERIFY: Run Phase 2 verify checkpoint

7. CLEANUP:
   a. Shut down teammates (SendMessage shutdown_request)
   b. File-ownership: set status = "merged" (no /merge needed)
   c. Worktree: leave as "dispatched" (needs /merge)
   d. TeamDelete
   e. "ALL_PARALLEL_COMPLETE — $totalTasks tasks done."
```

The dispatch-coordinator.sh Stop hook will re-inject this context if compaction occurs.

## Abort Handler

When `--abort` flag is present:

```text
1. Read .dispatch-state.json — error if missing or status != "dispatched"
2. Read ~/.claude/teams/$specName-parallel/config.json for teammates
3. SendMessage shutdown_request to each teammate (30s timeout)
4. TeamDelete
5. Set status = "aborted", abortedAt = ISO timestamp
6. Output abort summary
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

| Error | Action |
|-------|--------|
| Validate exit 2 | Format errors detected — show diagnostics, ask user to fix tasks.md |
| Partition exit 1 | Format error — show stderr diagnostics (specific line numbers and fixes) |
| Partition exit 2 | "All tasks already complete. Nothing to dispatch." |
| Partition exit 3 | "Only 1 task remaining. Run /ralph-specum:implement instead." |
| Partition exit 4 | "Circular file dependencies. Consider serializing or splitting files." |
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
