# Agent Team Creation Prompt Template

This template is populated by `/ralph-parallel:dispatch` with spec-specific values.

## Template

```text
I need you to coordinate parallel execution of spec tasks as a team lead.

## Spec: {{specName}}
## Strategy: {{strategy}}

### Your Role (Lead)

You are the coordination lead. Your job is to:
1. Spawn {{teammateCount}} teammates (instructions below)
2. Monitor task completion via the shared task list
3. Run [VERIFY] checkpoint tasks yourself when all prerequisite tasks complete
4. Handle serial tasks (listed below) after all parallel groups finish
5. Signal completion when everything is done

### Team Structure

{{#each groups}}
**Teammate {{index}}: {{name}}**
Spawn with this prompt:
```
{{teammatePrompt}}
```

Tasks assigned: {{taskIds}}
Files owned: {{ownedFiles}}
{{#if dependencies}}
BLOCKED UNTIL: Teammate(s) {{dependencies}} complete their tasks first.
Do NOT spawn this teammate until blocking teammates report completion.
{{/if}}
{{/each}}

### Serial Tasks (Lead Handles)

After ALL parallel groups complete, execute these tasks sequentially:
{{#each serialTasks}}
- {{id}}: {{description}}
{{/each}}

### Verify Checkpoints

These run after their prerequisite phase completes:
{{#each verifyTasks}}
- {{id}}: {{description}} (after phase {{phase}} tasks)
{{/each}}

### Coordination Rules

1. **File Ownership**: Each teammate ONLY modifies their assigned files.
   If a teammate needs a file owned by another, they must message the lead.
2. **Task Completion**: Teammates mark tasks [x] in tasks.md when done.
   The TaskCompleted hook runs verification automatically.
3. **Dependencies**: Do NOT spawn blocked teammates until their
   dependencies are satisfied. Check task list for completion.
4. **Progress**: Update .progress.md with parallel execution notes.
5. **Completion**: When ALL tasks (parallel + serial + verify) are done,
   output: ALL_PARALLEL_COMPLETE

### Quality Standards

- Every task must have its Verify command pass before marking complete
- No file should be modified by a teammate that doesn't own it
- Commits follow the task's Commit message format
- All existing tests must continue passing
```

## Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `{{specName}}` | dispatch state | Spec name |
| `{{strategy}}` | dispatch args | file-ownership or worktree |
| `{{teammateCount}}` | partition result | Number of parallel groups |
| `{{groups}}` | partition result | Array of group objects |
| `{{groups.*.index}}` | partition | 1-based group index |
| `{{groups.*.name}}` | partition | Human-readable group name |
| `{{groups.*.teammatePrompt}}` | teammate-prompt.md | Populated teammate prompt |
| `{{groups.*.taskIds}}` | partition | Comma-separated task IDs |
| `{{groups.*.ownedFiles}}` | partition | Comma-separated file paths |
| `{{groups.*.dependencies}}` | partition | Blocking group names |
| `{{serialTasks}}` | partition | Tasks that must run serially |
| `{{verifyTasks}}` | partition | [VERIFY] checkpoint tasks |
