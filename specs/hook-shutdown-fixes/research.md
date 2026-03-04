---
spec: hook-shutdown-fixes
phase: research
created: 2026-03-04T22:30:00Z
---

# Research: hook-shutdown-fixes

## Executive Summary

Five interacting bugs in ralph-parallel hooks create a cascade shutdown deadlock where neither teammates nor the lead can shut down gracefully. The root cause chain: `**Files**: none` is parsed as a literal filename (Bug 1) causing TaskCompleted to block -> TaskCompleted also fires when teammates idle with in-progress tasks (Bug 4) creating retry loops -> TeammateIdle has no safety valve (Bug 2) and checks stale tasks.md instead of dispatch state (Bug 3) -> nobody can escape (Bug 5). All fixes are localized to two scripts (task-completed-gate.sh and teammate-idle-gate.sh) with no architectural changes needed.

## External Research

### Claude Code Hook Behavior (Official Docs)

Key findings from https://code.claude.com/docs/en/hooks:

| Hook | When It Fires | Exit 2 Effect |
|------|---------------|---------------|
| TaskCompleted | "when any agent explicitly marks a task as completed through TaskUpdate, **OR when a teammate finishes its turn with in-progress tasks**" | Prevents task from being marked completed; stderr fed back as feedback |
| TeammateIdle | "when a teammate is about to go idle after finishing its turn" | Prevents teammate from going idle; teammate continues working |
| Stop | "when the main Claude Code agent has finished responding" | Prevents Claude from stopping; continues conversation |

Critical detail from docs: **TaskCompleted fires in TWO situations**, not just explicit TaskUpdate. The second trigger -- "teammate finishes its turn with in-progress tasks" -- is the amplifier for Bug 4. When a teammate tries to go idle with uncompleted tasks, TaskCompleted fires for those tasks, and if the hook blocks (exit 2), the teammate is forced to keep working on a task it cannot complete.

Decision control patterns:

| Hook | Decision Method |
|------|----------------|
| TaskCompleted | Exit code only (exit 2 blocks, stderr = feedback) |
| TeammateIdle | Exit code only (exit 2 blocks, stderr = feedback) |
| Stop | JSON `{"decision":"block","reason":"..."}` on stdout + exit 0 |

The docs explicitly warn: "Check `stop_hook_active` value or process the transcript to prevent Claude Code from running indefinitely."

### Agent Teams Shutdown Sequence

From https://code.claude.com/docs/en/agent-teams:

- "Shutdown can be slow: teammates finish their current request or tool call before shutting down"
- Lead sends shutdown request via `SendMessage shutdown_request`; teammate can approve or reject
- "Always use the lead to clean up"
- No mention of any built-in safety valve for hooks that repeatedly block
- Known limitation: "Task status can lag: teammates sometimes fail to mark tasks as completed, which blocks dependent tasks"

### Best Practices

- Hooks should be idempotent and fast (timeout defaults: 600s command, 30s prompt, 60s agent)
- Exit code 2 for blocking, exit 0 for allowing
- "Any other exit code" is a non-blocking error (stderr shown in verbose mode, execution continues)
- No built-in max-block mechanism for TeammateIdle or TaskCompleted -- the hook author must implement their own

## Codebase Analysis

### Bug 1: "Files: none" Parsing (task-completed-gate.sh, Stage 3, lines 206-236)

**Exact problematic code** (lines 207-236):

```bash
# --- Stage 3: File existence check ---
TASK_FILES=""
IN_TASK=false
while IFS= read -r fline; do
  if echo "$fline" | grep -qE "^\s*- \[.\] ${COMPLETED_SPEC_TASK}\b"; then
    IN_TASK=true; continue
  fi
  if [ "$IN_TASK" = true ] && echo "$fline" | grep -qE "^\s*- \[.\] [0-9]"; then break; fi
  if [ "$IN_TASK" = true ] && echo "$fline" | grep -qE "\*\*Files\*\*:"; then
    TASK_FILES=$(echo "$fline" | sed 's/.*\*\*Files\*\*:[[:space:]]*//' | sed 's/`//g' | sed 's/ *(NEW)//g; s/ *(MODIFY)//g; s/ *(CREATE)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    break
  fi
done < "$SPEC_DIR/tasks.md"

