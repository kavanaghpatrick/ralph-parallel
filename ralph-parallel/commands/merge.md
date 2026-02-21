---
description: Integrate results from parallel Agent Teams execution
argument-hint: [spec-name] [--abort] [--continue]
allowed-tools: [Read, Write, Edit, Bash, Task, AskUserQuestion, Glob, Grep]
---

# Merge

Integrates results from parallel Agent Teams execution back into a cohesive state.

**Note**: For file-ownership strategy, this command is optional — it performs a consistency check only. Dispatch handles the full lifecycle including cleanup. Merge is required only for worktree strategy.

## Parse Arguments

From `$ARGUMENTS`, extract:
- **spec-name**: Optional spec name (defaults to active spec)
- **--abort**: Cancel merge, restore pre-dispatch state
- **--continue**: Continue a merge that was paused for conflict resolution

## Step 1: Load Dispatch State

```text
1. Resolve spec (same logic as dispatch.md Step 1)
2. Read specs/$specName/.dispatch-state.json
   - Error if missing: "No dispatch state found. Run /ralph-parallel:dispatch first."
3. Validate status field:
   - "dispatched" → proceed with merge
   - "merged" → "Already merged. Nothing to do."
   - "superseded" → "This dispatch was superseded by a newer one. Nothing to merge."
   - "merging" + no --continue → "Merge in progress. Use --continue to resume or --abort to cancel."
```

## Step 2: Verify Completion

Check that all dispatched groups have completed their work.

```text
Completion Check:

1. FOR EACH group in dispatch state:
   a. Check tasks.md — are all group's tasks marked [x]?
   b. Check git log — are expected commits present?
   c. If worktree strategy: check worktree branch exists and has commits

2. Report status:
   - All complete → proceed to merge
   - Partial → show which groups are incomplete:
     "Group 'api-layer': 2/3 tasks complete (missing: 1.4)"
     "Group 'data-layer': not started"
   - Ask user: "Some groups incomplete. Merge anyway? (partial results)"
```

## Step 3: File-Ownership Verification (Optional)

When strategy is `file-ownership`:

```text
File-Ownership Verification (consistency check — dispatch already completed execution):

Since all teammates worked in the same directory with file ownership,
there's no git merge needed. Instead, verify consistency:

1. CHECK: All owned files were only modified by their assigned teammate
   - For each group's ownedFiles:
     - git log --oneline -- $file (check commit authors/messages)
     - Verify commits come from expected group
   - If file modified by wrong group: WARN "File $file was modified by
     group '$other' but owned by '$owner'"

2. CHECK: No merge conflicts in working tree
   - git status --porcelain
   - If uncommitted changes: WARN and list them

3. CHECK: Build verification
   a. Read qualityCommands from .dispatch-state.json
   b. Run qualityCommands.build (if available)
   c. Run qualityCommands.test (if available)
   d. Run qualityCommands.lint (if available)
   e. Collect pass/fail per command
   f. If ANY fail: report specific failures with output, do NOT mark as merged

4. UPDATE: Mark dispatch as merged
   - Update .dispatch-state.json: status = "merged"
   - Update tasks.md: ensure all completed tasks marked [x]
   - Update .progress.md with parallel execution summary
   - Note: session-setup.sh will detect "merged" status and restore
     gc.auto on the next session start
```

## Step 4: Worktree Merge

When strategy is `worktree`:

```text
Worktree Integration:

1. CREATE integration branch:
   git checkout -b integrate/$specName

2. FOR EACH group (in dependency order):
   a. Merge group's branch:
      git merge parallel/$specName/$groupName --no-edit

   b. If conflict:
      - Show conflicting files
      - Attempt auto-resolution for simple conflicts
      - If unresolvable: pause merge
        - Update .dispatch-state.json: status = "merging",
          currentGroup = groupName, conflicts = [files]
        - Output: "Merge conflict in $files. Resolve manually then
          run /ralph-parallel:merge --continue"
        - STOP

   c. If clean merge:
      - Record in completedGroups
      - Continue to next group

3. AFTER all groups merged:
   a. Run full test suite (if configured)
   b. If tests pass: fast-forward main branch
   c. If tests fail: report failures, do NOT fast-forward

4. CLEANUP worktrees:
   FOR EACH group:
   - git worktree remove .worktrees/$groupName
   - git branch -d parallel/$specName/$groupName
   Restore gc: git config gc.auto 1
```

## Step 5: Pre-Merge Conflict Detection

Before attempting actual merges, use git's merge-tree for dry-run conflict detection.

```text
Pre-Merge Check (worktree strategy only):

FOR EACH pair of group branches:
  result=$(git merge-tree --write-tree branch-A branch-B 2>&1)

  If exit code != 0:
    - Parse conflicting files from output
    - Record: potentialConflicts[branchA:branchB] = [files]
    - Display warning before merge begins

This allows the user to see ALL potential conflicts upfront
rather than discovering them one at a time during merge.
```

## Step 6: Generate Summary

```text
Output Format:

Merge Summary for '$specName'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Strategy: $strategy
Groups merged: $count/$total

Results:
  Group 1 (api-layer): 3/3 tasks PASS
  Group 2 (ui-components): 3/3 tasks PASS
  Group 3 (data-layer): 2/2 tasks PASS

Verification:
  All verify commands: PASS
  Test suite: PASS (or N/A)
  File ownership violations: 0

Serial tasks remaining: 2 (1.7, 2.3)
Verify checkpoints remaining: 2 (1.8, 2.4)

Next: Run /ralph-specum:implement to execute remaining serial tasks.
```

## Abort

When `--abort` flag:

```text
Abort Merge:

1. If worktree strategy and merge in progress:
   - git merge --abort
   - git checkout original-branch
   - Do NOT remove worktrees (preserve work)

2. Reset dispatch state:
   - Update .dispatch-state.json: status = "dispatched"
   - Remove merging-specific fields

3. Output: "Merge aborted. Worktrees preserved. Re-run /ralph-parallel:merge when ready."
```

## Error Handling

| Error | Action |
|-------|--------|
| No dispatch state | "Run /ralph-parallel:dispatch first." |
| Groups incomplete | Show status, offer partial merge |
| Merge conflict | Pause, show files, wait for --continue |
| Tests fail after merge | Report failures, do NOT fast-forward |
| Worktree missing | "Worktree for group '$name' was removed. Cannot merge this group." |
