---
spec: quality-gates
phase: design
created: 2026-02-22
generated: auto
---

# Design: quality-gates

## Overview

Two parallel improvements: (A) add mandatory anti-pattern rules and Quality Commands requirement to the task-planner agent prompt, (B) add baseline test snapshot capture to the dispatch flow and regression comparison to the quality gate hook.

## Architecture

```
Improvement A (task-planner):
  task-planner.md
    ├── New: ## Verify Anti-Patterns (mandatory block)
    ├── Updated: ## Use Explore → MANDATORY not advisory
    └── New: ## Quality Commands Section Requirement

Improvement B (baseline snapshot):
  dispatch.md
    └── New: Step 4.5 — capture baseline test snapshot
  dispatch-state.json
    └── New field: baselineSnapshot { testCount, capturedAt, command, rawOutput }
  task-completed-gate.sh
    └── Updated: Stage 5 — parse_test_count() + baseline comparison
  build-teammate-prompt.py
    └── Updated: build_quality_section() — include baseline count info
```

## Components

### Component A: Task-Planner Verify Enforcement

**Purpose**: Prevent compile-only verify commands from being generated
**File**: `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md`

**Changes**:

1. **Anti-pattern `<mandatory>` block** (insert after line 281, after VERIFY section):
   ```markdown
   ## Verify Command Anti-Patterns
   <mandatory>
   NEVER use these as standalone Verify commands:
   - `cargo check` (compile-only, proves nothing works)
   - `tsc --noEmit` (type-check only, no runtime validation)
   - `go build` (compile-only)
   - `pnpm build` alone (build-only, no test)
   - `gcc`/`g++` alone (compile-only)

   ALWAYS use test runner commands:
   - `cargo test` (not cargo check)
   - `pnpm test` / `npm test` / `vitest run`
   - `pytest` / `python3 -m pytest`
   - `go test ./...`
   - `bash -n script.sh` for shell scripts
   - `python3 -c "import ast; ast.parse(open('file').read())"` for Python syntax

   Compile checks are SUPPLEMENTAL (run by the quality gate hook automatically).
   Verify must prove the code WORKS, not just compiles.
   </mandatory>
   ```

2. **Make Explore mandatory** (update lines 119-122):
   Change "Spawn Explore subagents to understand the codebase" to include:
   ```
   You MUST spawn at least one Explore subagent before writing any tasks.
   Skipping Explore results in guessed file paths and wrong verify commands.
   ```

3. **Quality Commands requirement** (insert after anti-patterns):
   ```markdown
   ## Quality Commands Section
   <mandatory>
   Every generated tasks.md MUST begin with a `## Quality Commands` section:
   ```markdown
   ## Quality Commands
   - **Build**: `<discovered build command or "N/A">`
   - **Typecheck**: `<discovered typecheck command or "N/A">`
   - **Test**: `<discovered test command or "N/A">`
   - **Lint**: `<discovered lint command or "N/A">`
   ```
   These are discovered by the Explore agent. parse-and-partition.py reads this section.
   </mandatory>
   ```

### Component B: Baseline Test Snapshot

**Purpose**: Capture pre-dispatch test count for regression detection

#### B1: dispatch.md Step 4.5

**File**: `commands/dispatch.md` (insert between Step 4 and Step 5)

```markdown
## Step 4.5: Capture Baseline Test Snapshot

Before creating the team, capture the current test suite state:

1. Read `qualityCommands.test` from the dispatch state just written
2. If no test command: skip, set baselineSnapshot to null
3. Run the test command, capture output
4. Parse test count using regex cascade:
   - jest/vitest: `Tests:\s+(\d+) passed`
   - pytest: `(\d+) passed`
   - cargo test: `test result:.*(\d+) passed`
   - go test: count `^ok\s+` lines
   - generic: count lines matching `pass|PASS|ok |✓`
5. If test command fails (pre-existing failures): set testCount to -1
6. If output unparseable: set testCount to -1
7. Update dispatch-state.json:
   ```json
   "baselineSnapshot": {
     "testCount": <int or -1>,
     "capturedAt": "<ISO timestamp>",
     "command": "<test command>",
     "exitCode": <int>
   }
   ```
