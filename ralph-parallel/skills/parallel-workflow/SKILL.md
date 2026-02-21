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
4. Monitor progress:         /ralph-parallel:status
5. Integrate results:        /ralph-parallel:merge
6. Handle remaining serial:  /ralph-specum:implement
```

## Strategies

### File Ownership (Default)

Each teammate gets exclusive ownership of certain files. No merge needed — teammates work in the same repo but on different files.

**Best for:** Most projects. Simple, no merge complexity.
**Limitation:** Tasks sharing files must be serialized.

### Worktree (Phase 2)

Each teammate gets its own git worktree with a separate branch. Full file access but requires merge step.

**Best for:** Highly coupled codebases where tasks touch overlapping files.
**Limitation:** Merge conflicts possible, requires /ralph-parallel:merge step.

## Commands

| Command | Purpose |
|---------|---------|
| `/ralph-parallel:dispatch` | Analyze tasks, partition, generate team prompt |
| `/ralph-parallel:status` | Show parallel execution progress |
| `/ralph-parallel:merge` | Integrate results after team completion |

## How It Works

1. **Dispatch** reads tasks.md and builds a dependency graph based on file overlap
2. Tasks with non-overlapping files are grouped for parallel execution
3. A team creation prompt is generated (Agent Teams uses natural language)
4. The user pastes the prompt into a new session to create the team
5. Teammates execute their assigned tasks simultaneously
6. After completion, **merge** verifies consistency and integrates results
7. Remaining serial tasks and verify checkpoints run via normal ralph-specum

## Quality Gates

- Each task's **Verify** command runs automatically via TaskCompleted hook
- File ownership violations are detected during merge
- [VERIFY] checkpoint tasks are always executed sequentially
- Full test suite runs after merge (if configured)

## Tips

- Start with file-ownership strategy — it's simpler and covers most cases
- Keep tasks well-scoped: smaller tasks parallelize better
- Use [P] markers in tasks.md to pre-tag parallel-safe tasks
- Monitor with `/ralph-parallel:status` — don't wait blindly
- If a teammate gets stuck, the lead can reassign its remaining tasks
