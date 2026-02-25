---
spec: session-isolation
phase: research
created: 2026-02-25
---

# Research: Session Isolation

## Executive Summary

The prior research at `specs/dispatch-guardrails/research-session-isolation.md` is validated and largely correct. The core approach (store `coordinatorSessionId` in dispatch state, compare in Stop hook) is sound. However, there is a newly confirmed critical issue: `CLAUDE_ENV_FILE` is broken on resume due to session ID directory mismatch (GitHub #24775, OPEN), which means the `CLAUDE_ENV_FILE` bridge for getting `session_id` into dispatch is unreliable. The recovery mechanism must be a deterministic script (not prompt-based `--reclaim`), executable from the SessionStart hook.

## Prior Research Validation

Source: `/Users/patrickkavanagh/parallel_ralph/specs/dispatch-guardrails/research-session-isolation.md`

| Finding | Status | Notes |
|---------|--------|-------|
| `session_id` is common input on ALL hooks | **Confirmed** | Official docs, web search |
| `session_id` changes on `--resume` | **Confirmed** | GitHub #12235, #8069, #10806 |
| `CLAUDE_ENV_FILE` only in SessionStart | **Confirmed** | Official docs |
| `stop_hook_active` intentionally unchecked | **Confirmed** | Hook gives actionable next steps |
| Backward compat: missing field = block any session | **Confirmed** | Correct for legacy dispatches |
| Team existence as secondary discriminator | **Confirmed** | Best fallback after session_id |
| Fallback chain design | **Confirmed** | session_id match -> skip (different) -> block (legacy) |

### New Finding: CLAUDE_ENV_FILE Broken on Resume

Source: [GitHub #24775](https://github.com/anthropics/claude-code/issues/24775) (OPEN)

On `--resume`/`--continue`/compaction, `CLAUDE_ENV_FILE` points to a **startup session's** directory but the Bash tool env loader reads from the **resumed session's** directory. Env vars written by SessionStart are never found in resumed sessions.

**Impact**: The prior research recommended `session-setup.sh` exports `CLAUDE_SESSION_ID` via `CLAUDE_ENV_FILE`, then `dispatch.md` reads `$CLAUDE_SESSION_ID`. This works for fresh sessions but **fails silently on resume** -- the env var will be unset.

**Mitigation**: dispatch.md must have a fallback when `$CLAUDE_SESSION_ID` is empty. See "Code Harness Recovery" section.

## External Research

### Best Practices for Session Isolation in Hooks

Source: [Jon Roosevelt - Session Isolation for Claude Code Plugins](https://jonroosevelt.com/blog/claude-code-session-isolation-hooks)

Pattern: SessionStart writes `session_id` to `CLAUDE_ENV_FILE`, state files are scoped per-session (`file.{session_id}.local.md`), Stop hook reads `session_id` from its own JSON input to check only its own state file.

Key insight: **"Hooks are global, state must be local."** The `CLAUDE_ENV_FILE` mechanism is the bridge between hook context (has session_id) and tool context (needs session_id via env var).

### Claude Code Hooks Reference (Official)

Source: [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks)

Confirmed facts:
- Stop hook input: `session_id`, `stop_hook_active`, `last_assistant_message`, `transcript_path`, `cwd`
- SessionStart input: `session_id`, `source` (startup/resume/clear/compact), `cwd`
- Exit code 2 = block stop, stderr becomes prompt to Claude
- `CLAUDE_ENV_FILE` available only to SessionStart hooks
- Hooks snapshot at startup, don't hot-reload

### Known Bugs Affecting This Feature

| Issue | Status | Impact |
|-------|--------|--------|
| [#24775](https://github.com/anthropics/claude-code/issues/24775) | OPEN | CLAUDE_ENV_FILE broken on resume -- session ID directory mismatch |
| [#15840](https://github.com/anthropics/claude-code/issues/15840) | OPEN | CLAUDE_ENV_FILE sometimes empty string for plugins |
| [#12235](https://github.com/anthropics/claude-code/issues/12235) | OPEN | session_id changes on --resume |

## Code Harness Recovery Design

The user requirement: recovery must be **deterministic code harness** (scripts), not prompt-based reclaim. This changes the prior research recommendation from `/dispatch --reclaim` (prompt) to an automated script in `session-setup.sh` (code).

### Approach: SessionStart Auto-Reclaim

When `session-setup.sh` detects an orphaned dispatch (status=dispatched, team exists, but `coordinatorSessionId` doesn't match current session), it should **automatically update** `coordinatorSessionId` to the current session's ID.

**Why this is safe**:
1. SessionStart fires before any user interaction -- no race with other hooks
2. The scan already exists (lines 27-36 of current `session-setup.sh`)
3. The team existence check already exists (lines 70-77)
4. Only ONE session can be starting at a time per terminal (not concurrent)

**Implementation**:

```bash
# In session-setup.sh, after detecting active dispatch:
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

if [ "$DISPATCH_ACTIVE" = true ] && [ -n "$SESSION_ID" ]; then
  COORD_SID=$(jq -r '.coordinatorSessionId // empty' "$DISPATCH_FILE" 2>/dev/null) || COORD_SID=""

  if [ -n "$COORD_SID" ] && [ "$COORD_SID" != "$SESSION_ID" ]; then
    # Session ID mismatch -- this is likely a resumed/restarted coordinator
    # Auto-reclaim: update coordinatorSessionId to current session
    jq --arg sid "$SESSION_ID" '.coordinatorSessionId = $sid' "$DISPATCH_FILE" > "${DISPATCH_FILE}.tmp" \
      && mv "${DISPATCH_FILE}.tmp" "$DISPATCH_FILE"
    echo "ralph-parallel: Auto-reclaimed dispatch for '$ACTIVE_SPEC' (session changed)"
  elif [ -z "$COORD_SID" ]; then
    # Legacy dispatch (no coordinatorSessionId) -- stamp current session
    jq --arg sid "$SESSION_ID" '.coordinatorSessionId = $sid' "$DISPATCH_FILE" > "${DISPATCH_FILE}.tmp" \
      && mv "${DISPATCH_FILE}.tmp" "$DISPATCH_FILE"
    echo "ralph-parallel: Stamped session ID on legacy dispatch for '$ACTIVE_SPEC'"
  fi
fi
```

**Edge case: Two sessions start simultaneously, both see orphaned dispatch**

This is a theoretical TOCTOU but practically impossible:
- Sessions are started by humans, one at a time
- Even if two terminals start `claude` at the same instant, jq operations take <10ms
- The "last writer wins" semantic is correct -- the last session to start IS the coordinator

### Approach: CLAUDE_ENV_FILE with Fallback

Even though #24775 makes `CLAUDE_ENV_FILE` unreliable on resume, it works for **fresh sessions** (the common case for dispatch). The strategy:

1. `session-setup.sh` exports `CLAUDE_SESSION_ID` via `CLAUDE_ENV_FILE` (works on fresh start)
2. `session-setup.sh` auto-reclaims on resume (handles the broken env var case)
3. `dispatch.md` reads `$CLAUDE_SESSION_ID` and writes to state file
4. If `$CLAUDE_SESSION_ID` is empty (resume, env var lost), dispatch.md logs a warning but continues -- the SessionStart auto-reclaim already handled it

### Why `/dispatch --reclaim` is Still Useful

Even with auto-reclaim in SessionStart, an explicit reclaim is needed for:
- Debugging: user wants to verify the session owns the dispatch
- Manual override: user opened a NEW terminal (not resume) and wants to take over
- The auto-reclaim only fires on sessions that see an active dispatch at startup

**But**: `--reclaim` should be a thin wrapper around the same `jq` update, not a separate mechanism.

## Codebase Analysis

### File Inventory

| File | Role | Changes Needed |
|------|------|----------------|
| `hooks/scripts/dispatch-coordinator.sh` | Stop hook -- blocks coordinator from stopping | Add session_id comparison logic |
| `hooks/scripts/session-setup.sh` | SessionStart -- env setup, dispatch detection | Add CLAUDE_ENV_FILE export, auto-reclaim |
| `commands/dispatch.md` | Dispatch skill -- orchestrates parallel execution | Write `coordinatorSessionId` to state, add `--reclaim` |
| `commands/status.md` | Status display | Show coordinator session ownership |
| `hooks/hooks.json` | Hook registration | No changes needed |
| `scripts/*.py` | Deterministic scripts | No changes needed (session_id is hook/skill level) |

### Current .dispatch-state.json Schema

Source: `/Users/patrickkavanagh/parallel_ralph/specs/user-auth/.dispatch-state.json`

```json
{
  "dispatchedAt": "...",
  "strategy": "file-ownership",
  "maxTeammates": 4,
  "groups": [...],
  "serialTasks": [...],
  "verifyTasks": [...],
  "status": "merged",
  "completedGroups": [...]
}
```

New field to add: `"coordinatorSessionId": "<session-id-string>"`

4 existing dispatch state files exist without this field -- backward compatibility is mandatory.

### Existing Patterns

The Stop hook (`dispatch-coordinator.sh`) already:
- Reads `cwd` from JSON input (line 17) -- adding `session_id` follows same pattern
- Has a no-team-name scan branch (lines 42-55) -- this is where session_id comparison goes
- Has team-lost detection (lines 98-108) -- session_id enhances this

The SessionStart hook (`session-setup.sh`) already:
- Reads stdin JSON (implicitly via git commands, but doesn't parse it yet)
- Scans for active dispatches (lines 27-36)
- Checks team existence (lines 70-77)
- **Does NOT read `INPUT` from stdin** -- this is a gap; it needs to read stdin for `session_id`

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All primitives exist; session_id available in hooks |
| Effort Estimate | S | 4 files, ~50 lines of new logic total |
| Risk Level | Low | Graceful degradation on missing field; auto-reclaim is safe |
| CLAUDE_ENV_FILE reliability | Medium | Works fresh, broken on resume (#24775). Auto-reclaim compensates |

## Recommendations for Requirements

1. **Auto-reclaim in SessionStart** (deterministic, code harness): `session-setup.sh` detects orphaned dispatch and updates `coordinatorSessionId` automatically. This is the primary recovery mechanism.

2. **CLAUDE_ENV_FILE as best-effort bridge**: Export `CLAUDE_SESSION_ID` in SessionStart for dispatch.md to read. Gracefully degrade when empty (auto-reclaim already handled it).

3. **Stop hook session_id comparison**: Add to `dispatch-coordinator.sh` scan branch. Fallback chain: match -> block; mismatch -> skip; missing field -> block (legacy).

4. **dispatch.md Step 4 enhancement**: Write `coordinatorSessionId` from `$CLAUDE_SESSION_ID` env var. If empty, warn but continue.

5. **`--reclaim` flag**: Add to dispatch.md as thin wrapper around jq update. For manual override use cases.

6. **status.md enhancement**: Show `Coordinator: this session / different session / unknown (legacy)` based on `coordinatorSessionId` comparison.

7. **No changes to Python scripts or hooks.json**: Session isolation is purely hook/skill level logic.

## Related Specs

| Spec | Relevance | mayNeedUpdate | Notes |
|------|-----------|---------------|-------|
| dispatch-guardrails | High | No | Prior research lives there; session-isolation is the dedicated spec for this work |
| quality-gates-v2 | Low | No | Unrelated (lint gate, task writeback, provenance) |
| parallel-v2 | Medium | No | Status improvements overlap with /status coordinator display |
| parallel-qa-overhaul | Low | No | QA pipeline changes are orthogonal |
| gpu-graphics-demo | Low | No | Consumer spec, not plugin infrastructure |

## Quality Commands

| Type | Command | Source |
|------|---------|--------|
| Build | `tsc` | package.json scripts.build |
| Test | `node ./scripts/test.mjs` | package.json scripts.test |
| TypeCheck | `tsc --noEmit` | package.json scripts.typecheck |
| Lint | Not found | - |
| E2E Test | Not found | - |

**Note**: These are the project-level commands. The plugin itself is bash scripts + markdown -- no compilation. Testing is via `python3 ralph-parallel/scripts/test_*.py`.

**Local CI**: `tsc --noEmit && node ./scripts/test.mjs`

## Open Questions

1. **Should auto-reclaim fire for ALL sessions or only when team exists?** Recommendation: only when team exists (active teammates = real coordinator needed). If team is gone, the SessionStart warning is sufficient.

2. **Should legacy dispatches (no coordinatorSessionId) get auto-stamped?** Recommendation: Yes. SessionStart stamps current session_id on any dispatch missing the field. This upgrades legacy state to session-aware.

3. **What if user intentionally runs two sessions coordinating different specs?** The design handles this correctly: each dispatch has its own `coordinatorSessionId`, Stop hook scans all specs, only blocks for matches.

## Sources

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks) -- official docs
- [Jon Roosevelt - Session Isolation for Claude Code Plugins](https://jonroosevelt.com/blog/claude-code-session-isolation-hooks) -- pattern reference
- [GitHub #24775](https://github.com/anthropics/claude-code/issues/24775) -- CLAUDE_ENV_FILE broken on resume (OPEN)
- [GitHub #15840](https://github.com/anthropics/claude-code/issues/15840) -- CLAUDE_ENV_FILE empty for plugins (OPEN)
- [GitHub #12235](https://github.com/anthropics/claude-code/issues/12235) -- session_id changes on resume
- [GitHub #8069](https://github.com/anthropics/claude-code/issues/8069) -- SDK resume gives different session_id
- [GitHub #10806](https://github.com/anthropics/claude-code/issues/10806) -- --resume creates new session_id
- `/Users/patrickkavanagh/parallel_ralph/specs/dispatch-guardrails/research-session-isolation.md` -- prior research
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/dispatch-coordinator.sh` -- current Stop hook
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/scripts/session-setup.sh` -- current SessionStart hook
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/dispatch.md` -- dispatch skill
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/commands/status.md` -- status skill
- `/Users/patrickkavanagh/parallel_ralph/ralph-parallel/hooks/hooks.json` -- hook config
- `/Users/patrickkavanagh/parallel_ralph/specs/user-auth/.dispatch-state.json` -- existing state file example