if [ -n "$TASK_FILES" ]; then        # <-- "none" is non-empty, enters block
  MISSING=""
  IFS=',' read -ra FILE_LIST <<< "$TASK_FILES"
  for f in "${FILE_LIST[@]}"; do
    f=$(echo "$f" | xargs)  # trim whitespace
    [ -z "$f" ] && continue
    if [ ! -e "$PROJECT_ROOT/$f" ]; then  # <-- checks for $PROJECT_ROOT/none
      MISSING="$MISSING $f"               # <-- adds "none" to MISSING
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "SUPPLEMENTAL CHECK FAILED: file existence" >&2
    echo "Missing files:$MISSING" >&2       # <-- "Missing files: none"
    echo "Create the missing files before marking task complete." >&2
    exit 2                                   # <-- BLOCKS task completion
  fi
fi
```

**Confirmed sentinel values in real tasks.md files** (grep across project):

| File | Value |
|------|-------|
| `specs/api-dashboard/tasks.md` | `**Files**: none` |
| `specs/parallel-fixes/tasks.md` (x3) | `**Files**: none` |
| `specs/user-auth/tasks.md` (x2) | `**Files**: none` |
| `specs/quality-gates-v2/tasks.md` | `**Files**: N/A (validation only)` |
| `ralph-parallel/specs/quality-gates/tasks.md` | `**Files**: N/A (validation only)` |

Sentinel patterns to handle: `none`, `n/a`, `N/A`, `-`, and any value starting with `N/A` (to catch `N/A (validation only)`).

**Fix approach**: After line 215 extracts `TASK_FILES`, add a sentinel check:

```bash
# Skip file check for sentinel values
case "$(echo "$TASK_FILES" | tr '[:upper:]' '[:lower:]')" in
  none|n/a|n/a\ *|-|"") TASK_FILES="" ;;
esac
```

This normalizes to lowercase and catches all observed patterns. Setting `TASK_FILES=""` makes the `if [ -n "$TASK_FILES" ]` guard on line 220 skip the entire file check block.

### Bug 2: No TeammateIdle Safety Valve (teammate-idle-gate.sh)

**Full script** (66 lines): The script has NO block counter, NO max-blocks check, and NO escape mechanism.

```bash
# Block idle — re-engage teammate  (lines 62-65)
echo "Continue working. You have uncompleted tasks:" >&2
echo -e "$UNCOMPLETED" >&2
echo "Claim the next uncompleted task, implement it, and mark it complete." >&2
exit 2
```

Compare with dispatch-coordinator.sh safety valve pattern:

```bash
# dispatch-coordinator.sh, lines 113, 258-264
MAX_BLOCKS="${RALPH_MAX_STOP_BLOCKS:-3}"
...
BLOCK_COUNT=$(read_block_counter "$COUNTER_FILE" "$STATUS" "$DISPATCHED_AT")
if [ "$BLOCK_COUNT" -ge "$MAX_BLOCKS" ] 2>/dev/null; then
  # Safety valve: allow stop after MAX_BLOCKS
  exit 0
fi
```

The Stop hook has a block counter file at `/tmp/ralph-stop-${SPEC_NAME}-${SESSION_ID}` with format `count:status:dispatchedAt`. It resets when dispatch identity changes and allows escape after `MAX_BLOCKS` (default 3).

**Fix approach**: Port the block counter pattern from dispatch-coordinator.sh to teammate-idle-gate.sh:

1. Add counter file: `/tmp/ralph-idle-${SPEC_NAME}-${TEAMMATE_NAME}`
2. Add `MAX_IDLE_BLOCKS` env var (default: 5 -- higher than Stop's 3 because teammates should try harder)
3. Read/increment/write counter on each block
4. Reset counter when dispatch identity changes (dispatchedAt mismatch)
5. When counter >= MAX_IDLE_BLOCKS, exit 0 (allow idle) and log a warning

### Bug 3: TeammateIdle Checks tasks.md Instead of TaskList (teammate-idle-gate.sh, lines 47-55)

**Problematic code**:

```bash
UNCOMPLETED=""
for TASK_ID in $GROUP_TASKS; do
  # Check if task line has [ ] (uncompleted) vs [x] (completed)
  if grep -qE "^\s*- \[ \] ${TASK_ID}\b" "$TASKS_MD"; then
    DESC=$(grep -oE "^\s*- \[ \] ${TASK_ID}\s+.*" "$TASKS_MD" | sed "s/.*${TASK_ID}\s*//" | head -1)
    UNCOMPLETED="${UNCOMPLETED}  - ${TASK_ID}: ${DESC}\n"
  fi