```

#### B2: task-completed-gate.sh Stage 5 Enhancement

**File**: `hooks/scripts/task-completed-gate.sh`

**New function** `parse_test_count()`:
```bash
parse_test_count() {
  local output="$1"
  local count=-1

  # jest/vitest: "Tests:  42 passed"
  if echo "$output" | grep -qE 'Tests:\s+[0-9]+ passed'; then
    count=$(echo "$output" | grep -oE 'Tests:\s+([0-9]+) passed' | grep -oE '[0-9]+' | head -1)
  # pytest: "42 passed"
  elif echo "$output" | grep -qE '[0-9]+ passed'; then
    count=$(echo "$output" | grep -oE '([0-9]+) passed' | grep -oE '[0-9]+' | head -1)
  # cargo test: "test result: ok. 15 passed"
  elif echo "$output" | grep -qE 'test result:.*[0-9]+ passed'; then
    count=$(echo "$output" | grep -oE '([0-9]+) passed' | grep -oE '[0-9]+' | head -1)
  # go test: count "ok" lines
  elif echo "$output" | grep -qE '^ok\s+'; then
    count=$(echo "$output" | grep -cE '^ok\s+')
  # generic: count pass/ok/checkmark lines
  else
    count=$(echo "$output" | grep -ciE 'pass|ok |✓' || echo 0)
  fi

  echo "$count"
}
```

**Baseline comparison** (added to Stage 5 after test passes):
```bash
# After TEST_EXIT == 0:
BASELINE_COUNT=$(jq -r '.baselineSnapshot.testCount // -1' "$DISPATCH_STATE" 2>/dev/null || echo -1)
if [ "$BASELINE_COUNT" -gt 0 ]; then
  CURRENT_COUNT=$(parse_test_count "$TEST_OUTPUT")
  if [ "$CURRENT_COUNT" -gt 0 ] && [ "$CURRENT_COUNT" -lt "$((BASELINE_COUNT * 90 / 100))" ]; then
    echo "TEST COUNT REGRESSION: baseline=$BASELINE_COUNT, current=$CURRENT_COUNT (>10% drop)" >&2
    echo "Tests may have been deleted. Investigate before marking task complete." >&2
    exit 2
  fi
fi
```

#### B3: build-teammate-prompt.py Update

**File**: `scripts/build-teammate-prompt.py`

Minor addition to `build_quality_section()`: if baseline test count is provided, add a line:
```
Baseline test count: N tests passing at dispatch time. Do not delete tests.
```

This is informational only -- the hook enforces the gate.

## Data Flow

1. task-planner generates tasks.md with `## Quality Commands` section
2. parse-and-partition.py extracts quality commands into partition JSON
3. dispatch.md Step 4 writes quality commands to dispatch-state.json
4. dispatch.md Step 4.5 runs test command, parses count, stores baseline in dispatch-state.json
5. build-teammate-prompt.py includes baseline count in teammate prompt
6. Teammates execute tasks, mark complete
7. task-completed-gate.sh Stage 5 runs test, parses current count, compares to baseline

## Technical Decisions

| Decision | Options | Choice | Rationale |
|----------|---------|--------|-----------|
| Regression threshold | Fixed count vs percentage | >10% drop | Allows minor fluctuation from skipped/conditional tests |
| Unparseable baseline | Block vs skip | Skip (store -1) | Don't break dispatch for unknown test runners |
| Anti-pattern enforcement | Soft warning vs mandatory block | Mandatory block | task-planner respects `<mandatory>` tags strongly |
| Baseline storage | Separate file vs dispatch-state | dispatch-state.json | Single source of truth, already read by gate |

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` | Modify | Add anti-patterns, mandatory Explore, Quality Commands requirement |
| `commands/dispatch.md` | Modify | Add Step 4.5 baseline capture |
| `hooks/scripts/task-completed-gate.sh` | Modify | Add parse_test_count(), baseline comparison in Stage 5 |
| `scripts/build-teammate-prompt.py` | Modify | Add baseline info to quality section |

## Error Handling

| Error | Handling | User Impact |
|-------|----------|-------------|
| No test command in qualityCommands | Skip baseline capture, set null | No regression detection (graceful degradation) |
| Test command fails at baseline | Store testCount=-1 | Gate falls back to pass/fail only |
| Unparseable test output | Store testCount=-1 | Gate falls back to pass/fail only |
| Baseline missing from state | Skip comparison | Backward compatible with old dispatch states |

## Existing Patterns to Follow

- dispatch.md uses numbered Steps (Step 1, Step 2, ...) -- insert as Step 4.5
- task-completed-gate.sh uses numbered Stages with comments `# --- Stage N ---`
- task-planner.md uses `<mandatory>` blocks for critical rules
- dispatch-state.json uses flat JSON with nested qualityCommands object
