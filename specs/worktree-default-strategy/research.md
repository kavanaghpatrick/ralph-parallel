---
spec: worktree-default-strategy
phase: research
created: 2026-03-12
---

# Research: worktree-default-strategy

## Executive Summary

Changing the default strategy from `file-ownership` to `worktree` is technically feasible and touches ~15 files. The main risk is a **fundamental conflict** between ralph-parallel's documented worktree setup (`git worktree add ... -b parallel/$specName/$groupName`) and how Claude Code's `isolation: "worktree"` *actually* works -- it auto-generates branches as `worktree-agent-{hash}` with no custom naming support (upstream feature request #27749 is still open). The integration branch idea is sound but must account for this branch-naming gap.

## External Research

### How Claude Code `isolation: "worktree"` Actually Works

| Aspect | Behavior | Source |
|--------|----------|--------|
| Branch naming | Auto-generated as `worktree-agent-{hash}` | [Issue #27749](https://github.com/anthropics/claude-code/issues/27749) |
| Custom branch names | **NOT supported** -- feature request #27749 still open | [Issue #27749](https://github.com/anthropics/claude-code/issues/27749) |
| Custom worktree paths | **NOT supported** | [Issue #27749](https://github.com/anthropics/claude-code/issues/27749) |
| Cleanup | Worktrees with no changes auto-removed; changes persist | [Agent Teams docs](https://code.claude.com/docs/en/agent-teams) |
| Background teammates | Known bug: `pwd` may still point to main repo | [Issue #27749](https://github.com/anthropics/claude-code/issues/27749) |

**Critical finding**: dispatch.md line 324 documents `git worktree add .worktrees/$groupName -b parallel/$specName/$groupName` and merge.md line 122 references `parallel/$specName/$groupName` branches. But when the Task tool's `isolation: "worktree"` creates the worktree, it uses its own `worktree-agent-{hash}` naming. These two mechanisms are in conflict.

**Implication**: Either (a) ralph-parallel manually creates worktrees BEFORE spawning teammates (the Task tool then just uses the existing worktree), or (b) the documented `parallel/$specName/$groupName` naming never actually worked as written, and merge.md needs to discover branches by some other mechanism.

### Integration Branch Best Practices

- Create integration branch from base (main/develop) before spawning workers
- Each worker branches from integration, not from main
- Workers merge back to integration, not main
- Integration branch gets tested, then merged to main via PR
- Source: [Git worktree parallel workflows](https://elchemista.com/en/post/how-to-leverage-git-trees-for-parallel-agent-workflows)

### Pitfalls to Avoid

1. **Don't assume custom branch names work** -- Claude Code's Task tool doesn't support them yet
2. **gc.auto=0 is already handled** -- session-setup.sh manages this correctly
3. **Worktree cleanup timing matters** -- if merge.md tries to access worktrees that Claude Code already auto-cleaned, it will fail

## Codebase Analysis

### Current Architecture: file-ownership Strategy (End-to-End)

```
dispatch.md:
  1. Parse tasks.md
  2. parse-and-partition.py --strategy file-ownership
     -> _build_groups_automatic(): partition by file overlap, serialize conflicts
  3. write-dispatch-state.py --strategy file-ownership
  4. Task tool spawn WITHOUT isolation: "worktree"
     -> All teammates work in same directory, same branch
  5. file-ownership-guard.sh blocks cross-ownership writes (PreToolUse hook)
  6. Coordinator marks status="merged" on completion (no /merge needed)
```

### Current Architecture: worktree Strategy (End-to-End)

```
dispatch.md:
  1. Parse tasks.md
  2. parse-and-partition.py --strategy worktree
     -> _build_groups_worktree(): round-robin load balance, no file conflict checks
     -> Returns [] serial tasks (worktree eliminates file conflicts)
  3. write-dispatch-state.py --strategy worktree
  4. Task tool spawn WITH isolation: "worktree"
     -> Claude Code creates worktree-agent-{hash} branches (NOT parallel/$specName/$groupName)
  5. file-ownership-guard.sh still runs but is a no-op (no ownership violations possible)
  6. Coordinator leaves status="dispatched" (needs /merge)

merge.md:
  1. Verify all groups complete
  2. Pre-merge conflict detection: git merge-tree between branch pairs
  3. Create integrate/$specName branch
  4. Merge each parallel/$specName/$groupName branch (in dependency order)
     ^^^ THIS ASSUMES KNOWN BRANCH NAMES -- conflicts with worktree-agent-{hash}
  5. Run test suite
  6. Cleanup: git worktree remove, git branch -d
```

### All Files Referencing Strategy

| File | What it does with strategy | Line(s) |
|------|---------------------------|---------|
| `commands/dispatch.md` | Default `file-ownership` in arg parsing; controls Task tool `isolation` param | 3, 16, 65, 86, 97, 185, 194-196, 317-325 |
| `commands/merge.md` | Branches strategy into file-ownership verify vs worktree merge | 11, 44, 56, 96, 112, 143-147, 184 |
| `commands/status.md` | Display strategy name; next-step advice differs | 77, 103-104, 129 |
| `scripts/parse-and-partition.py` | `--strategy` arg (default `file-ownership`); chooses `_build_groups_worktree` vs `_build_groups_automatic`; `format_plan()` display | 6, 678, 701-706, 808-830, 1038, 1175 |
| `scripts/build-teammate-prompt.py` | `--strategy` arg (default `file-ownership`); `is_worktree` controls file ownership section | 119, 143, 192-207, 268-269 |
| `scripts/write-dispatch-state.py` | `--strategy` arg (choices validation); stored in state | 8, 98, 115-117 |
| `hooks/scripts/file-ownership-guard.sh` | Only enforces for file-ownership (no strategy check -- always runs, but worktree teammates have full ownership) | Entire file |
| `hooks/scripts/session-setup.sh` | Reads strategy from dispatch state; displays in status | 110 |
| `hooks/scripts/dispatch-coordinator.sh` | No strategy-specific logic | - |
| `hooks/scripts/task-completed-gate.sh` | No strategy-specific logic | - |
| `hooks/scripts/teammate-idle-gate.sh` | No strategy-specific logic | - |
| `hooks/scripts/merge-guard.sh` | No strategy-specific logic | - |
| `skills/parallel-workflow/SKILL.md` | Documents both strategies, tips say "start with file-ownership" | 37-48, 140, 162-163, 204, 293, 316, 345 |
| `templates/teammate-prompt.md` | References file-ownership enforcement | 22 |
| `templates/team-prompt.md` | State transitions differ by strategy | 36-37 |
| `scripts/test_build_teammate_prompt.py` | Tests for both strategies | 109-130 |
| `scripts/test_parse_and_partition.py` | Tests worktree partitioning | 361, 386 |
| `scripts/test_write_dispatch_state.py` | Tests strategy passthrough | 43, 48, 112, 235-240 |

### Key Difference in Partitioning

| Aspect | file-ownership | worktree |
|--------|---------------|----------|
| Partitioner | `_build_groups_automatic()` | `_build_groups_worktree()` |
| File conflict handling | Serialize overlapping tasks | Ignore (each has own copy) |
| Serial tasks | Tasks touching files owned by 2+ groups | **None** -- all tasks are parallelized |
| Group assignment | By file ownership (greedy bin packing) | Round-robin load balance |
| Pre-defined groups | Respected (with conflict resolution) | **Also respected** (predefined check runs first, line 696-700) |

### Dispatch Cleanup Behavior

| Strategy | Dispatch completion | Status set to |
|----------|-------------------|---------------|
| file-ownership | Coordinator marks "merged" directly | "merged" |
| worktree | Coordinator leaves as "dispatched" | "dispatched" (needs /merge) |

Source: dispatch.md Step 7 items 7c and 7d.

## Critical Gap: Branch Name Mismatch

**This is the biggest risk in the entire change.**

dispatch.md says:
```
git worktree add .worktrees/$groupName -b parallel/$specName/$groupName
```

merge.md says:
```
git merge parallel/$specName/$groupName --no-edit
```

But Claude Code's `isolation: "worktree"` creates:
```
worktree-agent-{random-hash}
```

**Two possible realities**:

1. **ralph-parallel was always intended to create worktrees manually** (before spawning teammates), and the Task tool's `isolation: "worktree"` just means "run this agent in the already-created worktree." This would mean dispatch.md needs a Step 5.5 that creates worktrees manually.

2. **The worktree strategy has never actually been tested end-to-end**, and the documented branch naming is aspirational. The Task tool creates its own branches, and merge.md would need to discover them (e.g., `git branch --list "worktree-agent-*"`).

**Recommendation**: Adopt approach (1). Have dispatch create the worktrees and branches manually with known names, then either:
- (a) Pass the worktree path to the Task tool so it runs in that directory (if `worktree_path` gets implemented per #27749), OR
- (b) Don't use `isolation: "worktree"` at all -- instead spawn teammates with a prompt that says "cd to /path/to/.worktrees/$groupName" and set their cwd.

Until #27749 lands, option (b) is the only reliable approach.

## Impact Assessment: Changing Default to `worktree`

### What Changes

| Change | Risk | Notes |
|--------|------|-------|
| `dispatch.md` line 16: default `worktree` | Low | Arg parsing change |
| `parse-and-partition.py` line 1175: default `worktree` | Low | Arg default change |
| `build-teammate-prompt.py` line 268: default `worktree` | Low | Arg default change |
| `write-dispatch-state.py`: no default needed (required arg) | None | Strategy comes from dispatch |
| `dispatch.md` Step 6 isolation logic (line 194-196): flip default | Medium | Must now set `isolation: "worktree"` by default |
| `dispatch.md` Step 7 cleanup (line 233-234): flip default | Low | Leave as "dispatched" by default |
| `skills/SKILL.md`: update docs, tips | Low | Documentation |
| `status.md`: update next-step advice | Low | Documentation |
| `templates/`: update references | Low | Documentation |
| Tests: update default strategy expectations | Low | 3 test files |

### What Breaks

1. **Users who relied on implicit file-ownership behavior** -- dispatching without `--strategy` will now create worktrees instead of sharing a directory. This is **intentional** and the whole point of the change.

2. **file-ownership-guard.sh becomes dead code for default dispatches** -- still runs but never triggers because worktree teammates don't share files. Not broken, just wasteful.

3. **Merge step now required by default** -- users who never ran `/merge` will need to. The coordinator's cleanup path changes from "set merged" to "leave as dispatched, tell user to merge."

4. **The branch-name mismatch problem** (see Critical Gap above) -- merge.md assumes known branch names that Claude Code doesn't actually create.

### What Doesn't Break

- `--strategy file-ownership` explicit flag still works
- All hooks work identically (no strategy-specific logic in hooks except guard)
- Quality gates are strategy-agnostic
- Pre-defined groups work with both strategies

## Integration Branch Proposal

### Current Merge Target

merge.md Step 5 line 117-118:
```
1. CREATE integration branch:
   git checkout -b integrate/$specName
```

The integration branch **already exists in merge.md** but is created at merge time, not dispatch time. The proposal is to:

1. Create `feat/$specName` at dispatch time (Step 4.5 in dispatch.md)
2. Have worktree branches fork from this integration branch
3. Have merge.md target this branch instead of creating `integrate/$specName`

### Proposed Flow

```
dispatch.md:
  Step 4.5: git checkout -b feat/$specName  (or use current branch if already on feat/*)
  Step 5.5: FOR EACH group:
    git worktree add .worktrees/$groupName feat/$specName -b parallel/$specName/$groupName
  Step 6: Spawn teammates with cwd=.worktrees/$groupName (no isolation: "worktree")

merge.md:
  Step 3: git checkout feat/$specName
  Step 5: FOR EACH group:
    git merge parallel/$specName/$groupName --no-edit
  Cleanup: git worktree remove, git branch -d parallel/*
  Result: feat/$specName has all merged work, ready for PR to main
```

### Changes Required for Integration Branch

| File | Change |
|------|--------|
| `commands/dispatch.md` | Add Step 4.5 (create feat/$specName branch), Step 5.5 (create worktrees) |
| `commands/merge.md` | Change Step 5 to checkout feat/$specName (not create integrate/$specName) |
| `scripts/write-dispatch-state.py` | Add `integrationBranch` field to state |
| `commands/status.md` | Show integration branch name |
| `skills/parallel-workflow/SKILL.md` | Document new flow |

### Edge Cases

1. **feat/$specName already exists** -- check and use it (user may have started work before dispatch)
2. **User is already on a feature branch** -- use that branch as integration branch, store in state
3. **Multiple dispatches for same spec** -- supersede handling already works; integration branch persists
4. **abort during dispatch** -- need to clean up integration branch (or leave it, since it has no harm)

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All code paths exist, changes are well-isolated |
| Effort Estimate | M | ~15 files to modify, branch-naming gap is the hard part |
| Risk Level | Medium | Branch-naming mismatch requires workaround until #27749 lands |

## Related Specs

| Spec | Relevance | mayNeedUpdate |
|------|-----------|---------------|
| `audit-fixes-v2` | Medium -- security/reliability fixes to same codebase. No conflicts; that spec fixes eval/race conditions, this spec changes strategy defaults. | false |

## Quality Commands

| Type | Command | Source |
|------|---------|--------|
| Unit Test | `python3 -m pytest plugins/ralph-parallel/scripts/` | test_*.py files |
| Build | Not found | - |
| Lint | Not found | - |
| TypeCheck | Not found | - |
| E2E Test | Not found | - |

**Local CI**: `cd /Users/patrickkavanagh/ralph-parallel-marketplace && python3 -m pytest plugins/ralph-parallel/scripts/ -q`

## Recommendations

1. **Change defaults in 3 files**: dispatch.md (arg hint + default), parse-and-partition.py (argparse default), build-teammate-prompt.py (argparse default). Low risk.

2. **Do NOT use Claude Code's `isolation: "worktree"` parameter**. Instead, have dispatch.md manually create worktrees with known branch names (`parallel/$specName/$groupName`), then spawn teammates with their cwd pointed to the worktree directory. This sidesteps the `worktree-agent-{hash}` naming problem entirely.

3. **Add integration branch creation to dispatch.md** as Step 4.5:
   - If current branch matches `feat/*` or `feature/*`, use it as integration branch
   - Otherwise create `feat/$specName` from HEAD
   - Store in dispatch-state.json as `integrationBranch`
   - Worktrees branch from this: `git worktree add .worktrees/$groupName -b parallel/$specName/$groupName feat/$specName`

4. **Update merge.md** to checkout the stored `integrationBranch` instead of creating `integrate/$specName`. This is simpler (branch already exists) and preserves any pre-dispatch commits on the feature branch.

5. **Add `integrationBranch` field to dispatch-state.json** via write-dispatch-state.py. merge.md reads this to know where to merge.

6. **Update SKILL.md** to make worktree the recommended/default strategy, keeping file-ownership as the fallback for simple cases.

7. **Keep file-ownership-guard.sh active** even for worktree dispatches -- it's a no-op in practice (worktree teammates can't violate ownership since they have their own copy) and removing it risks breaking file-ownership fallback.

8. **Write tests** for the new integration branch flow: test that write-dispatch-state.py accepts and stores `integrationBranch`, test that worktree partitioning produces zero serial tasks.

## Open Questions

1. **Should dispatch auto-detect when to use worktree vs file-ownership?** E.g., if all tasks touch disjoint files, file-ownership is simpler. If there are overlaps, auto-upgrade to worktree. This could be a `--strategy auto` option.

2. **What if the user wants to merge to a different branch than feat/$specName?** Should we support a `--target-branch` flag on dispatch?

3. **How to handle the case where Claude Code eventually supports custom branch names (#27749)?** Should we plan for a migration path, or just use the manual worktree approach permanently?

4. **Should `/merge` auto-create a PR from feat/$specName to main?** This would complete the integration branch workflow.

## Sources

- [Claude Code Agent Teams docs](https://code.claude.com/docs/en/agent-teams)
- [Claude Code Issue #27749: Custom worktree branch names](https://github.com/anthropics/claude-code/issues/27749)
- [Claude Code Issue #31969: Enter/resume worktrees, configurable naming](https://github.com/anthropics/claude-code/issues/31969)
- [Git worktree parallel agent workflows](https://elchemista.com/en/post/how-to-leverage-git-trees-for-parallel-agent-workflows)
- [Claude Code worktree guide](https://claudelab.net/en/articles/claude-code/worktree-guide)
- Plugin source: `/Users/patrickkavanagh/ralph-parallel-marketplace/plugins/ralph-parallel/`
- dispatch.md, merge.md, parse-and-partition.py, build-teammate-prompt.py, write-dispatch-state.py
- hooks: file-ownership-guard.sh, session-setup.sh, dispatch-coordinator.sh, task-completed-gate.sh
- tests: test_parse_and_partition.py, test_build_teammate_prompt.py, test_write_dispatch_state.py
