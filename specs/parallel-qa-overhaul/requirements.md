# Requirements: Parallel QA Overhaul

## Goal

Make ralph-parallel's QA pipeline catch real bugs by replacing grep-based verification theater with runtime checks, supplemental quality gates, and test-writing instructions -- all within the parallel dispatch layer (no ralph-specum changes).

## User Stories

### US-1: Quality Command Discovery

**As a** dispatch lead
**I want** the dispatch pipeline to auto-detect available quality commands (typecheck, build, test, lint) from the project
**So that** per-task gates and teammate prompts use project-appropriate checks instead of hardcoded assumptions

**Acceptance Criteria:**
- [ ] AC-1.1: `parse-and-partition.py` discovers quality commands from `package.json` scripts, `Makefile` targets, `pyproject.toml`, and `Cargo.toml`
- [ ] AC-1.2: Discovered commands stored in partition JSON under `qualityCommands` key with fields: `typecheck`, `build`, `test`, `lint`, `dev` (each nullable)
- [ ] AC-1.3: Discovery runs once during Step 2 (partition), results flow to teammate prompts and task-completed-gate
- [ ] AC-1.4: Handles missing/empty config files gracefully -- no crash, just null values
- [ ] AC-1.5: Works for at least: Node.js (package.json), Python (pyproject.toml/Makefile), Rust (Cargo.toml)

### US-2: Teammate Prompt Test-Writing Instructions

**As a** teammate agent
**I want** my prompt to include instructions for running quality checks and writing tests
**So that** I catch errors during implementation instead of only at the (weak) verify step

**Acceptance Criteria:**
- [ ] AC-2.1: `build-teammate-prompt.py` accepts `--quality-commands` JSON argument
- [ ] AC-2.2: Generated prompt includes "Quality Checks" section with: "After EACH task, run: `{typecheck_cmd}`" (when typecheck available)
- [ ] AC-2.3: If a test runner exists, prompt includes: "Write at least one test per implementation task. Run `{test_cmd}` to verify."
- [ ] AC-2.4: If no test runner exists, prompt includes: "Verify your code compiles/builds: `{build_cmd}`" (when build available)
- [ ] AC-2.5: Prompt includes: "If typecheck/build fails after your changes, fix BEFORE marking task complete"
- [ ] AC-2.6: When no quality commands discovered, section reads: "Run any available project checks (build, lint, typecheck) after each task"

### US-3: Enhanced Per-Task Quality Gate

**As a** dispatch system
**I want** the task-completed gate to run supplemental checks beyond the task's verify command
**So that** type errors, build failures, and missing files are caught per-task instead of discovered at merge

**Acceptance Criteria:**
- [ ] AC-3.1: `task-completed-gate.sh` reads `qualityCommands` from `.dispatch-state.json`
- [ ] AC-3.2: After running the task's verify command, gate runs typecheck if available (always)
- [ ] AC-3.3: Gate verifies files listed in task's `Files:` section actually exist on disk
- [ ] AC-3.4: Gate runs build command every Nth task completion (N configurable, default 3) or on the last task in a group
- [ ] AC-3.5: On failure, gate outputs the ACTUAL error output (not suppressed) as feedback to the teammate via stderr
- [ ] AC-3.6: Supplemental check failures block task completion (exit 2) with actionable error message
- [ ] AC-3.7: Gate timeout increased from 120s to 300s in hooks.json to accommodate build commands

### US-4: Verify Output on Failure

**As a** teammate agent
**I want** to see actual error output when my verify command fails
**So that** I can fix the specific issue instead of guessing

**Acceptance Criteria:**
- [ ] AC-4.1: `task-completed-gate.sh` captures verify command stdout+stderr to a temp file
- [ ] AC-4.2: On verify success, output is discarded (no noise)
- [ ] AC-4.3: On verify failure, last 50 lines of output sent to stderr as feedback
- [ ] AC-4.4: Error message includes the failing command, exit code, and truncated output

### US-5: Merge Checkpoint Runtime Verification

**As a** dispatch lead
**I want** the merge/final checkpoint to include a full build and (if available) runtime smoke test
**So that** cross-group integration failures are caught before declaring dispatch complete

**Acceptance Criteria:**
- [ ] AC-5.1: `dispatch.md` Step 7 PHASE GATE sub-step runs full build (not just typecheck) after all phase tasks complete
- [ ] AC-5.2: If project has test command, lead runs full test suite at phase gate
- [ ] AC-5.3: If project has dev server command, lead starts it, verifies it responds (via curl or similar), then stops it
- [ ] AC-5.4: On build/test failure at merge checkpoint, lead messages affected teammates with error output and does NOT mark phase complete
- [ ] AC-5.5: `merge.md` Step 3 verification re-runs build (not just grep-based verify commands)

### US-6: Verify Command Quality Validation

**As a** dispatch system
**I want** `parse-and-partition.py` to flag weak verify commands during partition analysis
**So that** the lead is warned before dispatching tasks with grep-only verification

