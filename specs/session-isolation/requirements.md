# Requirements: Session Isolation

## Goal
Scope the Stop hook to only block the coordinator session that owns a dispatch, so unrelated sessions in the same project are not blocked. Recovery from session ID changes (resume/restart) must be deterministic code (bash scripts), not prompt-based.

## User Stories

### US-1: Unrelated Sessions Not Blocked
**As a** developer running multiple Claude sessions in the same project
**I want** the Stop hook to only block the session that dispatched the work
**So that** I can stop unrelated sessions without being blocked by another session's dispatch

**Acceptance Criteria:**
- [ ] AC-1.1: Session A dispatches spec X. Session B (different session_id) can stop without being blocked by spec X's dispatch.
- [ ] AC-1.2: Session A dispatches spec X. Session A cannot stop while spec X has incomplete work (existing behavior preserved).
- [ ] AC-1.3: dispatch-coordinator.sh reads `session_id` from stdin JSON input and compares against `coordinatorSessionId` in .dispatch-state.json.
- [ ] AC-1.4: Fallback chain: session_id matches coordinatorSessionId -> block; session_id mismatches -> skip; coordinatorSessionId missing -> block (legacy).

### US-2: Coordinator Session ID Stamped on Dispatch
**As a** dispatch coordinator
**I want** my session ID recorded in .dispatch-state.json when I dispatch
**So that** the Stop hook knows which session owns this dispatch

**Acceptance Criteria:**
- [ ] AC-2.1: dispatch.md Step 4 writes `"coordinatorSessionId": "<value>"` to .dispatch-state.json.
- [ ] AC-2.2: Value sourced from `$CLAUDE_SESSION_ID` env var (set by session-setup.sh via CLAUDE_ENV_FILE).
- [ ] AC-2.3: If `$CLAUDE_SESSION_ID` is empty (resume, env var lost), dispatch.md logs a warning but continues (auto-reclaim already handled ownership).
- [ ] AC-2.4: Existing .dispatch-state.json schema backward compatible -- all other fields unchanged.

### US-3: Auto-Reclaim on Session Start
**As a** developer resuming a session that was coordinating a dispatch
**I want** the SessionStart hook to automatically reclaim the dispatch for my new session ID
**So that** I don't have to manually reclaim ownership after a resume/restart

**Acceptance Criteria:**
- [ ] AC-3.1: session-setup.sh reads `session_id` from stdin JSON input via `INPUT=$(cat)`.
- [ ] AC-3.2: When coordinatorSessionId is present but mismatches current session_id AND team exists, session-setup.sh auto-updates coordinatorSessionId via jq.
- [ ] AC-3.3: When coordinatorSessionId is missing (legacy dispatch), session-setup.sh stamps current session_id onto the dispatch state file.
- [ ] AC-3.4: Auto-reclaim only fires when team exists (active teammates = real coordinator needed). If team is gone, skip auto-reclaim.
- [ ] AC-3.5: Diagnostic message printed: "ralph-parallel: Auto-reclaimed dispatch for '$ACTIVE_SPEC' (session changed)" or "ralph-parallel: Stamped session ID on legacy dispatch for '$ACTIVE_SPEC'".

### US-4: CLAUDE_ENV_FILE Best-Effort Bridge
**As a** dispatch skill
**I want** CLAUDE_SESSION_ID exported via CLAUDE_ENV_FILE on fresh session start
**So that** dispatch.md can read the env var to write coordinatorSessionId

