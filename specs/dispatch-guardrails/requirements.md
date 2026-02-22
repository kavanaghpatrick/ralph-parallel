---
spec: dispatch-guardrails
phase: requirements
created: 2026-02-22T22:15:19Z
generated: auto
---

# Requirements: dispatch-guardrails

## Summary

Add sanctioned manual group override to parse-and-partition.py and post-dispatch prompt validation to prevent leads from bypassing the prompt generation pipeline.

## User Stories

### US-1: Override auto-partition grouping

As a dispatch lead, I want to pass custom task-to-group assignments to parse-and-partition.py so that I can fix incorrect auto-groupings without bypassing the pipeline.

**Acceptance Criteria**:
- AC-1.1: `--manual-groups '{"group-name": ["1.1", "1.2"], "other-group": ["1.3"]}'` accepted by parse-and-partition.py
- AC-1.2: Manual groups still flow through build-teammate-prompt.py (file ownership, quality commands, Signed-off-by all present)
- AC-1.3: Invalid task IDs in manual groups produce clear error messages with exit code 1
- AC-1.4: File ownership is computed from task files within each manual group (not supplied by the user)
- AC-1.5: Tasks not assigned to any manual group become serial tasks (handled by lead)

### US-2: Validate teammate prompts post-dispatch

As a dispatch system, I want to validate that spawned teammate prompts contain required sections so that pipeline bypasses are detected immediately.

**Acceptance Criteria**:
- AC-2.1: validate-prompt.py checks for: `## File Ownership`, `## Quality Checks`, `## Commit Convention`, `Signed-off-by`
- AC-2.2: Missing sections produce WARNING output (not errors) — fail-open policy
- AC-2.3: Script accepts prompt text via stdin or `--prompt-file`
- AC-2.4: JSON output mode available for programmatic consumption
- AC-2.5: Exit code 0 = all sections present, exit code 1 = sections missing (but non-fatal in dispatch context)

### US-3: Integrate validation into dispatch flow

As a dispatch system, I want Step 6.5 in dispatch.md to invoke validate-prompt.py after teammates are spawned so that bypasses are caught in real time.

**Acceptance Criteria**:
- AC-3.1: dispatch.md includes Step 6.5 that runs validate-prompt.py on each generated prompt
- AC-3.2: Validation failures produce loud warnings but do NOT shut down teammates
- AC-3.3: dispatch.md instructs lead to regenerate prompts via pipeline if validation fails

## Functional Requirements

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| FR-1 | parse-and-partition.py accepts `--manual-groups` JSON arg | Must | US-1 |
| FR-2 | Manual groups produce valid partition JSON with ownedFiles computed from task files | Must | US-1 |
| FR-3 | Unassigned tasks in manual groups become serialTasks | Must | US-1 |
| FR-4 | validate-prompt.py checks 4 required sections in teammate prompts | Must | US-2 |
| FR-5 | validate-prompt.py outputs structured JSON diagnostics | Should | US-2 |
| FR-6 | dispatch.md Step 6.5 calls validate-prompt.py after spawn | Must | US-3 |
| FR-7 | Manual groups respect `--max-teammates` limit | Should | US-1 |
| FR-8 | validate-prompt.py accepts `--required-sections` override for future extensibility | Could | US-2 |

## Non-Functional Requirements

| ID | Requirement | Category |
|----|-------------|----------|
| NFR-1 | All fixes are deterministic script logic (Python/bash), not prose changes | Architecture |
| NFR-2 | Validation is fail-open: warn loudly but never kill teammates | Reliability |
| NFR-3 | Manual groups JSON must be valid JSON (parse error = exit 1) | Usability |
| NFR-4 | New scripts follow existing test patterns (pytest + importlib.util loading) | Maintainability |

## Out of Scope

- PostToolUse hook for automatic prompt validation (no hook available for Task tool)
- UI/TUI for interactive group editing
- Automatic remediation (regenerating prompts) — lead must do this manually
- Changes to build-teammate-prompt.py output format

## Dependencies

- parse-and-partition.py existing parsing infrastructure (parse_tasks, build_dependency_graph)
- build-teammate-prompt.py section header format (must stay stable for validation)
- dispatch.md Step 6 teammate spawn flow
