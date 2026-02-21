# Tasks: Ralph-Parallel Post-Demo Fixes

## Phase 1: Hook Fixes (Critical Path)

- [x]1.1 [P] Fix task-completed-gate.sh to verify per-task not per-group
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Do**:
    1. Change hook to extract ONLY the single task being completed from dispatch state
    2. Map TaskList task_id to spec task IDs via dispatch-state.json groups (not subject regex)
    3. Find the verify command for that specific task in tasks.md
    4. Run only that task's verify command, not all group tasks chained
  - **Done when**: Hook verifies individual task, not entire group
  - **Verify**: Read the hook script and confirm it maps task_id → single spec task verify command
  - **Commit**: `fix: quality gate verifies per-task instead of per-group`

- [x]1.2 [P] Fix spec resolution in task-completed-gate.sh
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Do**:
    1. Parse team_name from hook input JSON
    2. Derive spec name: strip "-parallel" suffix from team_name
    3. Look up specs/$specName/.dispatch-state.json directly
    4. Keep .current-spec as secondary fallback
    5. Keep alphabetical scan as last resort fallback
  - **Done when**: Hook resolves correct spec even with multiple dispatched specs
  - **Verify**: Read hook and confirm team_name is parsed and used as primary resolution
  - **Commit**: `fix: resolve correct spec via team_name in quality gate hook`

- [x]1.3 [P] Fix session-setup.sh stale detection and gc.auto cleanup
  - **Files**: `ralph-parallel/hooks/scripts/session-setup.sh`
  - **Do**:
    1. Check for "merged" status in addition to "dispatched" and "merging"
    2. Only disable gc.auto if at least one dispatch has status "dispatched" or "merging"
    3. If all dispatches are "merged" or no dispatches exist, ensure gc.auto is restored to default
  - **Done when**: gc.auto is properly managed across dispatch lifecycle
  - **Verify**: Read hook and confirm "merged" status is handled
  - **Commit**: `fix: session-setup handles merged status and restores gc.auto`

- [x]1.4 [VERIFY] Phase 1 hook fixes verification
  - **Files**: none
  - **Do**:
    1. Read all three hook scripts and verify changes are correct
    2. Confirm task-completed-gate.sh handles: per-task verify, team_name resolution, fallbacks
    3. Confirm session-setup.sh handles: merged status, gc.auto restore
  - **Done when**: All hook scripts are internally consistent
  - **Verify**: Read all modified hook files
  - **Commit**: none

## Phase 2: Dispatch Command Rewrite

- [x]2.1 [P] Rewrite dispatch.md Steps 6-7 for direct orchestration
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Do**:
    1. Replace Step 6 (Generate Team Creation Prompt) with: Use TeamCreate to create team named "$specName-parallel"
    2. Replace Step 7 (Output prompt for copy-paste) with: Use Task tool to spawn teammates with inline prompts
    3. Add Step 8: Lead coordination loop — monitor completion, run verify checkpoints, handle serial tasks
    4. Update the CRITICAL delegation rules to reflect direct orchestration
    5. Keep --dry-run behavior unchanged (show plan only)
  - **Done when**: dispatch.md instructs agent to orchestrate directly via TeamCreate + Task
  - **Verify**: Read dispatch.md and confirm Steps 6-7 use TeamCreate/Task tools
  - **Commit**: `feat: dispatch orchestrates directly via Agent Teams API`

- [x]2.2 [P] Add dispatch state lifecycle management to dispatch.md
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Do**:
    1. Before writing new dispatch state, scan for stale dispatches in same spec
    2. If existing dispatch-state.json has status "dispatched", warn and set to "superseded"
    3. Add completedGroups tracking as teammates finish
    4. Document status transitions: dispatched → merging → merged (or superseded)
  - **Done when**: dispatch.md includes stale state cleanup before creating new dispatch
  - **Verify**: Read dispatch.md and confirm stale state handling exists
  - **Commit**: `feat: dispatch manages stale state lifecycle`

- [x]2.3 [P] Add automated phase gating to dispatch.md
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Do**:
    1. In Step 8 (coordination loop), use TaskList blockedBy dependencies for Phase 2 tasks
    2. Phase 2 teammate tasks should be created with blockedBy on the verify checkpoint task
    3. When lead completes verify, Phase 2 tasks auto-unblock
    4. Lead messages teammates to proceed only as a notification, not a gate
  - **Done when**: Phase 2 tasks auto-unblock via task dependencies
  - **Verify**: Read dispatch.md Step 8 and confirm blockedBy usage
  - **Commit**: `feat: automated phase gating via task dependencies`

- [x]2.4 [VERIFY] Phase 2 dispatch rewrite verification
  - **Files**: none
  - **Do**:
    1. Read full dispatch.md and verify coherent flow from Step 1 to Step 8
    2. Confirm --dry-run still stops at Step 5
    3. Confirm direct orchestration replaces copy-paste prompt
    4. Confirm phase gating uses blockedBy
  - **Done when**: dispatch.md is a complete, consistent command spec
  - **Verify**: Read dispatch.md end-to-end
  - **Commit**: none

## Phase 3: Supporting Files

- [x]3.1 [P] Update merge.md with dispatch state cleanup
  - **Files**: `ralph-parallel/commands/merge.md`
  - **Do**:
    1. After successful merge, set dispatch-state.json status to "merged"
    2. Add completedGroups field update as each group is verified
    3. Document that merge restores gc.auto if no other active dispatches
  - **Done when**: merge.md sets status "merged" on completion
  - **Verify**: Read merge.md and confirm status transition to "merged"
  - **Commit**: `feat: merge sets dispatch status to merged on completion`

- [x]3.2 [P] Update SKILL.md and remove dead templates
  - **Files**: `ralph-parallel/skills/parallel-workflow/SKILL.md`, `ralph-parallel/templates/team-prompt.md`, `ralph-parallel/templates/teammate-prompt.md`
  - **Do**:
    1. Update SKILL.md: remove "user pastes the prompt" language, document direct orchestration
    2. Convert team-prompt.md from Handlebars template to reference doc (prompt construction guide)
    3. Convert teammate-prompt.md from Handlebars template to reference doc
    4. Remove {{variable}} syntax, replace with plain descriptions of what to include
  - **Done when**: SKILL.md reflects direct orchestration, templates are reference docs
  - **Verify**: Read SKILL.md and confirm no copy-paste language
  - **Commit**: `docs: update skill docs for direct orchestration, convert templates to reference`

- [x]3.3 [P] Add file ownership enforcement guidance to dispatch.md
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Do**:
    1. In teammate prompt construction, add explicit warning about file ownership
    2. Add instruction for teammates to check owned files before writing
    3. Document that merge.md will detect violations post-hoc
    4. Optionally suggest a PostToolUse:Write hook pattern for enforcement
  - **Done when**: Dispatch teammate prompts include ownership enforcement
  - **Verify**: Read dispatch.md teammate prompt section
  - **Commit**: `feat: add file ownership enforcement guidance to dispatch`

- [x]3.4 [VERIFY] Final integration verification
  - **Files**: none
  - **Do**:
    1. Read all modified files end-to-end
    2. Verify dispatch.md → merge.md → status.md form coherent lifecycle
    3. Verify hooks are consistent with command specs
    4. Verify SKILL.md matches actual behavior
  - **Done when**: All plugin files are internally consistent
  - **Verify**: Read all plugin files
  - **Commit**: none