done
```

The hook checks tasks.md checkboxes (`[ ]` vs `[x]`), but tasks.md may be stale:
- Teammate may have completed work but not yet updated tasks.md
- Another teammate may have edited tasks.md (race condition in file-ownership strategy)
- The mark-tasks-complete.py script runs during CLEANUP, after all tasks are done

The authoritative source is the dispatch state's `completedGroups` array. From `specs/user-auth/.dispatch-state.json`:

```json
{
  "completedGroups": ["data-models", "api-layer", "services", "ui-components"],
  "groups": [
    {"index": 0, "name": "data-models", "tasks": ["1.1", "1.2"], ...},
    {"index": 1, "name": "api-layer", "tasks": ["1.4", "1.5", "2.1"], ...}
  ]
}
```

**Fix approach**: Add a secondary check before the tasks.md loop:

```bash
# Check dispatch state first -- if this teammate's group is in completedGroups, allow idle
TEAMMATE_GROUP_DONE=$(jq -r --arg name "$TEAMMATE_NAME" \
  '.completedGroups // [] | index($name) != null' \
  "$DISPATCH_STATE" 2>/dev/null) || TEAMMATE_GROUP_DONE="false"

if [ "$TEAMMATE_GROUP_DONE" = "true" ]; then
  exit 0  # Group is in completedGroups -- allow idle
