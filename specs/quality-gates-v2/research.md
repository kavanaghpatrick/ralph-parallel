---
spec: quality-gates-v2
phase: research
created: 2026-02-22
generated: auto
---

# Research: quality-gates-v2

## Executive Summary

Three audit issues from v6 dispatch need script-level fixes: (1) lint enforcement missing from task-completed-gate.sh, (2) no script to write back `[x]` marks to tasks.md after dispatch, (3) no commit provenance attribution for worktree teammates. All fixes are additive, ecosystem-agnostic, and favor deterministic scripts over prose.

## Codebase Analysis

### Existing Patterns

- **Quality command sourcing**: All scripts read commands from `dispatch-state.json .qualityCommands` (task-completed-gate.sh lines 131-132, 180, 232). New lint stage follows same pattern.
- **Stage-based gate**: task-completed-gate.sh uses numbered stages (1-5). Lint becomes Stage 6.
- **Python scripts with argparse CLI**: parse-and-partition.py, build-teammate-prompt.py, validate-tasks-format.py all follow `argparse + main() + stdin/file input + stdout JSON` pattern.
- **Bash scripts with jq**: capture-baseline.sh reads/writes dispatch-state.json via jq. New mark-tasks-complete.py follows the JSON-in/file-out pattern.
- **Teammate prompt generation**: build-teammate-prompt.py builds per-group prompts. Commit convention injection goes here.

### Dependencies

- `jq` -- all bash scripts depend on it (already required)
- `python3` -- all Python scripts (already required)
- `git` -- for commit provenance verification (already available)
- No new external dependencies needed

### Constraints

- **Ecosystem-agnostic**: Lint command must come from `qualityCommands.lint`, never hardcoded
- **No new hooks**: All fixes go into existing scripts or new standalone scripts
- **Backward compatible**: Existing dispatches without lint commands must pass through gracefully
- **File format**: tasks.md checkbox format `- [ ] X.Y` / `- [x] X.Y` is stable, parsed by regex

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All 3 fixes are additive to existing script patterns |
| Effort Estimate | M | 3 scripts to modify, 1 new script, 1 new verification script |
| Risk Level | Low | No breaking changes, graceful fallback for missing commands |

## Recommendations

1. Add lint as Stage 6 in task-completed-gate.sh (periodic, same interval as build)
2. Create mark-tasks-complete.py that reads completedGroups from dispatch-state.json and updates tasks.md
3. Inject `Signed-off-by: <agent-name>` git trailer via build-teammate-prompt.py commit convention
4. Add verify-commit-provenance.py for post-merge provenance audit