**Acceptance Criteria:**
- [ ] AC-4.1: session-setup.sh writes `CLAUDE_SESSION_ID=<value>` to `$CLAUDE_ENV_FILE` when CLAUDE_ENV_FILE is set and non-empty.
- [ ] AC-4.2: If CLAUDE_ENV_FILE is unset/empty, session-setup.sh skips the export without error.
- [ ] AC-4.3: On resume, CLAUDE_ENV_FILE may be broken (#24775) -- auto-reclaim (US-3) compensates. No hard dependency on this env var.

### US-5: Manual Reclaim via --reclaim Flag
**As a** developer who opened a new terminal (not resume) and wants to take over a dispatch
**I want** `/dispatch --reclaim` to manually set my session as the coordinator
**So that** I can take ownership without relying on auto-reclaim

**Acceptance Criteria:**
- [ ] AC-5.1: dispatch.md accepts `--reclaim` flag in argument parsing.
- [ ] AC-5.2: `--reclaim` reads current session's CLAUDE_SESSION_ID (or falls back to requesting it via hook input).
- [ ] AC-5.3: Updates coordinatorSessionId in .dispatch-state.json for the active spec.
- [ ] AC-5.4: Outputs confirmation: "Reclaimed dispatch for '$specName' — this session is now coordinator."
- [ ] AC-5.5: Errors if no active dispatch (status != "dispatched") for the spec.

### US-6: Status Shows Coordinator Ownership
**As a** developer checking dispatch status
**I want** `/status` to show whether this session is the coordinator
**So that** I know if I own the dispatch or if another session does

**Acceptance Criteria:**
- [ ] AC-6.1: status.md reads coordinatorSessionId from .dispatch-state.json.
- [ ] AC-6.2: Compares against current session's CLAUDE_SESSION_ID env var.
- [ ] AC-6.3: Displays one of: `Coordinator: this session` / `Coordinator: different session` / `Coordinator: unknown (legacy)`.
- [ ] AC-6.4: JSON output includes `"coordinatorSessionId"` and `"isCoordinator": true|false|null`.

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | Stop hook compares session_id against coordinatorSessionId before blocking | High | Unit test: mock stdin with matching/mismatching/missing session_id; verify exit code 0 vs 2 |
| FR-2 | dispatch.md writes coordinatorSessionId to .dispatch-state.json in Step 4 | High | Integration test: dispatch a spec, verify field present in state file |
| FR-3 | session-setup.sh reads stdin JSON to extract session_id | High | Unit test: pipe JSON with session_id, verify it's parsed |
| FR-4 | session-setup.sh auto-reclaims orphaned dispatches on startup | High | Unit test: set mismatched coordinatorSessionId + team exists, verify jq update |
| FR-5 | session-setup.sh stamps legacy dispatches missing coordinatorSessionId | Medium | Unit test: dispatch state without field, verify field added |
| FR-6 | session-setup.sh exports CLAUDE_SESSION_ID via CLAUDE_ENV_FILE | Medium | Unit test: set CLAUDE_ENV_FILE to temp file, verify var written |
| FR-7 | dispatch.md accepts --reclaim flag for manual ownership transfer | Medium | Integration test: run --reclaim, verify coordinatorSessionId updated |
| FR-8 | status.md displays coordinator ownership line | Medium | Integration test: run /status, verify ownership line present |
| FR-9 | Backward compat: missing coordinatorSessionId = block any session (legacy) | High | Unit test: dispatch state without field, Stop hook blocks all sessions |
| FR-10 | Auto-reclaim only fires when team config exists with members | High | Unit test: no team config, verify no jq update attempted |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | Stop hook latency | Added time from session_id comparison | < 50ms (single jq call) |
| NFR-2 | SessionStart hook latency | Added time from auto-reclaim logic | < 100ms (jq read + conditional write) |
| NFR-3 | Zero breaking changes | Existing dispatches without coordinatorSessionId | All continue to work identically |
| NFR-4 | Atomic state updates | jq write to temp file + mv | No partial writes on crash |
| NFR-5 | No new dependencies | Tools used | Only bash, jq (already required) |

## Test Plan

### Unit Tests (per-script, isolated)

| Test | File Under Test | Scenario | Expected |
|------|----------------|----------|----------|
| T-1 | dispatch-coordinator.sh | session_id matches coordinatorSessionId, dispatch active | Exit 2 (block) |
| T-2 | dispatch-coordinator.sh | session_id mismatches coordinatorSessionId, dispatch active | Exit 0 (allow) |
| T-3 | dispatch-coordinator.sh | coordinatorSessionId missing (legacy), dispatch active | Exit 2 (block) |
| T-4 | dispatch-coordinator.sh | coordinatorSessionId present, no active dispatch | Exit 0 (allow) |
| T-5 | dispatch-coordinator.sh | session_id empty in input | Exit 2 (block, treat as legacy) |
| T-6 | session-setup.sh | Orphaned dispatch (mismatch + team exists) | coordinatorSessionId updated |
| T-7 | session-setup.sh | Orphaned dispatch (mismatch + NO team) | coordinatorSessionId NOT updated |
| T-8 | session-setup.sh | Legacy dispatch (field missing + team exists) | coordinatorSessionId stamped |
| T-9 | session-setup.sh | Legacy dispatch (field missing + NO team) | coordinatorSessionId NOT stamped |
| T-10 | session-setup.sh | CLAUDE_ENV_FILE set | CLAUDE_SESSION_ID written to file |
| T-11 | session-setup.sh | CLAUDE_ENV_FILE unset | No error, no file written |
| T-12 | session-setup.sh | session_id matches coordinatorSessionId | No update (already correct) |

### Integration Tests (multi-session simulation)

| Test | Scenario | Expected |
|------|----------|----------|
| IT-1 | Session A dispatches, Session B tries to stop | B stops freely; A blocked |
| IT-2 | Session A dispatches, resumes as Session A' | Auto-reclaim fires, A' becomes coordinator |
| IT-3 | Session A dispatches, Session B runs /status | Shows "Coordinator: different session" |
| IT-4 | Legacy dispatch (no field), any session stops | Blocked (backward compat) |
| IT-5 | /dispatch --reclaim from new session | coordinatorSessionId updated, confirmaton shown |

### Edge Case Tests

| Test | Scenario | Expected |
|------|----------|----------|
| EC-1 | Two specs dispatched, different coordinators | Each Stop hook only blocks its own coordinator |
| EC-2 | Dispatch state file corrupted (invalid JSON) | jq fails gracefully, Stop hook exits 0 (allow) |
| EC-3 | CLAUDE_ENV_FILE points to nonexistent dir | session-setup.sh skips export, no error |
| EC-4 | Team config exists but 0 members | Treated as team-lost, no auto-reclaim |
| EC-5 | concurrent session starts (theoretical TOCTOU) | Last-writer-wins is correct behavior |

## Glossary
- **coordinatorSessionId**: New field in .dispatch-state.json identifying which session owns the dispatch
- **Auto-reclaim**: SessionStart hook automatically updating coordinatorSessionId when session_id changes (resume/restart)
- **Legacy dispatch**: A .dispatch-state.json file created before session isolation, lacking the coordinatorSessionId field
- **CLAUDE_ENV_FILE**: File path provided by Claude Code to SessionStart hooks for exporting env vars to the Bash tool
- **Stop hook**: dispatch-coordinator.sh, fires when Claude attempts to stop, can block with exit code 2
- **session_id**: Unique identifier for a Claude Code session, provided in hook stdin JSON. Changes on --resume.

## Out of Scope
- Per-file session scoping (session_id is per-dispatch, not per-file)
- Multi-coordinator support (one coordinator per dispatch, not shared ownership)
- Changes to Python scripts (parse-and-partition.py, build-teammate-prompt.py, etc.)
- Changes to hooks.json registration (no new hooks needed)
- Changes to file-ownership-guard.sh or task-completed-gate.sh
- Fixing CLAUDE_ENV_FILE bug (#24775) upstream -- we work around it
- Session-scoped state files (Jon Roosevelt pattern) -- too invasive for our single-file model

## Dependencies
- `jq` must be available on PATH (already required by all hooks)
- Claude Code must provide `session_id` in hook stdin JSON (confirmed in official docs)
- CLAUDE_ENV_FILE provided by Claude Code to SessionStart hooks (confirmed, but unreliable on resume)
- Existing .dispatch-state.json files (4 exist: user-auth, api-dashboard, gpu-metrics-operator, gpu-graphics-demo -- all status=merged, no active impact)

## Files Changed

| File | Change Type | Est. Lines |
|------|------------|------------|
| hooks/scripts/dispatch-coordinator.sh | Modify | +15 (session_id comparison in scan branch) |
| hooks/scripts/session-setup.sh | Modify | +25 (stdin parsing, auto-reclaim, CLAUDE_ENV_FILE) |
| commands/dispatch.md | Modify | +8 (coordinatorSessionId in Step 4, --reclaim flag) |
| commands/status.md | Modify | +5 (coordinator ownership display) |

## Success Criteria
- Multiple sessions in same project: each only blocked by their own dispatch
- Resumed session auto-reclaims without user intervention
- Legacy dispatches (no coordinatorSessionId) behave identically to current behavior
- All unit tests pass (T-1 through T-12)
- All integration tests pass (IT-1 through IT-5)
- All edge case tests pass (EC-1 through EC-5)
- Zero regressions in existing test suite (`python3 ralph-parallel/scripts/test_*.py`)

## Unresolved Questions
- Should `--reclaim` require confirmation from the user, or execute immediately? Recommendation: execute immediately (deterministic, no prompts).
- If CLAUDE_SESSION_ID env var is empty at dispatch time, should dispatch.md refuse to proceed or continue without it? Recommendation: continue with warning (auto-reclaim handles recovery).
- Should auto-reclaim fire on `source: "compact"` in addition to `source: "resume"`? Recommendation: Yes, fire on all sources -- session_id may change on any restart.

## Next Steps
1. Approve requirements (user review)
2. Create design.md with implementation details for each file change
3. Generate tasks.md with implementation and test tasks
4. Dispatch parallel execution