fi
```

This check happens BEFORE the tasks.md loop. If the group is already marked complete in dispatch state, the teammate is allowed to idle regardless of tasks.md content.

### Bug 4: TaskCompleted Fires on Idle With In-Progress Tasks

**Confirmed by official docs**: "This fires in two situations: when any agent explicitly marks a task as completed through the TaskUpdate tool, **or when an agent team teammate finishes its turn with in-progress tasks.**"

This means: teammate has in-progress tasks -> tries to go idle -> TaskCompleted fires for each in-progress task -> if any TaskCompleted hook blocks (e.g., Bug 1's Files:none) -> teammate gets error feedback -> tries again -> infinite loop.

The fix is NOT to change TaskCompleted behavior (that's Claude Code core), but to ensure TaskCompleted does NOT spuriously block:

1. Fix Bug 1 (Files:none sentinel) -- removes the most common false-positive block
2. Add graceful handling in task-completed-gate.sh for tasks that genuinely cannot pass verification yet (e.g., a task whose verify command depends on another group's work)

**Additional consideration**: When TaskCompleted fires for "finishing turn with in-progress tasks", the `task_subject` may still contain a valid `X.Y:` prefix, meaning the hook will try to run that task's verify command. If the task is genuinely incomplete (work not done), the verify command WILL fail, and the hook WILL block. This is correct behavior when the teammate hasn't done the work. The problem is only when the verify passes but Stage 3 (file check) blocks on a sentinel value.

### Bug 5: Cascade Shutdown Deadlock

The full cascade:

```
1. Teammate completes Task X.Y but task has **Files**: none
2. TaskCompleted fires (Stage 3) → "Missing files: none" → exit 2 (BLOCK)
3. Teammate gets error: "Create the missing files before marking task complete"
4. Teammate tries to idle (can't complete the task)
5. TeammateIdle fires → tasks.md shows [ ] for this task → exit 2 (BLOCK)
6. Teammate is forced back to work → tries to complete again → goto step 2
7. This loops FOREVER because TeammateIdle has no safety valve (Bug 2)
8. Meanwhile, lead tries to stop → Stop hook blocks (dispatch not done)
9. Stop hook has MAX_BLOCKS=3 safety valve → lead eventually escapes
10. But teammates are STUCK with no escape mechanism
11. Teammates burn tokens indefinitely until session timeout or user intervention
```

The fixes break this cascade at multiple points:
- Bug 1 fix: Step 2 no longer blocks (sentinel handled)
- Bug 2 fix: Step 7 has a safety valve (MAX_IDLE_BLOCKS)
- Bug 3 fix: Step 5 checks dispatch state, not stale tasks.md

### Existing Test Patterns

**test_gate.sh** (hooks/scripts/test_gate.sh): Integration tests for task-completed-gate.sh.
- Uses `run_test()` with expected exit code and stderr substring
- Creates tmpdir with minimal spec structure
- Uses a `setup_*` function to populate files per test case
- 7 tests covering verify pass/fail, typecheck pass/fail, file existence pass/fail, backward compat
- Missing: NO test for `**Files**: none` sentinel value (the bug was undiscovered)

**test_stop_hook.sh** (scripts/test_stop_hook.sh): Tests for dispatch-coordinator.sh.
- More comprehensive: `setup_project()`, `write_dispatch_state()`, `begin_test()/end_test()`
- Assert functions: `assert_exit_code`, `assert_stdout_contains_json_block`, etc.
- 22 tests, 100 assertions
- Pattern: create tmpdir, populate dispatch state, pipe JSON input to hook script, check exit code and output

**test_session_isolation.sh** (scripts/test_session_isolation.sh): Tests for session isolation.
- 24 tests, 41 assertions
- Similar pattern to test_stop_hook.sh

No existing test file for teammate-idle-gate.sh -- one must be created.

### Dependencies and Existing Patterns

**dispatch-coordinator.sh block counter** (fully implemented, battle-tested):
- Counter file: `/tmp/ralph-stop-${SPEC_NAME}-${SESSION_ID}`
- Format: `count:status:dispatchedAt`
- Read: `read_block_counter()` function
- Write: `write_block_counter()` function
- Reset: automatic on dispatch identity change (status or dispatchedAt mismatch)
- Safety valve: `MAX_BLOCKS` env var, default 3

This pattern can be directly ported to teammate-idle-gate.sh with minimal adaptation.

**build-teammate-prompt.py** (scripts/build-teammate-prompt.py):
- Line 230: `- For each task: implement -> verify -> commit -> mark [x] in specs/{spec_name}/tasks.md`
- Teammates are explicitly told to update tasks.md checkboxes
- But if TaskCompleted blocks, the teammate never gets to the "mark [x]" step
- This creates a stale-tasks.md feedback loop (Bug 3)

### Dispatch State Structure

From `specs/user-auth/.dispatch-state.json`:

```json
{
  "dispatchedAt": "2026-02-21T14:45:00Z",
  "strategy": "file-ownership",
  "maxTeammates": 4,
  "groups": [
    {"index": 0, "name": "data-models", "tasks": ["1.1", "1.2"], "ownedFiles": [...], "dependencies": []},
    {"index": 1, "name": "api-layer", "tasks": ["1.4", "1.5", "2.1"], "ownedFiles": [...], "dependencies": []}
  ],
  "serialTasks": ["2.3"],
  "verifyTasks": ["1.8", "2.4"],
  "status": "dispatched",
  "completedGroups": ["data-models", "api-layer"]
}
```

Key fields for fixes:
- `groups[].name` maps to `TEAMMATE_NAME` (from `CLAUDE_CODE_AGENT_NAME`)
- `groups[].tasks` lists task IDs assigned to that group
- `completedGroups` is the authoritative completion source (Bug 3 fix)
- `dispatchedAt` is used for block counter reset identity (Bug 2 fix)

## Related Specs

| Spec | Relevance | mayNeedUpdate | Notes |
|------|-----------|---------------|-------|
| stop-hook-sticky-stderr | **High** | No | Rewrote dispatch-coordinator.sh with JSON decision control + block counter. This spec's Bug 2 fix ports the same block counter pattern to teammate-idle-gate.sh. No conflict -- different file. |
| dispatch-quality-gates | **High** | No | Added VERIFY phase gate (Stage 1.5), lint gate (Stage 6), merge-guard.sh. Bug 1 fix is in Stage 3 of same file (task-completed-gate.sh) but different lines -- no conflict. |
| dispatch-guardrails | **Medium** | No | Added validate-tasks-format.py and manual groups. Different files, no overlap. |
| session-isolation | **Low** | No | Session isolation for dispatch-coordinator.sh. No overlap with teammate-idle-gate.sh or task-completed-gate.sh. |
| quality-gates-v2 | **Low** | No | Added lint gate, task writeback, commit provenance. All merged, no overlap. |

## Quality Commands

| Type | Command | Source |
|------|---------|--------|
| Build | `tsc` | package.json scripts.build |
| TypeCheck | `tsc --noEmit` | package.json scripts.typecheck |
| Test | `node ./scripts/test.mjs` | package.json scripts.test |
| Lint | Not found | - |
| Bash syntax | `bash -n <script>` | Existing test patterns (stop-hook-sticky-stderr) |
| Hook tests (gate) | `bash ralph-parallel/hooks/scripts/test_gate.sh` | Existing test file |
| Hook tests (stop) | `bash ralph-parallel/scripts/test_stop_hook.sh` | Existing test file |
| Hook tests (isolation) | `bash ralph-parallel/scripts/test_session_isolation.sh` | Existing test file |
| Python tests | `cd ralph-parallel && python3 -m pytest scripts/ -v` | Existing pattern |

**Local CI**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/teammate-idle-gate.sh && bash ralph-parallel/hooks/scripts/test_gate.sh && bash ralph-parallel/scripts/test_stop_hook.sh`

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | **High** | All fixes are localized to 2 shell scripts. Patterns already exist in dispatch-coordinator.sh. |
| Effort Estimate | **S** | Bug 1 is a 3-line fix. Bug 2 is ~30 lines ported from existing pattern. Bug 3 is a ~10-line addition. Bug 4 is solved by Bug 1. Bug 5 is solved by Bugs 1-3. |
| Risk Level | **Low** | Changes are additive (new guards before existing logic) or defensive (sentinel checks). No existing behavior is removed. |
| Test Coverage | **Medium** | test_gate.sh exists for task-completed-gate.sh. New test file needed for teammate-idle-gate.sh. |

## Recommendations for Requirements

1. **Bug 1 (Files:none)**: Add case-insensitive sentinel check after TASK_FILES extraction in Stage 3. Pattern: `case "$lower" in none|n/a|n/a\ *|-|"") ...`. Zero risk -- purely defensive.

2. **Bug 2 (safety valve)**: Port block counter from dispatch-coordinator.sh. Use `/tmp/ralph-idle-${SPEC_NAME}-${TEAMMATE_NAME}` as counter file. Default MAX_IDLE_BLOCKS=5 (configurable via env var). Log warning when safety valve triggers.

3. **Bug 3 (stale tasks.md)**: Add completedGroups check BEFORE tasks.md loop. If teammate's group name is in completedGroups, allow idle immediately. This is the authoritative source per dispatch protocol.

4. **Bug 4 (TaskCompleted on idle)**: No separate fix needed -- solved by Bug 1. The double-trigger behavior is by design in Claude Code. The fix is ensuring the hook doesn't spuriously block.

5. **Bug 5 (cascade deadlock)**: No separate fix needed -- solved by combination of Bugs 1-3. The cascade is broken at multiple points.

6. **Tests**: Add `**Files**: none` test case to existing test_gate.sh. Create new test_teammate_idle_gate.sh with tests for: safety valve, completedGroups check, normal block behavior, counter reset.

7. **Ordering**: Bug 1 fix should be implemented first (highest impact, simplest change). Bug 2+3 can be done in parallel (different parts of teammate-idle-gate.sh).

## Additional Issues Discovered

### Issue: test_gate.sh Does Not Clean Up Properly

The existing test_gate.sh uses `trap "rm -rf $tmpdir" RETURN` inside `run_test()`. This trap is scoped to the function, which is correct, but the git rev-parse fallback in task-completed-gate.sh means tests must run outside a git repo or with `CWD` set correctly. The test file handles this by passing `"cwd":"$tmpdir"` in the input JSON.

### Issue: No CLAUDE_CODE_AGENT_NAME Handling in task-completed-gate.sh

The task-completed-gate.sh script does NOT check `CLAUDE_CODE_AGENT_NAME`. It fires for ALL agents (lead + teammates). This is intentional (per dispatch-quality-gates learnings) but means the lead's VERIFY tasks also go through the gate. No fix needed, just documentation.

### Issue: teammate-idle-gate.sh Has No Logging

Unlike dispatch-coordinator.sh which logs block count and reason to stderr, teammate-idle-gate.sh has minimal logging. The fix should add logging for: block count, safety valve trigger, completedGroups bypass.

## Open Questions

1. **MAX_IDLE_BLOCKS default**: Should it be 5 (recommended) or match the Stop hook's 3? Higher value gives teammates more chances to complete work before escape. Lower value prevents excessive token burn.

2. **Counter file cleanup**: When should idle block counter files be cleaned up? Options: (a) session-setup.sh on dispatch terminal state, (b) let OS /tmp cleanup handle it, (c) cleanup in teammate-idle-gate.sh when allowing idle. Recommend (b) for simplicity -- tmp files are ephemeral.

3. **Additional sentinel values**: Are there other `**Files**:` values beyond `none`, `N/A`, `N/A (validation only)`, and `-` that should be treated as sentinels? The current grep found these 4 patterns. Recommend a case-insensitive catch-all that handles these plus common variations.

## Sources

- Claude Code Hooks Reference: https://code.claude.com/docs/en/hooks
- Claude Code Agent Teams: https://code.claude.com/docs/en/agent-teams
- task-completed-gate.sh: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`
- teammate-idle-gate.sh: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/teammate-idle-gate.sh`
- dispatch-coordinator.sh: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/dispatch-coordinator.sh`
- test_gate.sh: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/test_gate.sh`
- test_stop_hook.sh: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/test_stop_hook.sh`
- dispatch.md: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md`
- build-teammate-prompt.py: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py`
- user-auth dispatch state: `/Users/patrickkavanagh/parallel_ralph/specs/user-auth/.dispatch-state.json`
- Sentinel value grep across specs/*/tasks.md
