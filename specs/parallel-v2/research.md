---
spec: parallel-v2
phase: research
created: 2026-02-21
generated: auto
---

# Research: parallel-v2

## Executive Summary

11 targeted improvements to the ralph-parallel plugin (v0.1.0) based on real demo run failures. All changes are to existing markdown instruction files and bash scripts — no new application code. High feasibility since the codebase is small (~1073 lines across 10 files) and well-structured.

## Codebase Analysis

### Existing Patterns

| Pattern | File | Notes |
|---------|------|-------|
| Command = markdown instructions | `commands/dispatch.md` | Claude interprets step-by-step |
| Hook = bash script + JSON config | `hooks/hooks.json`, `hooks/scripts/*.sh` | stdin JSON, exit codes 0/2 |
| State = JSON files in spec dir | `specs/$name/.dispatch-state.json` | Read/written by commands |
| Templates = reference docs | `templates/*.md` | Not loaded automatically, just guidance |
| Skill = SKILL.md description | `skills/parallel-workflow/SKILL.md` | Triggers on keyword match |

### Key Files to Modify

| File | Lines | Changes Needed |
|------|-------|----------------|
| `commands/dispatch.md` | 413 | P0-1 (1:1 tasks), P0-2 (completedGroups), P0-3 (timeouts), P0-4 (verify metadata), P1-7 (abort), P1-8 (rebalancing) |
| `commands/status.md` | 108 | P0-5 (TaskList check), P2-10 (--watch) |
| `commands/merge.md` | 198 | P1-6 (clarify flow) |
| `hooks/scripts/task-completed-gate.sh` | 145 | P0-1 (simplified lookup) |
| `skills/parallel-workflow/SKILL.md` | 82 | P1-6 (clarify flow), P2-11 (example) |
| `templates/teammate-prompt.md` | 46 | P0-1 (1:1 task references) |

### Dependencies

- `jq`: used in hooks for JSON parsing (already dependency)
- `git`: used in session-setup.sh and merge.md (already dependency)
- No new external dependencies needed

### Constraints

- Commands are markdown — changes must be coherent natural language instructions
- Hooks must maintain stdin JSON contract (TaskCompleted schema)
- Backward compat: existing dispatch-state.json files with flat `verifyTasks` array must still be handled
- Plugin version stays at 0.1.0 (these are fixes, not new major features)

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All changes to existing files, well-understood patterns |
| Effort Estimate | M | 11 changes across 6 files, most are instruction rewrites |
| Risk Level | Low | No runtime deps, markdown instruction changes are safe to iterate |

## Impact Analysis

| Priority | Items | Impact |
|----------|-------|--------|
| P0 (High) | 5 items | Fix core dispatch reliability — 1:1 tasks, completedGroups, timeouts, verify metadata, status |
| P1 (Medium) | 3 items | Improve docs clarity and add abort/rebalance — reduces user confusion |
| P2 (Low) | 3 items | Nice-to-haves — file enforcement hook, watch mode, worked example |

## Recommendations

1. Start with P0-1 (1:1 TaskList tasks) as it simplifies the entire task-completed-gate.sh logic
2. P0-4 (verify metadata) pairs naturally with P0-1 since both change dispatch state schema
3. P1-6 (clarify flow) should be done after P0 changes settle the dispatch/merge boundary
4. P2-11 (worked example) should be last since it documents the final state