**Acceptance Criteria:**
- [ ] AC-6.1: Script classifies verify commands into tiers: `runtime` (build/test/serve), `static` (typecheck/lint), `weak` (grep/ls/cat/echo/true)
- [ ] AC-6.2: Partition output includes `verifyQuality` summary: count per tier
- [ ] AC-6.3: If >50% of tasks have `weak` verify commands, partition plan output includes a WARNING line
- [ ] AC-6.4: Warning suggests: "Consider adding build/test verify commands to tasks.md before dispatch"
- [ ] AC-6.5: Warning is informational only -- does NOT block dispatch

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | Quality command discovery from project config files | High | AC-1.1 through AC-1.5 |
| FR-2 | Quality commands stored in `.dispatch-state.json` | High | Readable by gate hook and teammate prompt builder |
| FR-3 | Teammate prompt includes quality check instructions | High | AC-2.1 through AC-2.6 |
| FR-4 | Teammate prompt includes test-writing guidance when test runner available | Medium | AC-2.3 |
| FR-5 | Per-task gate runs supplemental typecheck | High | AC-3.2 |
| FR-6 | Per-task gate verifies file existence | Medium | AC-3.3 |
| FR-7 | Per-task gate runs periodic build check | Medium | AC-3.4 |
| FR-8 | Verify failure output shown to teammate | High | AC-4.1 through AC-4.4 |
| FR-9 | Merge checkpoint runs full build | High | AC-5.1 |
| FR-10 | Merge checkpoint runs test suite when available | High | AC-5.2 |
| FR-11 | Merge checkpoint runtime smoke test (dev server) | Low | AC-5.3 |
| FR-12 | Verify command quality classification | Medium | AC-6.1 through AC-6.3 |
| FR-13 | Weak verify warning in partition plan | Medium | AC-6.4, AC-6.5 |
| FR-14 | Hook timeout increase for build-inclusive gates | High | AC-3.7 |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | Quality command discovery latency | Wall time | <2s for any project type |
| NFR-2 | Per-task gate overhead (typecheck only) | Added time per task | <15s average |
| NFR-3 | Per-task gate overhead (typecheck + build) | Added time per task | <60s average |
| NFR-4 | No false positives on file existence check | False block rate | 0% for tasks that correctly list their files |
| NFR-5 | Backward compatibility | Existing dispatches without qualityCommands | Gate falls back to verify-only behavior |

## Glossary

- **Verify command**: The `**Verify**:` field in tasks.md. Currently the ONLY check run by the per-task gate.
- **Supplemental check**: Additional quality check (typecheck, build, file existence) run by the gate AFTER the verify command.
- **Quality commands**: Project-specific commands (typecheck, build, test, lint, dev) discovered from config files.
- **Weak verify**: A verify command that only checks string/file presence (grep, ls, cat, echo, true). Does not validate behavior.
- **Runtime verify**: A verify command that actually executes code (build, test, serve, curl).
- **Per-task gate**: The TaskCompleted hook (`task-completed-gate.sh`) that blocks task completion on failure.
- **Merge checkpoint**: The lead coordination step in dispatch.md that runs after all teammate groups complete.

## Out of Scope

- Changes to `ralph-specum` plugin (task-planner.md, qa-engineer.md) -- separate plugin, separate spec
- Adding test frameworks to projects that lack them -- teammates work with what exists
- Headless browser / WebGPU runtime testing -- too complex for this iteration
- `.qa-config.json` per-spec configuration file -- unnecessary complexity; use discovered quality commands
- Worktree strategy changes -- file-ownership is the focus
- Coverage measurement or coverage gates
- Flaky test detection or retry loops

## Dependencies

- Existing `.dispatch-state.json` structure (written by dispatch.md Step 4) -- adding `qualityCommands` field
- `jq` available in shell (already used by task-completed-gate.sh)
- Project config files (package.json, etc.) present in project root at dispatch time

## Files Modified

| File | Changes |
|------|---------|
| `ralph-parallel/scripts/parse-and-partition.py` | Quality command discovery, verify quality classification, warning output |
| `ralph-parallel/scripts/build-teammate-prompt.py` | `--quality-commands` arg, "Quality Checks" section in generated prompt |
| `ralph-parallel/hooks/scripts/task-completed-gate.sh` | Supplemental checks, verify output capture, file existence check |
| `ralph-parallel/hooks/hooks.json` | TaskCompleted timeout 120 -> 300 |
| `ralph-parallel/commands/dispatch.md` | Pass quality commands to prompt builder, merge checkpoint runtime verify steps |
| `ralph-parallel/commands/merge.md` | Step 3 verification uses build instead of re-running grep verify commands |

## Unresolved Questions

1. **Build frequency in gate**: Running build after every 3rd task is arbitrary. Should it be configurable per-dispatch, or is a fixed default sufficient?
2. **Dev server smoke test reliability**: Starting/stopping a dev server in the lead loop is fragile (port conflicts, hang on shutdown). Worth the complexity?
3. **Typecheck in non-JS projects**: For Python projects, the equivalent (mypy/pyright) can be slow. Should there be a timeout threshold that skips supplemental checks?

## Success Criteria

- A dispatch of a fresh spec with no test runner (like gpu-metrics-operator) produces teammates that run `build` after each task and lead runs full build at merge checkpoint
- Weak verify commands (grep/ls) trigger a visible WARNING in the partition plan
- Verify failures show actual error output instead of just "Verify command failed"
- Per-task gate catches type errors introduced by a teammate before the task is marked complete
- Zero regression in existing dispatch behavior when `qualityCommands` is absent (backward compat)

## Next Steps

1. Approve requirements (user review)
2. Generate tasks from these requirements
3. Dispatch tasks for parallel implementation
