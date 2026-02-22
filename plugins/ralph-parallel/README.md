# ralph-parallel

Parallel spec execution via Claude Code Agent Teams. Analyzes tasks from ralph-specum specs, partitions them into parallelizable groups by file ownership, and dispatches them to Agent Teams teammates for simultaneous execution.

## Commands

| Command | Description |
|---------|-------------|
| `dispatch` | Analyze tasks.md, partition into groups, and dispatch to Agent Teams teammates for parallel execution |
| `status` | Monitor progress of an active parallel dispatch |
| `merge` | Verify and integrate results after all teammates complete |

## Hooks

| Hook | Event | Description |
|------|-------|-------------|
| `session-setup.sh` | SessionStart | Configure gc.auto management and output context for the session |
| `file-ownership-guard.sh` | PreToolUse (Write/Edit) | Block file writes outside the teammate's owned files |
| `dispatch-coordinator.sh` | Stop | Re-inject coordination context after compaction |
| `task-completed-gate.sh` | TaskCompleted | Per-task verification: verify command, typecheck, file existence, build, test, and lint checks |

## Scripts

| Script | Description |
|--------|-------------|
| `parse-and-partition.py` | Parse tasks.md, build dependency graph, and partition tasks into parallelizable groups by file ownership |
| `build-teammate-prompt.py` | Generate teammate prompts from partition JSON with rules, commit conventions, and task blocks |
| `validate-tasks-format.py` | Validate tasks.md structure and verify command format before dispatch |
| `capture-baseline.sh` | Capture pre-dispatch baseline snapshot (test counts, lint state) for regression detection |
| `mark-tasks-complete.py` | Write back completed task checkboxes to tasks.md from dispatch-state.json completedGroups |
| `verify-commit-provenance.py` | Audit git log for Signed-off-by trailers and report provenance coverage per teammate |

## Quick Start

```
/ralph-parallel:dispatch
```

Run this command from a project with a ralph-specum spec (containing `tasks.md`). The plugin will:

1. Parse and validate the spec's tasks
2. Partition tasks into parallelizable groups based on file ownership
3. Capture a quality baseline (test counts, lint state)
4. Dispatch each group to an Agent Teams teammate
5. Monitor completion with periodic build, test, and lint checks
6. Write back task completion marks and verify commit provenance
