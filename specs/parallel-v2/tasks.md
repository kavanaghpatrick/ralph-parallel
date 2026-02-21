---
spec: parallel-v2
phase: tasks
total_tasks: 20
created: 2026-02-21
generated: auto
---

# Tasks: parallel-v2

## Phase 1: Make It Work (POC)

Focus: Implement all 11 improvements directly. These are markdown/script edits — no build step needed.

- [x] 1.1 Rewrite dispatch.md Step 7 for 1:1 TaskList tasks
  - **Do**: In `commands/dispatch.md`, replace Step 7 "Create Team and Spawn Teammates" section. Change from creating "one task per group" to creating one TaskList task per spec task. Each TaskList task subject must start with the spec task ID: `"X.Y: description"`. Group tasks by owner (group name). Update the teammate prompt construction to list individual TaskList task IDs. Teammates should claim each task as they start it (not one group-level task).
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Step 7 creates individual TaskList tasks with spec task IDs in subjects, teammate prompts reference individual task IDs
  - **Verify**: `grep -c "one TaskList task per spec task\|individual TaskList" ralph-parallel/commands/dispatch.md` returns >= 1
  - **Commit**: `fix(dispatch): create 1:1 TaskList tasks instead of per-group`
  - _Requirements: FR-1, FR-3_
  - _Design: Component 1_

- [x] 1.2 Simplify task-completed-gate.sh for direct task ID extraction
  - **Do**: In `hooks/scripts/task-completed-gate.sh`, replace lines 76-105 (the "Determine which spec task was just completed" section). Instead of regex-extracting from group subject/description, parse spec task ID directly from TASK_SUBJECT: `COMPLETED_SPEC_TASK=$(echo "$TASK_SUBJECT" | grep -oE '^[0-9]+\.[0-9]+')`. Remove the multi-strategy fallback logic. Keep the `if [ -z "$COMPLETED_SPEC_TASK" ]` guard that allows through.
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Lines 76-105 replaced with ~5 lines that extract task ID from start of TASK_SUBJECT
  - **Verify**: `grep -c "grep -oE '^\[0-9\]" ralph-parallel/hooks/scripts/task-completed-gate.sh` returns >= 1 AND `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh` exits 0
  - **Commit**: `fix(hooks): simplify task ID extraction in completed gate`
  - _Requirements: FR-2_
  - _Design: Component 1_

- [x] 1.3 Update teammate-prompt.md for 1:1 task references
  - **Do**: In `templates/teammate-prompt.md`, update "Key Fields Per Teammate" table. Change TaskList ID row from single ID to list of individual IDs. Update section 1 "Identity and Assignment" to say teammate claims each task individually via TaskUpdate as they start it. Update section 4 to say "mark each TaskList task as completed when its spec task is done."
  - **Files**: `ralph-parallel/templates/teammate-prompt.md`
  - **Done when**: Template reflects individual task claiming and completion
  - **Verify**: `grep -c "individual\|each task" ralph-parallel/templates/teammate-prompt.md` returns >= 2
  - **Commit**: `fix(templates): update teammate prompt for 1:1 task mapping`
  - _Requirements: FR-3_
  - _Design: Component 1_

- [x] 1.4 Add completedGroups update to dispatch.md Step 8
  - **Do**: In `commands/dispatch.md` Step 8 "Lead Coordination Loop", add a new substep after monitoring teammate messages. Add: "TRACK GROUP COMPLETION: When a teammate reports all their tasks are done, or when TaskList shows all tasks owned by a group are completed: (a) add group name to completedGroups in .dispatch-state.json, (b) write updated state file." Insert between current items 1 (MONITOR) and 2 (PHASE GATE).
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Step 8 has explicit completedGroups update instruction
  - **Verify**: `grep -c "completedGroups" ralph-parallel/commands/dispatch.md` returns >= 3 (initial write + update logic + cleanup)
  - **Commit**: `fix(dispatch): add completedGroups tracking in lead loop`
  - _Requirements: FR-4_
  - _Design: Component 2_

