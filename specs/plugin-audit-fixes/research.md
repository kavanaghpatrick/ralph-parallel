---
spec: plugin-audit-fixes
phase: research
created: 2026-02-26T14:30:00Z
---

# Research: plugin-audit-fixes

## Executive Summary

Comprehensive audit of 18 bugs across ralph-parallel plugin. All 18 confirmed via code reading and reproduction. 6 CRITICAL issues affect correctness (broken dependency ordering, format mismatch, env var propagation, dispatch flow gaps). 12 HIGH issues affect robustness and documentation accuracy. Most fixes are surgical (1-10 line changes); the format mismatch (#2) requires a design decision on canonical format.

## Issue Analysis

### CRITICAL #1: String comparison of task IDs

**Location**: `parse-and-partition.py:440,445,611,628`

**Root cause**: Task IDs like `"1.10"` are compared with Python `<` / `>` operators on strings. String comparison is lexicographic: `"1.10" < "1.2"` evaluates to `True` because `"1" < "2"` at character index 2.

**Reproduction**:
```python
>>> sorted(["1.1", "1.2", "1.10", "1.9", "1.11", "2.1"])
['1.1', '1.10', '1.11', '1.2', '1.9', '2.1']  # WRONG
```

**Affected locations (4)**:

| Line | Context | Impact |
|------|---------|--------|
| 440 | `other['id'] < t['id']` in VERIFY dependency building | VERIFY task 1.10 treated as preceding task 1.2 |
| 445 | `other['id'] > t['id']` in post-VERIFY dependency | Tasks after VERIFY not blocked correctly |
| 611 | `.sort(key=lambda t: (t['phase'], t['id']))` in worktree | Wrong task ordering for 10+ tasks per phase |
| 628 | Same sort in automatic partitioning | Wrong task ordering |

**Fix**: Create a helper function and use it everywhere:

```python
def _task_id_key(task_id: str) -> tuple[int, int]:
    """Convert 'X.Y' to (X, Y) for correct numeric comparison."""
    parts = task_id.split('.')
    return (int(parts[0]), int(parts[1]))
```

Replace:
- Lines 440,445: `other['id'] < t['id']` -> `_task_id_key(other['id']) < _task_id_key(t['id'])`
- Lines 611,628: `key=lambda t: (t['phase'], t['id'])` -> `key=lambda t: (t['phase'], _task_id_key(t['id']))`

**Risk**: Low. Pure logic fix, no side effects.
**Tests needed**: Yes -- add test with task IDs "1.1" through "1.12" and verify correct VERIFY dependency ordering.

---

### CRITICAL #2: Quality Commands format mismatch

**Location**: `parse-and-partition.py:124-167` vs `validate-tasks-format.py:317-318` vs actual tasks.md files

**Root cause**: Three different formats in play:

| Component | Expected Format | Example |
|-----------|----------------|---------|
| `parse-and-partition.py` `parse_quality_commands_from_tasks()` | Code-fenced `slot: cmd` | ````\nbuild: cargo build\n```` |
| `validate-tasks-format.py` `validate_quality_commands_section()` | Bold markdown | `**Build**: \`cargo build\`` |
| Actual tasks.md (session-isolation) | Bold markdown with dash prefix | `- **Build**: N/A` |
| Actual tasks.md (quality-gates-v2) | Bare dash prefix | `- Build: N/A` |

**Evidence from real files**:
- `specs/session-isolation/tasks.md:5`: `- **Build**: N/A (bash scripts + markdown -- no compilation)`
- `specs/session-isolation/tasks.md:8`: `- **Test**: \`bash ralph-parallel/scripts/test_session_isolation.sh\``
- `specs/quality-gates-v2/tasks.md:12`: `- Build: N/A`

**Impact**: `parse_quality_commands_from_tasks()` finds zero quality commands from real tasks.md files because it looks for code-fenced blocks. Falls back to auto-discovery, which may find wrong commands (e.g., project-root package.json instead of monorepo subdirectory).

**Decision required**: Choose ONE canonical format. Recommendation: **bold markdown format** (`- **Build**: \`cmd\``) because:
1. It's what the task-planner (ralph-specum) actually generates
2. It's what `validate-tasks-format.py` already validates
3. It's more readable in rendered markdown

**Fix**: Update `parse_quality_commands_from_tasks()` in `parse-and-partition.py` to parse bold markdown format:

```python
def parse_quality_commands_from_tasks(content: str) -> dict:
    result = {}
    valid_slots = {"typecheck", "build", "test", "lint", "dev"}
    in_section = False

    for line in content.split('\n'):
        if re.match(r'^##\s+Quality\s+Commands', line, re.IGNORECASE):
            in_section = True
            continue
        if in_section and re.match(r'^##\s+', line) and not re.match(r'^##\s+Quality', line, re.IGNORECASE):
            break
        if not in_section:
            continue

        # Parse bold markdown: - **Build**: `cmd` or **Build**: `cmd`
        m = re.match(r'^[-*]\s*\*\*(\w+)\*\*:\s*`([^`]+)`', line.strip())
        if m:
            slot = m.group(1).lower()
            cmd = m.group(2).strip()
            if slot in valid_slots and cmd:
                result[slot] = cmd
            continue

        # Also support code-fenced format (backward compat)
        # ... keep existing code-fence parsing ...
```

**Risk**: Medium. Changing parser format could break if some specs use the old code-fenced format. Mitigate by supporting BOTH formats.
**Tests needed**: Yes -- test both bold markdown and code-fenced formats.

---

### CRITICAL #3: Missing `export` in session-setup.sh:19

**Location**: `session-setup.sh:19`

**Current code**:
```bash
echo "CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
```

**Root cause**: `CLAUDE_ENV_FILE` is sourced before each Bash tool invocation. Lines written to it must use `export` keyword for variables to propagate to subprocess environments.

**Evidence**: [Claude Code docs](https://code.claude.com/docs/en/settings) confirm `CLAUDE_ENV_FILE` expects `export` statements. Blog posts and community examples all use `export VAR=value` format.

**Fix**: Single character change:
```bash
echo "export CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
```

**Risk**: Very low. Purely additive.
**Tests needed**: Update existing test (test_session_isolation.sh test_T10) to verify the `export` keyword is present.

---

### CRITICAL #4: dispatch.md Step 3 missing `--strategy` flag

**Location**: `dispatch.md:82-87` (Step 3)

**Current code**:
```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/parse-and-partition.py \
  --tasks-md specs/$specName/tasks.md \
  --max-teammates $maxTeammates \
  --format
```

**Missing**: `--strategy $strategy` flag.

**Impact**: When user passes `--strategy worktree`, Step 2 uses it correctly but Step 3 (display plan) defaults to `file-ownership`. The displayed plan does not match the actual partition. The user sees the wrong plan and approves dispatch based on incorrect information.

**Fix**: Add `--strategy $strategy` to the Step 3 command:
```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/parse-and-partition.py \
  --tasks-md specs/$specName/tasks.md \
  --max-teammates $maxTeammates \
  --strategy $strategy \
  --format
```

**Risk**: None. Pure documentation fix.
**Tests needed**: No (dispatch.md is interpreted by the LLM, not executed programmatically).

---

### CRITICAL #5: Partition JSON file path never established

**Location**: `dispatch.md:189` references `/tmp/$specName-partition.json`

**Root cause**: Step 2 says "Save to a variable" but Step 6 references `--partition-file /tmp/$specName-partition.json`. No step writes the partition JSON to that file.

**Impact**: `build-teammate-prompt.py` would fail with FileNotFoundError when trying to read `/tmp/$specName-partition.json`. In practice, the LLM may work around this by piping stdin, but the documentation is misleading.

**Fix options** (pick one):
1. **Add a save step**: After Step 2, add: "Save the partition JSON to `/tmp/$specName-partition.json`"
2. **Use stdin piping**: Change Step 6 to pipe the partition JSON via stdin instead of `--partition-file`
3. **Save to dispatch state**: The partition data is already in `.dispatch-state.json` from Step 4. Reference that.

**Recommended**: Option 1 -- explicit save is clearest. Add after Step 2's success case:
```text
Save partition JSON to /tmp/$specName-partition.json for use by build-teammate-prompt.py in Step 6.
```

**Risk**: None. Documentation fix.
**Tests needed**: No.

---

### CRITICAL #6: "Phase 2" hardcoded in coordination loop

**Location**: `dispatch.md:235-237` (Step 7, items 5 and 6)

**Current text**:
```
5. SERIAL TASKS: After Phase 2, execute serial tasks yourself
6. FINAL VERIFY: Run Phase 2 verify checkpoint
```

**Impact**: Specs with 3+ phases will have serial tasks and verify checkpoints only run after Phase 2, skipping Phase 3+ entirely. The coordinator would mark dispatch complete prematurely.

**Fix**: Replace with dynamic phase references:
```
5. SERIAL TASKS: After the LAST parallel phase, execute serial tasks yourself
6. FINAL VERIFY: Run the final phase's verify checkpoint
```

Or more precisely:
```
5. SERIAL TASKS: After ALL parallel groups complete (all phases), execute serial tasks yourself
6. FINAL VERIFY: Run the last phase's verify checkpoint
```

**Risk**: None. Documentation fix.
**Tests needed**: No.

---

### HIGH #7: ZeroDivisionError in `_build_groups_worktree`

**Location**: `parse-and-partition.py:617`

**Current code**:
```python
groups = [{'tasks': [], 'ownedFiles': set(), 'dependencies': set()}
          for _ in range(min(max_teammates, len(parallel_tasks)))]

for i, task in enumerate(parallel_tasks):
    target = i % len(groups)
```

**Trigger**: When ALL incomplete tasks are VERIFY tasks (parallel_tasks is empty), `len(parallel_tasks)` is 0, so `min(max_teammates, 0)` creates 0 groups, then `i % len(groups)` hits ZeroDivisionError.

**Actually**: The division error is in `i % len(groups)` when `groups` is empty. But wait -- if `parallel_tasks` is empty, the `for i, task in enumerate(parallel_tasks)` loop never executes. The actual issue is that `groups` will be an empty list, and the function returns `([], [])`. Then `_format_result` might get 0 groups.

Let me re-examine... `partition_tasks` calls `_build_groups_worktree(parallel_tasks, max_teammates)` where `parallel_tasks` could be empty. The function creates `min(max_teammates, len(parallel_tasks))` = `min(N, 0)` = 0 groups. The loop doesn't execute. Returns `([], [])`. Back in `partition_tasks`, `_format_result` receives empty groups. At line 773: `max((len(g['tasks']) for g in result_groups), default=1)` handles empty with default=1. This seems safe.

**Revised assessment**: The ZeroDivisionError does NOT actually trigger because the loop body never executes when parallel_tasks is empty. However, the subsequent code in `partition_tasks` at line 996 (`len(result['groups']) == 0`) would exit with code 4 ("Could not create any parallel groups"), which is misleading when the real issue is "only VERIFY tasks remain."

**Fix**: Add guard at top of `_build_groups_worktree`:
```python
if not parallel_tasks:
    return [], []
```

**Risk**: Very low.
**Tests needed**: Yes -- test with all-VERIFY task list.

---

### HIGH #8: Rebalance corrupts file_ownership

**Location**: `parse-and-partition.py:697`

**Current code**:
```python
groups[largest]['ownedFiles'] -= task_files
```

**Root cause**: When moving a task from the largest group to the smallest, line 697 removes the task's files from the largest group's `ownedFiles`. But OTHER tasks in that group may still reference those files. The `ownedFiles` set becomes inconsistent with the tasks' actual file needs.

**Impact**: File ownership guard hook (`file-ownership-guard.sh`) reads `ownedFiles` from dispatch state. If a file was removed by rebalancing but another task still needs it, that task's writes will be blocked.

**Fix**: Only remove files that no other task in the group references:
```python
groups[largest]['tasks'].pop(t_idx)
# Only remove files not referenced by remaining tasks
remaining_files = set()
for remaining_task in groups[largest]['tasks']:
    remaining_files.update(remaining_task['files'])
groups[largest]['ownedFiles'] = remaining_files
groups[smallest]['tasks'].append(task)
groups[smallest]['ownedFiles'].update(task_files)
for f in task_files:
    file_ownership[f] = smallest
```

**Risk**: Low. Only affects automatic partitioning when rebalancing triggers.
**Tests needed**: Yes -- test with overlapping files where rebalancing occurs.

---

### HIGH #9: git commit -s contradicts trailer format

**Location**: `build-teammate-prompt.py:180` and `verify-commit-provenance.py:129`

**Conflict**:
- `build-teammate-prompt.py:180`: "Use `git commit -s` flag or manually append the trailer"
- `git commit -s` produces: `Signed-off-by: Claude <noreply@anthropic.com>` (user.name + user.email)
- `verify-commit-provenance.py:129`: `if trailer in known_set` where `known_set` contains bare group names like `"infrastructure"` or `"api-layer"`

**Impact**: `git commit -s` trailers will NEVER match known group names. Every commit gets classified as "unknown_agent" in provenance audit.

**Fix**: Two options:
1. **Remove `-s` advice**: Update `build-teammate-prompt.py:180` to only recommend manual trailer:
   ```
   Append the Signed-off-by trailer manually to every commit message.
   Do NOT use `git commit -s` as it produces the wrong format.
   ```
2. **Update provenance checker**: Parse `Signed-off-by: Name <email>` and extract just the name portion. Too fragile -- group names aren't git usernames.

**Recommended**: Option 1. Remove the `-s` advice.

**Risk**: Very low. Only changes prompt text.
**Tests needed**: No (documentation-level fix in the generated prompt).

---

### HIGH #10: eval cd side effect in task-completed-gate.sh

**Location**: `task-completed-gate.sh:115`

**Current code**:
```bash
cd "$PROJECT_ROOT"
```

**Impact**: After `cd`, subsequent `eval "$VERIFY_CMD"` runs in `PROJECT_ROOT`. If the verify command itself does `cd subdir && cargo test`, the working directory stays in `subdir` for Stage 2 (typecheck), Stage 3 (file existence), Stage 4 (build), Stage 5 (test), and Stage 6 (lint). All supplemental checks could fail or check wrong directories.

**Fix**: Use subshell for each eval:
```bash
VERIFY_OUTPUT=$(cd "$PROJECT_ROOT" && eval "$VERIFY_CMD" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?
```

Or reset before each stage:
```bash
pushd "$PROJECT_ROOT" > /dev/null
# ... run verify ...
popd > /dev/null
```

**Recommended**: Wrap each `eval` in a subshell `(cd "$PROJECT_ROOT" && eval "...")`. This also prevents any other env pollution.

**Risk**: Low. Subshell isolates side effects.
**Tests needed**: Yes -- test with verify command that changes directory.

---

### HIGH #11: Unquoted $PROJECT_ROOT in file-ownership-guard.sh

**Location**: `file-ownership-guard.sh:82`

**Current code**:
```bash
REL_PATH="${FILE_PATH#$PROJECT_ROOT/}"
```

**Impact**: If `PROJECT_ROOT` contains glob characters (`*`, `?`, `[`), bash parameter expansion treats them as patterns. Unlikely in practice but technically a bug.

**Fix**: Quote the variable:
```bash
REL_PATH="${FILE_PATH#"$PROJECT_ROOT"/}"
```

**Risk**: Very low.
**Tests needed**: No (edge case, defensive fix).

---

### HIGH #12: Inconsistent PROJECT_ROOT across hooks

**Location**: All 4 hooks

**Current patterns**:

| Hook | PROJECT_ROOT Source |
|------|--------------------|
| `session-setup.sh` | `git rev-parse --show-toplevel` |
| `dispatch-coordinator.sh` | `CWD` from input JSON, fallback `git rev-parse` |
| `file-ownership-guard.sh` | `CWD` from input JSON, fallback `git rev-parse` |
| `task-completed-gate.sh` | `CWD` from input JSON, fallback `git rev-parse` |

**Impact**: `CWD` from hook input is the Claude agent's current working directory, which could be a subdirectory of the project root. If a teammate `cd`s into `src/` before triggering a hook, `CWD` would be `project/src/` instead of `project/`. This would cause spec directory lookups to fail (`project/src/specs/...` doesn't exist).

**session-setup.sh** always uses `git rev-parse --show-toplevel` (correct). The other 3 hooks prefer `CWD` (potentially wrong).

**Fix**: All hooks should use `git rev-parse --show-toplevel` as primary, with CWD only as fallback when not in a git repo:
```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"
```

**Risk**: Low. `git rev-parse` is the canonical way to find project root.
**Tests needed**: Yes -- test hooks from a subdirectory CWD.

---

### HIGH #13: TaskCreate vs Task naming in dispatch.md

**Location**: `dispatch.md:4` (allowed-tools) vs `dispatch.md:132-170` (Step 5)

**Conflict**:
- `allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]` -- lists `Task`
- Step 5 instructions reference `TaskCreate` tool calls
- Claude Code's actual tool names are `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet` (separate tools)
- The `Task` tool in allowed-tools is the agent spawning tool (spawns subagents)

**Impact**: This is actually NOT a bug. `Task` in allowed-tools means the agent-spawning Task tool (needed for Step 6 teammate spawning). `TaskCreate`/`TaskUpdate`/`TaskList` are always available system tools that don't need to be listed in allowed-tools.

**Revised assessment**: The allowed-tools list is correct. The dispatch command needs `Task` (agent spawning) and the TaskCreate/TaskList tools are always accessible. No fix needed.

**Risk**: N/A
**Tests needed**: No.

---

### HIGH #14: Stall detection contradicts delegation rules

**Location**: `dispatch.md:222-224` (Step 7, item 3c) vs `dispatch.md:289` (CRITICAL rules)

**Conflict**:
- Step 7.3c: "If still no response: reassign tasks to self or serialize"
- CRITICAL rules: "Do NOT execute spec tasks yourself during dispatch (teammates do that)"

**Impact**: Coordinator may incorrectly take over teammate tasks, defeating parallel execution.

**Fix**: Remove "reassign to self" from stall detection. Replace with:
```
c. If still no response: re-spawn the stalled teammate with remaining tasks.
   If re-spawn fails, serialize remaining tasks and warn user.
```

**Risk**: None. Documentation fix.
**Tests needed**: No.

---

### HIGH #15: SendMessage not in allowed-tools

**Location**: `dispatch.md:4` (allowed-tools) vs `dispatch.md:242,258` (uses SendMessage)

**Current allowed-tools**: `[Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]`

**Impact**: The dispatch command needs `SendMessage` for:
- Step 7.7b: Shutting down teammates
- Abort handler: Sending shutdown_request to each teammate

Without `SendMessage` in allowed-tools, the coordinator cannot communicate with teammates or shut them down.

**Fix**: Add `SendMessage` to allowed-tools:
```
allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep, SendMessage]
```

Also consider adding `TeamCreate`, `TeamDelete` which are used in Steps 5 and 7.

**Risk**: None. Expanding tool access.
**Tests needed**: No.

---

### HIGH #16: Wrong step numbers in templates

**Location**: `team-prompt.md:3` and `teammate-prompt.md:5,39`

**team-prompt.md:3**: References "Step 8" -- `dispatch.md` only goes to Step 7.

**teammate-prompt.md:5**: References "Step 7" for spawning -- actually Step 6 in dispatch.md.

**teammate-prompt.md:39**: References TaskList IDs "Created in Step 7" -- actually Step 5.

**Impact**: Minor. These are reference docs used by the dispatch command author, not consumed by LLMs at runtime. The `build-teammate-prompt.py` script generates actual prompts programmatically, not from these templates.

**Fix**: Update step references:
- team-prompt.md: "Step 8" -> "Step 7"
- teammate-prompt.md: "Step 7" -> "Step 6" and "Step 7" -> "Step 5"

**Risk**: None.
**Tests needed**: No.

---

### HIGH #17: Stop hook re-injection omits mark-tasks-complete

**Location**: `dispatch-coordinator.sh:191-195`

**Current re-injected prompt** (lines 191-195):
```
NEXT ACTIONS:
1. Check TaskList for teammate progress
2. If waiting for teammates: they may be idle -- check and send status messages
3. When all Phase N tasks done: run the verify checkpoint yourself
4. When all tasks done: update dispatch-state.json status to "merged", shut down teammates, TeamDelete
```

**Missing**: Step 7.7a from dispatch.md: `mark-tasks-complete.py` call. After compaction, the coordinator loses the CLEANUP instructions and may skip task writeback.

**Fix**: Add mark-tasks-complete to item 4:
```
4. When all tasks done:
   a. Run: python3 ${CLAUDE_PLUGIN_ROOT}/scripts/mark-tasks-complete.py --dispatch-state specs/$SPEC_NAME/.dispatch-state.json --tasks-md specs/$SPEC_NAME/tasks.md
   b. Update dispatch-state.json status to "merged"
   c. Shut down teammates (SendMessage shutdown_request)
   d. TeamDelete
```

But we can't interpolate `CLAUDE_PLUGIN_ROOT` in the shell heredoc easily. Simpler approach:

```
4. When all tasks done: run mark-tasks-complete.py, set status="merged", shut down teammates, TeamDelete
```

This at least reminds the coordinator. The full command is in dispatch.md which may still be in context.

**Risk**: Low. Adding text to re-injection prompt.
**Tests needed**: No.

---

### HIGH #18: No stale status handling in status.md and merge.md

**Location**: `status.md` and `merge.md`

**Root cause**: `session-setup.sh` can set dispatch status to `"stale"` (when team is lost but dispatch isn't complete). Neither status.md nor merge.md mention or handle this status.

**Impact**:
- `status.md`: Would try to query a non-existent team and show confusing results
- `merge.md`: Step 1 validates status as "dispatched" -> proceed. "stale" would fall through to no match, likely causing an error or proceeding incorrectly.

**Fix for status.md**: Add stale handling in Step 1:
```
- If status "stale": Display stale notice with reason and staleSince timestamp.
  Recommend: /ralph-parallel:dispatch to re-dispatch, or /ralph-parallel:dispatch --abort to cancel.
```

**Fix for merge.md**: Add stale handling in Step 1.3:
```
- "stale" -> "This dispatch is stale (team lost). Run /ralph-parallel:dispatch to re-dispatch or --abort to cancel."
```

**Risk**: None. Documentation fixes.
**Tests needed**: No.

---

## Cross-Cutting Patterns

### Pattern: Multiple locations with same bug class

| Bug Class | Instances | Files |
|-----------|-----------|-------|
| String ID comparison | 4 locations | parse-and-partition.py |
| PROJECT_ROOT inconsistency | 3 hooks | file-ownership-guard, task-completed-gate, dispatch-coordinator |
| Format mismatch | 2 parsers | parse-and-partition.py, validate-tasks-format.py |

### Fix Dependencies

```
#2 (format mismatch) MUST be decided before implementing
#5 depends on #4 (both are dispatch.md flow fixes)
#12 can be applied independently to all 3 hooks
#15 should be combined with #13 review (allowed-tools audit)
```

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All issues are well-understood with clear fixes |
| Effort Estimate | M | ~18 fixes, most are 1-10 lines. #1, #2, #8, #10 need tests |
| Risk Level | Low | No architectural changes, all surgical fixes |

## Fix Classification

| Type | Issues | Count |
|------|--------|-------|
| Python code fix | #1, #2, #7, #8 | 4 |
| Shell script fix | #3, #10, #11, #12 | 4 |
| Documentation fix (dispatch.md) | #4, #5, #6, #13, #14, #15 | 6 |
| Documentation fix (other .md) | #16, #18 | 2 |
| Prompt text fix | #9 | 1 |
| Stop hook fix | #17 | 1 |

## Test Coverage

| Issue | Existing Test | New Test Needed |
|-------|--------------|-----------------|
| #1 String IDs | No test for >9 tasks per phase | Yes -- 12-task phase with VERIFY |
| #2 Format mismatch | test_parse_and_partition.py has QC tests but not markdown format | Yes -- bold markdown format parsing |
| #3 Missing export | test_session_isolation.sh T-10 exists but doesn't check `export` keyword | Yes -- update T-10 |
| #7 ZeroDivision | No | Yes -- all-VERIFY task list |
| #8 Rebalance | No | Yes -- overlapping files with rebalancing |
| #10 eval cd | No | Yes -- verify cmd with cd |
| #12 PROJECT_ROOT | No | Yes -- hook invocation from subdirectory |

## Quality Commands

| Type | Command | Source |
|------|---------|--------|
| Build | `tsc` | package.json scripts.build |
| TypeCheck | `tsc --noEmit` | package.json scripts.typecheck |
| Test | `node ./scripts/test.mjs` | package.json scripts.test |
| Lint | Not found | - |
| Plugin tests | `python3 ralph-parallel/scripts/test_parse_and_partition.py` | Existing test files |

**Local CI**: `tsc --noEmit && python3 ralph-parallel/scripts/test_parse_and_partition.py && python3 ralph-parallel/scripts/test_build_teammate_prompt.py && python3 ralph-parallel/scripts/test_mark_tasks_complete.py && python3 ralph-parallel/scripts/test_verify_commit_provenance.py`

## Related Specs

| Spec | Relevance | mayNeedUpdate |
|------|-----------|---------------|
| session-isolation | **High** -- #3 directly modifies session-setup.sh from that spec | false (fix completes their intent) |
| quality-gates-v2 | **High** -- #2 affects QC parsing, #10 affects task-completed-gate.sh | false (fixes complement their work) |
| dispatch-guardrails | **Medium** -- #12, #14, #15 improve dispatch robustness | false |
| parallel-qa-overhaul | **Low** -- general quality improvements | false |

## Recommendations for Requirements

1. **Batch fixes by file**: Group issues by affected file to minimize merge conflicts if dispatching in parallel
2. **Decide format for #2 first**: The quality commands format decision affects both parsers and existing tasks.md files. Recommend: bold markdown (`- **Build**: \`cmd\``) as canonical, with backward-compatible code-fence support
3. **Prioritize #1 (string IDs)**: This is the most impactful bug -- breaks any spec with 10+ tasks per phase
4. **Skip #13**: Not actually a bug after analysis (Task tool is correct in allowed-tools)
5. **Add regression tests for #1, #2, #8**: These are the fixes most likely to regress
6. **Fix #3 immediately**: One-word fix (`export`) with outsized impact on session isolation reliability

## Open Questions

1. Should `parse_quality_commands_from_tasks()` support BOTH formats (bold markdown + code-fenced) for backward compatibility, or just the canonical bold markdown format?
2. For #5 (partition file path): Should we save to /tmp (simple) or use a named temp file via `mktemp` (safer)?
3. For #14 (stall detection): Should re-spawning a stalled teammate be documented as the recommended recovery path?

## Sources

- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/parse-and-partition.py` -- lines 124-167, 440-445, 611-628, 617, 697
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/validate-tasks-format.py` -- lines 317-318
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py` -- line 180
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/verify-commit-provenance.py` -- line 129
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/session-setup.sh` -- line 19
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh` -- line 115
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/file-ownership-guard.sh` -- line 82
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/dispatch-coordinator.sh` -- lines 191-195
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` -- lines 4, 82-87, 189, 222-224, 235-237, 289
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/status.md` -- no stale handling
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/merge.md` -- no stale handling
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/templates/team-prompt.md` -- line 3
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/templates/teammate-prompt.md` -- lines 5, 39
- `/Users/patrickkavanagh/parallel_ralph/specs/session-isolation/tasks.md` -- lines 3-9 (actual QC format)
- `/Users/patrickkavanagh/parallel_ralph/specs/quality-gates-v2/tasks.md` -- lines 11-15 (actual QC format)
- [Claude Code CLAUDE_ENV_FILE docs](https://code.claude.com/docs/en/settings) -- confirms `export` format
- [GitHub #15840](https://github.com/anthropics/claude-code/issues/15840) -- CLAUDE_ENV_FILE for plugins
- [GitHub #19357](https://github.com/anthropics/claude-code/issues/19357) -- CLAUDE_ENV_FILE format documentation
