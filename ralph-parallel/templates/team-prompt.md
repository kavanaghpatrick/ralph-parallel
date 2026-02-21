# Team Prompt Reference

Reference guide for constructing team lead prompts. Used by `/ralph-parallel:dispatch` Step 8 when building the lead coordination loop.

## Lead Responsibilities

The lead (dispatch command itself) handles:
1. Creating the team via TeamCreate
2. Spawning teammates via Task tool (one per group, in parallel)
3. Monitoring teammate completion messages
4. Running [VERIFY] checkpoint tasks when prerequisite phases complete
5. Executing serial tasks that span file ownership boundaries
6. Shutting down teammates and cleaning up the team

## Coordination Rules

1. **File Ownership**: Each teammate ONLY modifies their assigned files. If a teammate needs a file owned by another, they must message the lead.
2. **Task Completion**: Teammates mark tasks [x] in tasks.md when done. The TaskCompleted hook runs per-task verification automatically.
3. **Phase Gates**: Lead runs [VERIFY] checkpoints between phases. Phase 2 tasks use blockedBy dependencies on the verify task for auto-unblocking.
4. **Progress**: Lead tracks completion via teammate messages and TaskList status.
5. **Completion**: When ALL tasks (parallel + serial + verify) are done, lead outputs: ALL_PARALLEL_COMPLETE

## Quality Standards

- Every task must have its Verify command pass before marking complete
- No file should be modified by a teammate that doesn't own it
- Commits follow the task's Commit message format
- All existing tests must continue passing

## Dispatch State Transitions

| From | To | Trigger |
|------|----|---------|
| (none) | dispatched | /dispatch creates new dispatch |
| dispatched | superseded | /dispatch creates newer dispatch for same spec |
| dispatched | merging | /merge starts (worktree strategy) |
| dispatched | merged | /dispatch completes (file-ownership strategy) |
| merging | merged | /merge completes |
| merging | dispatched | /merge --abort |