- [x] 1.5 Add stall/timeout handling to dispatch.md Step 8
  - **Do**: In `commands/dispatch.md` Step 8, add a new section "STALL DETECTION" after the TRACK GROUP COMPLETION substep. Include: (1) If no message from a teammate for 10+ minutes, send status check message. (2) Wait 5 more minutes. (3) If still no response, mark as stalled — options: reassign tasks to self or another teammate, or shut down and serialize. (4) Log stall event in .dispatch-state.json with timestamp and teammate name.
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Step 8 has STALL DETECTION section with 10-minute threshold and recovery actions
  - **Verify**: `grep -c "STALL DETECTION\|10 minutes\|stalled" ralph-parallel/commands/dispatch.md` returns >= 2
  - **Commit**: `fix(dispatch): add stall/timeout handling for stuck teammates`
  - _Requirements: FR-5_
  - _Design: Component 3_

- [x] 1.6 Add phase metadata to verifyTasks in dispatch.md Step 6
  - **Do**: In `commands/dispatch.md` Step 6 "Write Dispatch State", change the verifyTasks field from flat array `["1.8", "2.4"]` to array of objects `[{"id": "1.8", "phase": 1}, {"id": "2.4", "phase": 2}]`. Also update the Step 8 PHASE GATE section to reference the phase field when deciding which verify to run. Update the Partition Result JSON example in Step 4 to show the new format.
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: verifyTasks examples show object format with phase field, Step 8 references phase
  - **Verify**: `grep -c '"phase":' ralph-parallel/commands/dispatch.md` returns >= 2
  - **Commit**: `fix(dispatch): add phase metadata to verifyTasks`
  - _Requirements: FR-6_
  - _Design: Component 4_

- [x] 1.7 Rewrite status.md Step 2 for TaskList-first progress
  - **Do**: In `commands/status.md`, rewrite Step 2 "Compute Progress". Make TaskList the primary source: (1) Query TaskList for all tasks, (2) group by owner to get per-group progress, (3) use task status (pending/in_progress/completed) for accurate counts. Move git log to secondary: only for "Current activity" display line. Also handle both old (string array) and new (object array) verifyTasks formats.
  - **Files**: `ralph-parallel/commands/status.md`
  - **Done when**: Step 2 queries TaskList first, git log is secondary
  - **Verify**: `grep -c "TaskList" ralph-parallel/commands/status.md` returns >= 3
  - **Commit**: `fix(status): use TaskList as primary progress source`
  - _Requirements: FR-7_
  - _Design: Component 5_

- [x] 1.8 Clarify file-ownership vs worktree merge flow
  - **Do**: (1) In `commands/dispatch.md` Step 8 CLEANUP section, add note: "For file-ownership strategy, dispatch handles the full lifecycle. No /merge step needed." (2) In `commands/merge.md`, add after intro paragraph: "**Note**: For file-ownership strategy, this command is optional (consistency check). Dispatch handles full lifecycle including cleanup. Merge is required only for worktree strategy." (3) In `skills/parallel-workflow/SKILL.md`, update workflow step 5 to: "Integrate results: /ralph-parallel:merge (worktree strategy only; file-ownership completes in dispatch)". (4) In merge.md Step 3 header, change "File-Ownership Merge" to "File-Ownership Verification (Optional)".
  - **Files**: `ralph-parallel/commands/dispatch.md`, `ralph-parallel/commands/merge.md`, `ralph-parallel/skills/parallel-workflow/SKILL.md`
  - **Done when**: All three files clarify that /merge is optional for file-ownership
  - **Verify**: `grep -c "optional\|not needed\|worktree strategy only" ralph-parallel/commands/dispatch.md ralph-parallel/commands/merge.md ralph-parallel/skills/parallel-workflow/SKILL.md` returns >= 3
  - **Commit**: `docs(parallel): clarify file-ownership vs worktree merge flow`
  - _Requirements: FR-8_
  - _Design: Component 6_

- [x] 1.9 Add dispatch --abort handler
  - **Do**: In `commands/dispatch.md`, add a new section "## Abort Handler" after Step 8. When `--abort` flag is present: (1) Read .dispatch-state.json — error if missing or status != "dispatched". (2) Read team config `~/.claude/teams/$specName-parallel/config.json` for active teammates. (3) Send shutdown_request to each teammate via SendMessage. (4) Wait up to 30s for confirmations. (5) Delete team via TeamDelete. (6) Update .dispatch-state.json: status = "aborted", abortedAt = ISO timestamp. (7) Output abort summary. Also update Parse Arguments to list --abort flag.
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Abort handler section exists with shutdown/cleanup logic
  - **Verify**: `grep -c "\-\-abort\|Abort Handler\|aborted" ralph-parallel/commands/dispatch.md` returns >= 3
  - **Commit**: `feat(dispatch): add --abort flag for clean dispatch cancellation`
  - _Requirements: FR-9_
  - _Design: Component 7_

