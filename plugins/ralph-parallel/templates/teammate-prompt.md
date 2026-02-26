# Teammate Prompt Reference

Reference guide for constructing per-group teammate prompts. Used by `/ralph-parallel:dispatch` Step 6 when spawning teammates.

## Prompt Structure

Each teammate prompt should include these sections:

### 1. Identity and Assignment
- Teammate name matches group name (e.g., "data-models")
- References the spec name and individual TaskList task IDs (1:1 with spec tasks)
- Claims each task individually via TaskUpdate as they start it

### 2. Task List
- Full task blocks from tasks.md, in execution order
- Each task includes: Files, Do steps, Done when, Verify command, Commit message
- Phase 2 tasks are marked with a NOTE to wait for lead confirmation

### 3. File Ownership
- Explicit list of ALL files the teammate may modify
- Clear instruction: may READ any file, but NEVER WRITE outside ownership list
- This is the primary enforcement mechanism for file-ownership strategy

### 4. Execution Rules
- For each task: claim TaskList task → implement → run verify → commit → mark [x] in tasks.md → mark TaskList task as completed
- After all tasks: message lead with completion summary

### 5. Communication Protocol
- Message lead on completion: "Group $name complete. All N tasks verified."
- Message lead on blockers: explain issue, do NOT modify other files
- For Phase 2 tasks: pause and message lead after Phase 1 tasks complete

## Key Fields Per Teammate

| Field | Source | Example |
|-------|--------|---------|
| Group name | Partition result | "data-models" |
| Spec name | Dispatch state | "user-auth" |
| TaskList IDs | Created in Step 5 (one per spec task) | "#1, #2, #3" |
| Task list | tasks.md content | Full task blocks |
| Owned files | Partition result | ["src/models/User.ts", ...] |
| Dependencies | Partition result | [] or ["api-layer"] |
| Task count | Partition result | 3 |
| Working directory | Project root | /path/to/project |
