---
spec: parallel-qa-overhaul
phase: research
created: 2026-02-21
---

# Research: parallel-qa-overhaul

## Executive Summary

The ralph-parallel QA pipeline has 5 verification touchpoints that ALL reduce to static analysis (grep, tsc, ls) -- zero runtime verification. The gpu-metrics-operator spec proved this: 25 Phase 1 tasks all passed verification via grep for string patterns, yet the code has never been executed in a browser. The fix requires changes at 4 layers: task-planner agent (generate meaningful verify commands), teammate prompt (instruct test writing), per-task gate (add baseline checks beyond the verify command), and lead coordination loop (add runtime smoke test at merge checkpoint).

## External Research

### Best Practices from Industry

- **Multi-phase QA pipeline**: OpenObserve's "Council of Sub Agents" uses 6 phases (Analysis, Planning, Generation, Audit, Healing, Documentation). Key insight: a "Sentinel" agent blocks pipeline progression when quality issues detected. Source: [OpenObserve blog](https://openobserve.ai/blog/autonomous-qa-testing-ai-agents-claude-code/)
- **Iterative healing**: OpenObserve's Healer agent attempts up to 5 repair cycles per failing test, diagnosing selector, timing, and API issues. Reduced flaky tests by 85%. Source: same
- **Three-level safeguards**: CodeScene recommends automated checks at three checkpoints: continuous during generation, pre-commit, and PR pre-flight. Source: [CodeScene blog](https://codescene.com/blog/agentic-ai-coding-best-practice-patterns-for-speed-with-quality)
- **Coverage as behavioral gate**: Strict coverage gates on PRs make weakened behavioral checks immediately visible. Prevents agents from deleting tests to pass builds. Source: same
- **Anthropic's C compiler approach**: 16 agents, simple file locking, no orchestrator. Tests were the quality gate -- agents ran the full test suite and iterated. Source: [Anthropic engineering blog](https://www.anthropic.com/engineering/building-c-compiler)

### Prior Art: What Actually Catches Bugs

| Technique | Catches | Misses |
|-----------|---------|--------|
| `grep` for exports | Missing symbol names | Wrong behavior, type mismatches, runtime errors |
| `tsc --noEmit` | Type errors, missing imports | Runtime crashes, logic errors, integration failures |
| `vite build` | Bundle failures, missing deps | Runtime behavior, API contract violations |
| Unit tests | Logic errors in isolation | Integration failures, environment issues |
| Integration tests | Cross-module failures | Visual/UX issues, performance |
| Smoke test (runtime) | "Does it start?" | Deep logic errors |

### Pitfalls to Avoid

- **Grep-based verification is theater**: The gpu-metrics-operator tasks used `grep -c 'export' file | xargs test 8 -le` to "verify" a file. This confirms string presence, not correctness.
- **TypeCheck-only gates miss integration errors**: tsc confirms types match, but parallel groups can produce code that typechecks individually but fails to integrate (e.g., different assumptions about buffer layouts).
- **Mock-only tests**: The qa-engineer agent already has mock detection, but the task-planner never generates test-writing tasks for POC phase.

## Codebase Analysis

### Touchpoint 1: Task Planner (ralph-specum/agents/task-planner.md)

**Location**: `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md`

**What it says it does** (lines 9-41): Explicit mandate for E2E validation. Lists API integrations, analytics, browser extensions, auth flows as requiring real verification. States "If you can't verify end-to-end, the task list is incomplete."

**What it actually produces** (gpu-metrics-operator/tasks.md): 100% grep/ls/tsc verify commands. Every single verify command across 25 Phase 1 tasks is one of:
- `grep 'pattern' file` (17 tasks)
- `tsc --noEmit` (5 tasks -- all [VERIFY] checkpoints)
- `ls file1 file2 ...` (2 tasks)
- `vite build` (1 task)

**Root cause**: The task-planner has strong E2E principles but ZERO examples of how to translate them into verify commands for different project types. It also uses an Explore subagent to "discover test patterns" (line 131) but there's no enforcement that discovered patterns are used. The [VERIFY] task format (line 229-241) only mentions lint/typecheck/test commands -- no runtime smoke tests.

**Gap**: No guidance on what constitutes a meaningful verify command vs a useless one. No mandate that Phase 1 POC tasks must have at least ONE runtime verification step. No examples showing how to verify WebGPU, API, or browser projects without traditional test runners.

### Touchpoint 2: Teammate Prompts (build-teammate-prompt.py)

**Location**: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py`

**What it does**: Generates per-group prompts with tasks, file ownership, verify commands. The Rules section (line 95) says `implement -> verify -> commit -> mark [x]`.

**Gap**:
- No instruction to write tests. Teammates implement code and run the (grep-based) verify command.
- No baseline quality instruction like "ensure your code compiles before marking complete"
- No instruction to run project-level typecheck/build after each task
- The verify command is displayed as-is from tasks.md -- no augmentation or supplementary checks

### Touchpoint 3: Per-Task Gate (task-completed-gate.sh)

**Location**: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh`

**What it does**: TaskCompleted hook. Extracts spec task ID from subject, finds the verify command in tasks.md, runs it via `eval`. Blocks (exit 2) if command fails.

**Mechanism** (lines 93-118):
1. Parse tasks.md to find task block
2. Extract `**Verify**:` line
3. Run via `eval "$VERIFY_CMD" >/dev/null 2>&1`
4. Block on non-zero exit

**Gap**:
- Runs ONLY the verify command from tasks.md. If that's `grep`, then grep is all that runs.
- Suppresses all output (`>/dev/null 2>&1`), so even when blocking, the feedback is just "Verify command failed: grep ..." -- not helpful.
- No supplemental checks (e.g., always run typecheck after code changes)
- No check that files actually exist/were created
- No check that the task's `Files:` section files were actually modified
- Timeout is 120s (hooks.json) which is generous but could be insufficient for build+test

### Touchpoint 4: Group Checkpoints ([VERIFY] tasks in tasks.md)

**What they are**: Tasks tagged [VERIFY] that run between groups/phases. The task-planner generates these as `tsc --noEmit` or `lint && typecheck`.

**Gap**:
- Only typecheck. Never `build`. Never runtime test.
- The phase 1 merge checkpoint (task 1.21 in gpu-metrics) was just `tsc --noEmit` -- no build, no smoke test
- Cross-group integration issues (different buffer layouts, incompatible shader assumptions) caught only by typecheck, not by running the code

### Touchpoint 5: Merge/Final Checkpoint (dispatch.md lead coordination)

**Location**: `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` Step 7 (lead coordination loop)

**What it does**: Lead runs [VERIFY] tasks, executes serial tasks, does final cleanup.

**Gap**:
- No runtime smoke test anywhere in the lead loop
- No instruction to run `build` after all groups merge
- No instruction to verify the built artifact works (e.g., `vite build && ls dist/`)
- merge.md Step 3 says "re-run Verify commands" but those are all grep

### Additional Files

**parse-and-partition.py**: Handles partitioning. Extracts verify commands from tasks.md and passes them through to partition JSON. No filtering or quality check on verify command quality.

**file-ownership-guard.sh**: Blocks writes outside ownership. Works correctly for its purpose. Not relevant to QA improvements.

**session-setup.sh**: gc.auto management. Not relevant to QA improvements.

**dispatch-coordinator.sh**: Stop hook for lead context re-injection. Not relevant to QA improvements.

## Quality Commands (gpu-metrics-operator project)

| Type | Command | Source |
|------|---------|--------|
| TypeCheck | `npx tsc --noEmit` | package.json scripts.typecheck |
| Build | `npx vite build` | package.json scripts.build |
| Dev server | `npx vite` | package.json scripts.dev |
| Lint | Not found | - |
| Unit Test | Not found | - |
| Integration Test | Not found | - |
| E2E Test | Not found | - |

**Local CI**: `npx tsc --noEmit && npx vite build` (only available checks)

Note: This project has NO test runner, NO lint, NO test framework. The task-planner should have recognized this and generated verify commands using build verification + runtime smoke tests instead of grep.

## Feasibility Assessment

| Layer | Change | Effort | Risk | Impact |
|-------|--------|--------|------|--------|
| task-planner.md | Add verify command quality standards + examples | S | Low | HIGH -- root cause fix |
| task-planner.md | Require runtime verify for POC checkpoint | S | Low | HIGH -- ensures at least 1 real test |
| build-teammate-prompt.py | Add "run typecheck after each task" baseline | S | Low | Medium -- catches type drift |
| build-teammate-prompt.py | Add "write tests" instruction section | M | Medium | Medium -- depends on project having test infra |
| task-completed-gate.sh | Add supplemental typecheck/build after verify | M | Medium | HIGH -- catches real errors per-task |
| task-completed-gate.sh | Show verify command output on failure | S | Low | Medium -- better debugging |
| dispatch.md | Add build + smoke test at merge checkpoint | S | Low | HIGH -- final safety net |
| dispatch.md | Add runtime verify step after all groups complete | S | Low | HIGH -- integration testing |
| parse-and-partition.py | Extract quality commands from package.json | M | Low | Medium -- enables smart gate |

## Related Specs

| Spec | Relevance | mayNeedUpdate | Notes |
|------|-----------|---------------|-------|
| parallel-v2 | **HIGH** | No | Already implemented 1:1 task mapping, stall detection, abort. This spec builds on v2's infrastructure. |
| gpu-metrics-operator | **HIGH** | No | The failing case that exposed the QA gaps. Used as evidence/reference only. |
| git-worktrees-parallel-dev | **Low** | No | Research-only spec about git worktrees. Not affected. |
| api-dashboard | **Low** | No | Previous demo spec. Not affected by QA changes. |

## Recommendations for Requirements

### R1: Verify Command Quality Standards in task-planner.md (HIGH priority)

Add explicit rules to task-planner agent:
- **Banned patterns**: `grep` alone is NOT a valid verify command for implementation tasks (OK for config/doc tasks)
- **Required patterns**: At least one task per phase must run an actual build or test command
- **POC checkpoint**: MUST include a runtime verify (build, serve, curl, etc.), not just typecheck
- **Quality hierarchy**: build > test > typecheck > grep. Use the most meaningful check available.
- **Context-aware**: If no test runner exists, verify via build + runtime check (e.g., start server, hit endpoint, check output exists)

### R2: Supplemental Checks in task-completed-gate.sh (HIGH priority)

After running the task's verify command, add baseline checks:
1. **Always typecheck**: If `package.json` has a typecheck script, run it after every task completion
2. **File existence**: Verify the task's `Files:` entries exist
3. **Build check**: If 3+ tasks completed since last build, run build
4. The supplemental checks are configurable via a `.qa-config.json` in the spec directory

### R3: Teammate Prompt Enhancement (MEDIUM priority)

In `build-teammate-prompt.py`, add a new section to the generated prompt:
- "After EACH task, run typecheck: `{typecheck_cmd}`" (discovered from package.json/Makefile)
- "If a test runner exists, write at least one test per implementation task"
- "If typecheck fails after your changes, fix before marking task complete"

### R4: Merge Checkpoint Runtime Verify (HIGH priority)

In `dispatch.md` lead coordination loop, after all groups complete:
1. Run full build (not just typecheck)
2. If project has a dev server: start it, verify it responds (curl/WebFetch)
3. If project has tests: run full test suite
4. If build/tests fail: log failure, do NOT mark as complete, message teammates with errors

### R5: Quality Command Discovery (MEDIUM priority)

Create a discovery step in dispatch that:
1. Reads package.json scripts, Makefile targets, CI configs
2. Identifies available quality commands (lint, typecheck, test, build, e2e)
3. Stores them in `.dispatch-state.json` as `qualityCommands`
4. task-completed-gate.sh and teammate prompts use these discovered commands

### R6: Verify Command Output on Failure (LOW priority)

In `task-completed-gate.sh`, change:
```bash
eval "$VERIFY_CMD" >/dev/null 2>&1
```
to capture and display output on failure for better debugging.

## Open Questions

1. **task-planner scope**: The task-planner is in the `ralph-specum` plugin (separate from ralph-parallel). Changes to it affect ALL specs, not just parallel-dispatched ones. Is this OK, or should verify quality only be enforced in the parallel pipeline?

2. **WebGPU/browser projects**: For projects like gpu-metrics-operator where runtime testing requires a real browser with GPU support, what constitutes a meaningful verify? `vite build` is the best we can do without headless Chrome + WebGPU. Should the task-planner recognize these limitations and generate build-only verify commands instead of grep?

3. **Test writing mandate**: Should teammates be REQUIRED to write tests, or just instructed to write them if a test framework exists? Mandating tests when no test infra exists wastes effort. The current POC-first workflow explicitly skips tests in Phase 1.

4. **Supplemental check performance**: Running `tsc --noEmit` after every task completion adds 5-15 seconds per task. For a spec with 25 tasks across 4 parallel groups, this adds ~2-6 minutes total. Acceptable?

5. **qa-config.json scope**: Should quality configuration be per-spec or per-project? Per-spec allows customization; per-project avoids duplication.

## Sources

### External
- [OpenObserve: Autonomous QA Testing with AI Agents](https://openobserve.ai/blog/autonomous-qa-testing-ai-agents-claude-code/) -- Multi-phase pipeline, Sentinel quality gate, Healer iteration loop
- [CodeScene: Agentic AI Coding Best Practices](https://codescene.com/blog/agentic-ai-coding-best-practice-patterns-for-speed-with-quality) -- Three-level safeguards, coverage as behavioral gate
- [Anthropic: Building a C Compiler with Parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler) -- Test suite as primary quality gate for 16-agent team
- [Claude Code Agent Teams Docs](https://code.claude.com/docs/en/agent-teams) -- Official agent teams documentation

### Internal Files Analyzed
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/build-teammate-prompt.py` -- Teammate prompt generation
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/task-completed-gate.sh` -- Per-task quality gate
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` -- Lead coordination
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/scripts/parse-and-partition.py` -- Task parsing/partitioning
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/merge.md` -- Merge checkpoint
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/status.md` -- Status monitoring
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/templates/teammate-prompt.md` -- Prompt template reference
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/templates/team-prompt.md` -- Lead prompt reference
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/hooks.json` -- Hook registration
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/file-ownership-guard.sh` -- File ownership enforcement
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/dispatch-coordinator.sh` -- Stop hook
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/session-setup.sh` -- Session setup
- `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/task-planner.md` -- Task planning agent
- `~/.claude/plugins/cache/smart-ralph/ralph-specum/3.1.2/agents/qa-engineer.md` -- QA engineer agent
- `/Users/patrickkavanagh/parallel_ralph/specs/gpu-metrics-operator/tasks.md` -- Failing case evidence
- `/Users/patrickkavanagh/parallel_ralph/specs/gpu-metrics-operator/.progress.md` -- GPU metrics learnings
- `/Users/patrickkavanagh/parallel_ralph/specs/parallel-v2/requirements.md` -- v2 improvements (already shipped)
- `/Users/patrickkavanagh/parallel_ralph/specs/parallel-v2/tasks.md` -- v2 task structure
- `/Users/patrickkavanagh/parallel_ralph/specs/parallel-v2/.progress.md` -- v2 learnings