- [x] 1.10 Define partition rebalancing algorithm
  - **Do**: In `commands/dispatch.md` Step 4, replace the vague "Try to redistribute non-conflicting tasks" with a concrete algorithm: (1) Compute maxTasks and minTasks across groups. (2) While maxTasks > 2 * minTasks: (a) Pick last task in largest group. (b) Check if its files conflict with smallest group's files. (c) If no conflict: move task, update fileOwnership, recompute. (d) If conflict: skip, try next task. (e) Stop when balanced or no more moves possible. (3) Output: "Rebalanced: moved N tasks" or "No rebalancing possible (file conflicts)."
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Step 4 BALANCE CHECK has concrete move algorithm
  - **Verify**: `grep -c "maxTasks\|minTasks\|rebalance" ralph-parallel/commands/dispatch.md` returns >= 2
  - **Commit**: `fix(dispatch): define concrete partition rebalancing algorithm`
  - _Requirements: FR-10_
  - _Design: Component 8_

- [x] 1.11 Add optional file ownership enforcement guidance
  - **Do**: In `commands/dispatch.md`, add a new section "## Optional: Real-Time File Ownership Enforcement" after the Abort Handler. Describe an optional PreToolUse:Write hook that: (1) reads dispatch-state.json to find the teammate's group, (2) checks if the write target file is in the group's ownedFiles, (3) blocks with exit 2 if not owned. Note this is guidance only — not enabled by default. Also mention in `hooks/hooks.json` as a comment (JSON doesn't support comments, so add a "notes" field in the description).
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Section describes optional PreToolUse:Write enforcement
  - **Verify**: `grep -c "PreToolUse\|file ownership enforcement\|optional" ralph-parallel/commands/dispatch.md` returns >= 2
  - **Commit**: `docs(dispatch): add optional file ownership enforcement guidance`
  - _Requirements: FR-11_
  - _Design: Component 9_

- [x] 1.12 Add --watch mode to status.md
  - **Do**: In `commands/status.md`, add --watch to Parse Arguments section. Add new section "## Watch Mode" after Step 3. When --watch flag: (1) Run normal status display. (2) Instruct: "Re-check TaskList every 30 seconds and display updated status." (3) Continue until all tasks completed or user interrupts. (4) On completion: "All tasks complete. Watch mode ended."
  - **Files**: `ralph-parallel/commands/status.md`
  - **Done when**: --watch flag documented with 30s refresh and exit conditions
  - **Verify**: `grep -c "\-\-watch\|Watch Mode\|30 seconds" ralph-parallel/commands/status.md` returns >= 2
  - **Commit**: `feat(status): add --watch mode for live monitoring`
  - _Requirements: FR-12_
  - _Design: Component 10_

- [x] 1.13 Add end-to-end worked example to SKILL.md
  - **Do**: In `skills/parallel-workflow/SKILL.md`, add "## Worked Example" section before "## Tips". Show a concrete example: (1) A spec "todo-api" with 3 tasks: 1.1 create model (model.ts), 1.2 create handler (handler.ts), 1.3 add tests (test.ts). (2) Dispatch partitions into 2 groups: backend (1.1, 1.2) and testing (1.3 depends on backend). (3) Show partition plan output. (4) Show teammate completion messages. (5) Show final status output. Keep it concise — 40-60 lines max.
  - **Files**: `ralph-parallel/skills/parallel-workflow/SKILL.md`
  - **Done when**: Worked example section shows full dispatch flow
  - **Verify**: `grep -c "Worked Example\|todo-api\|partition" ralph-parallel/skills/parallel-workflow/SKILL.md` returns >= 2
  - **Commit**: `docs(skill): add end-to-end worked example`
  - _Requirements: FR-13_
  - _Design: Component 11_

- [x] 1.14 POC Checkpoint
  - **Do**: Review all 11 improvements are implemented. Check each file for consistency. Verify no broken markdown formatting. Ensure dispatch.md Step 7 and task-completed-gate.sh are aligned on the task subject format.
  - **Done when**: All improvements implemented and consistent across files
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `feat(parallel-v2): complete all 11 improvements`

## Phase 2: Refactoring

- [x] 2.1 Ensure dispatch.md internal consistency
  - **Do**: Read dispatch.md end-to-end. Check that Step 4 Partition Result, Step 6 dispatch-state.json, Step 7 TaskList creation, and Step 8 lead loop all reference the same data structures. Verify verifyTasks object format is consistent. Verify 1:1 task mapping is reflected in all examples. Fix any inconsistencies.
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: All sections reference consistent data structures and formats
  - **Verify**: Read file and confirm no contradictions
  - **Commit**: `refactor(dispatch): ensure internal consistency across sections`
  - _Design: Architecture_

- [x] 2.2 Ensure cross-file consistency
  - **Do**: Verify that dispatch.md, status.md, merge.md, task-completed-gate.sh, and SKILL.md all agree on: (1) TaskList task subject format ("X.Y: description"), (2) verifyTasks object format, (3) dispatch-state.json schema, (4) file-ownership flow (no /merge needed). Fix any cross-file mismatches.
  - **Files**: `ralph-parallel/commands/dispatch.md`, `ralph-parallel/commands/status.md`, `ralph-parallel/commands/merge.md`, `ralph-parallel/hooks/scripts/task-completed-gate.sh`, `ralph-parallel/skills/parallel-workflow/SKILL.md`
  - **Done when**: All files use consistent terminology and data formats
  - **Verify**: `grep -c "X.Y:" ralph-parallel/commands/dispatch.md ralph-parallel/commands/status.md ralph-parallel/hooks/scripts/task-completed-gate.sh` returns >= 3
  - **Commit**: `refactor(parallel): ensure cross-file consistency`
  - _Design: Architecture_

## Phase 3: Testing

- [x] 3.1 Validate bash scripts
  - **Do**: Run bash -n (syntax check) on both hook scripts. Verify jq expressions are valid. Test task-completed-gate.sh with a mock JSON input that has task_subject starting with "1.1: Add endpoint".
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`, `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: Both scripts pass syntax check and jq expressions are valid
  - **Verify**: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh`
  - **Commit**: `test(hooks): validate bash script syntax`

- [x] 3.2 Validate markdown structure
  - **Do**: Check all command markdown files have valid frontmatter (--- delimited YAML). Verify all ## headings are properly nested. Verify code blocks are properly closed. Check no broken links or references.
  - **Files**: `ralph-parallel/commands/dispatch.md`, `ralph-parallel/commands/status.md`, `ralph-parallel/commands/merge.md`
  - **Done when**: All markdown files have valid structure
  - **Verify**: `head -5 ralph-parallel/commands/dispatch.md ralph-parallel/commands/status.md ralph-parallel/commands/merge.md` shows valid frontmatter for each
  - **Commit**: `test(docs): validate markdown structure` (if fixes needed)

## Phase 4: Quality Gates

- [x] 4.1 Local quality check
  - **Do**: Run bash syntax checks on all scripts. Verify hooks.json is valid JSON. Verify plugin.json is valid JSON. Read all modified files and confirm changes are correct.
  - **Verify**: `jq . ralph-parallel/.claude-plugin/plugin.json > /dev/null && jq . ralph-parallel/hooks/hooks.json > /dev/null && bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && bash -n ralph-parallel/hooks/scripts/session-setup.sh`
  - **Done when**: All validations pass
  - **Commit**: `fix(parallel-v2): address any remaining issues` (if needed)

- [x] 4.2 Create PR and verify CI
  - **Do**: Push branch, create PR with gh CLI summarizing all 11 improvements
  - **Verify**: `gh pr checks --watch` all green (or no CI configured)
  - **Done when**: PR ready for review

## Notes

- **POC shortcuts taken**: All 11 improvements implemented in Phase 1 since they are markdown/script edits (no compilation or runtime needed)
- **Production TODOs**: Phase 2 ensures consistency across the 6 modified files
- **Key risk**: dispatch.md is large (~413 lines) — changes to Steps 4, 6, 7, 8 must be carefully coordinated
