---
spec: dispatch-guardrails
phase: research
created: 2026-02-22T22:15:19Z
generated: auto
---

# Research: dispatch-guardrails

## Executive Summary

The ralph-parallel plugin has a pipeline bypass vulnerability: dispatch leads can manually write teammate prompts, skipping build-teammate-prompt.py and losing Signed-off-by, quality commands, file ownership, and baseline test count. Three changes fix this: (1) `--manual-groups` flag on parse-and-partition.py for sanctioned overrides, (2) new validate-prompt.py script for post-dispatch validation, (3) minimal dispatch.md update to invoke validation.

## Codebase Analysis

### Existing Patterns

- **parse-and-partition.py** (943 lines): Already supports predefined group annotations via `### Group N:` headers in tasks.md and `--strategy` flag for worktree mode. Adding `--manual-groups` follows the same pattern as existing `--strategy` flag.
- **build-teammate-prompt.py** (205 lines): Generates prompts with required sections: `## File Ownership`, `## Quality Checks`, `## Commit Convention` (Signed-off-by), `## Rules`. These are the sections to validate.
- **validate-tasks-format.py** (435 lines): Existing validation script pattern — reads content, returns structured diagnostics, uses exit codes 0/1/2/3. New validate-prompt.py should follow identical patterns.
- **hooks.json**: 4 hooks registered (SessionStart, PreToolUse, Stop, TaskCompleted). No post-spawn hook exists — validation must be called from dispatch.md.

### Dependencies

- `jq` — used by hooks for JSON parsing, available in environment
- `argparse`, `json`, `re`, `sys` — standard library, no new deps needed
- build-teammate-prompt.py already produces deterministic output — validation can check for exact section headers

### Constraints

- dispatch.md is executed by the AI lead agent, not a shell — prose changes alone are unenforceable
- No PostToolUse hook available for Task tool — can't auto-validate on teammate spawn
- Fail-open policy: validation warns but doesn't kill teammates (they're already spawned)
- Manual groups must still produce valid partition JSON compatible with build-teammate-prompt.py

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All changes extend existing patterns |
| Effort Estimate | M | 3 files modified, 1 new script, ~200 LOC total |
| Risk Level | Low | Additive changes, no breaking modifications |

## Recommendations

1. Add `--manual-groups` as JSON string arg to parse-and-partition.py, reusing `_build_groups_from_predefined` logic
2. Create validate-prompt.py as standalone script matching validate-tasks-format.py patterns
3. Add Step 6.5 to dispatch.md that calls validate-prompt.py after all teammates spawned
4. Write tests for both new features following existing test patterns (importlib.util loading)
