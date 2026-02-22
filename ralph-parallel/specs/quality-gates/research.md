---
spec: quality-gates
phase: research
created: 2026-02-22
generated: auto
---

# Research: quality-gates

## Executive Summary

Two complementary improvements to the ralph-parallel quality pipeline: (1) strengthen task-planner verify command generation to ban compile-only checks, and (2) capture baseline test snapshots at dispatch time for regression detection. Both modify existing files with well-understood interfaces.

## Codebase Analysis

### Existing Patterns

| File | Role | Key Sections |
|------|------|-------------|
| `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` | Agent prompt defining task generation rules | Lines 119-145 (Explore), 243-281 (VERIFY format) |
| `commands/dispatch.md` | Dispatch orchestration (Steps 1-7) | Step 4 writes dispatch-state.json, Step 5 creates team |
| `hooks/scripts/task-completed-gate.sh` | 5-stage quality gate hook | Stage 5 runs test suite, exits 2 on failure |
| `scripts/build-teammate-prompt.py` | Generates teammate prompts with quality section | `build_quality_section()` function |

### Dependencies

- `dispatch-state.json` schema: `{ qualityCommands: { typecheck, build, test, lint, dev } }` -- will add `baselineSnapshot` field
- task-completed-gate.sh reads `qualityCommands.test` from dispatch-state.json -- will also read `baselineSnapshot`
- task-planner.md is in the ralph-specum plugin cache (external to this repo, but user owns it)

### Constraints

- No test suite exists for the plugin -- verification is manual inspection + `bash -n` / `python3 -c "import ast; ..."` syntax checks
- task-planner.md is a Markdown agent prompt, not executable code
- Test output parsing varies wildly across runners (jest, pytest, cargo test, go test, etc.)
- Baseline snapshot must handle: no test command, pre-existing failures, unparseable output

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All changes are to existing files with clear interfaces |
| Effort Estimate | S-M | 4 files to modify, no new files needed |
| Risk Level | Low | Additive changes, no breaking modifications |

## Test Output Parsing Strategy

Different test runners output counts differently:

| Runner | Pattern | Example |
|--------|---------|---------|
| jest/vitest | `Tests:\s+(\d+) passed` | Tests: 42 passed |
| pytest | `(\d+) passed` | 42 passed, 1 failed |
| cargo test | `test result: ok. (\d+) passed` | test result: ok. 15 passed |
| go test | `ok\s+` (count lines) | ok package 0.5s |
| generic | Count lines matching `PASS\|pass\|ok\|✓` | Fallback heuristic |

Strategy: parse with ordered regex cascade. Store `-1` if unparseable or pre-existing failures.

## Recommendations

1. Add anti-pattern list as `<mandatory>` block in task-planner.md for maximum enforcement
2. Insert Step 4.5 in dispatch.md between state write and team creation
3. Enhance Stage 5 in task-completed-gate.sh with baseline comparison (non-blocking warning for count decrease, blocking for zero tests)
4. Keep build-teammate-prompt.py changes minimal -- only add baseline info to prompt if present
