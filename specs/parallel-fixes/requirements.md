# Requirements: Ralph-Parallel Post-Demo Fixes

## Goal
Fix 9 issues discovered during parallel execution demo of the ralph-parallel plugin.

## Requirements

### R1: Direct Orchestration (Must Fix)
Dispatch command must use TeamCreate + Task tools directly instead of generating a copy-paste prompt. The user should never have to manually paste anything.

### R2: Per-Task Quality Gate (Must Fix)
TaskCompleted hook must verify only the individual task being completed, not all tasks in the group. This prevents premature Phase 2 execution.

### R3: Reliable Spec Resolution (Must Fix)
Hook must resolve the correct spec using team_name → spec name mapping as primary strategy, with .current-spec as fallback. Must work with multiple concurrent dispatches.

### R4: Dispatch State Lifecycle (Must Fix)
- Dispatch must mark previous stale dispatch states as "completed" before creating new ones
- Merge must set status to "merged" when done
- Prevent stale "dispatched" states from poisoning hooks

### R5: Automated Phase Gating (Should Fix)
Phase 2 tasks should use blockedBy dependencies on the verify task. When lead completes verify, Phase 2 tasks auto-unblock without manual messaging.

### R6: Robust Task ID Extraction (Should Fix)
Replace fragile regex extraction from task_subject with structured approach using task_description or dispatch state lookup.

### R7: Remove Dead Templates (Should Fix)
Remove or repurpose Handlebars-style templates that are never rendered. Inline prompt construction in dispatch.md.

### R8: File Ownership Enforcement During Execution (Nice to Have)
Add guidance or hook to detect file ownership violations during execution, not just at merge time.

### R9: Session Setup Cleanup (Nice to Have)
Session setup hook should check for "merged" status and re-enable gc.auto when no active dispatches remain.
