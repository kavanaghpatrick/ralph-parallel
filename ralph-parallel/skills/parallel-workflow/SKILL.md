---
name: parallel-workflow
description: This skill should be used when the user asks about "parallel execution", "dispatch tasks", "agent teams", "parallel ralph", "simultaneous tasks", "multi-agent", "file ownership", "worktree strategy", or needs guidance on running ralph-specum tasks in parallel across multiple Claude Code teammates.
---

# Parallel Workflow

Guides users through dispatching ralph-specum spec tasks for parallel execution via Claude Code Agent Teams.

## Overview

Ralph Parallel extends ralph-specum by enabling multiple spec tasks to execute simultaneously across Agent Teams teammates. Instead of sequential task-by-task execution, tasks are partitioned into non-conflicting groups and dispatched to separate teammates.

## Workflow

```text
1. Create spec normally:     /ralph-specum:start my-feature "goal"
2. Complete spec phases:     research → requirements → design → tasks
3. Dispatch for parallel:    /ralph-parallel:dispatch
   → Analyzes tasks, partitions by file ownership, creates team, spawns teammates
   → Lead coordinates execution, runs verify checkpoints, handles serial tasks
4. Monitor progress:         /ralph-parallel:status
5. Integrate results:        /ralph-parallel:merge (worktree strategy only)
6. Handle remaining serial:  /ralph-specum:implement (if any tasks remain)
```

## Strategies

### File Ownership (Default)

Each teammate gets exclusive ownership of certain files. No merge needed — teammates work in the same repo but on different files. The lead orchestrates everything directly.

**Best for:** Most projects. Simple, no merge complexity.
**Limitation:** Tasks sharing files must be serialized.

### Worktree (Phase 2)

Each teammate gets its own git worktree with a separate branch. Full file access but requires merge step.

**Best for:** Highly coupled codebases where tasks touch overlapping files.
**Limitation:** Merge conflicts possible, requires /ralph-parallel:merge step.

## Commands

| Command | Purpose |
|---------|---------|
| `/ralph-parallel:dispatch` | Analyze tasks, partition, create team, orchestrate execution |
| `/ralph-parallel:status` | Show parallel execution progress |
| `/ralph-parallel:merge` | Integrate results (worktree strategy) or verify consistency |

## How It Works

1. **Dispatch** reads tasks.md and builds a dependency graph based on file overlap
2. Tasks with non-overlapping files are grouped for parallel execution
3. Dispatch creates an Agent Team directly using TeamCreate + Task tools
4. Teammates are spawned in parallel with inline prompts specifying their tasks and owned files
5. The lead monitors completion, runs verify checkpoints, and handles serial tasks
6. For file-ownership strategy: no merge needed — dispatch handles everything end-to-end
7. For worktree strategy: **merge** resolves branches after team completion

## Dispatch State Lifecycle

```text
dispatched → merged        (normal completion)
dispatched → merging → merged  (worktree strategy with merge step)
dispatched → superseded    (new dispatch replaces stale one)
```

## Quality Gates

- Each task's **Verify** command runs automatically via TaskCompleted hook (per-task, not per-group)
- File ownership violations are detected during merge
- [VERIFY] checkpoint tasks are always executed by the lead sequentially
- Full test suite runs after merge (if configured)

## Tips

- Start with file-ownership strategy — it's simpler and covers most cases
- Keep tasks well-scoped: smaller tasks parallelize better
- Use [P] markers in tasks.md to pre-tag parallel-safe tasks
- Monitor with `/ralph-parallel:status` — don't wait blindly
- If a teammate gets stuck, the lead can reassign its remaining tasks
