---
spec: deep-audit-fixes
phase: design
created: 2026-03-17
generated: auto
---

# Design: deep-audit-fixes

## Overview

Localized security hardening and POSIX compliance fixes across 10 shell scripts and 7 Python files. No architectural changes. Each fix is a function-level or line-level edit.

## Components

### Component A: Command Sanitizer Hardening (C1)
**Purpose**: Block command separator injection through `eval`
**Files**: `task-completed-gate.sh`, `capture-baseline.sh`
**Change**: Add rejection rules for `;`, `&&`, `||`, `|` in `_sanitize_cmd()`

```bash
# After existing backtick/subshell check, add:
# Reject command separators and pipes
if printf '%s' "$cmd" | grep -qE '[;|]|&&|\|\|' 2>/dev/null; then
    echo "ralph-parallel: REJECTED command (separator/pipe): $cmd" >&2
    return 1
fi
```

**Trade-off**: This blocks legitimate piped commands (e.g., `npm test | head`). Acceptable because verify commands should be simple single commands. If piping is needed, users can wrap in a script file.

### Component B: Input Validation (C2, C3)
**Purpose**: Prevent regex/path injection via untrusted IDs

**TASK_ID validation** (task-completed-gate.sh, teammate-idle-gate.sh):
```bash
# After extracting COMPLETED_SPEC_TASK, validate format
if ! printf '%s' "$COMPLETED_SPEC_TASK" | grep -qE '^[0-9]+\.[0-9]+$'; then
    exit 0  # Invalid format, allow through
fi
```

**SESSION_ID validation** (dispatch-coordinator.sh, teammate-idle-gate.sh):
```bash
# After reading SESSION_ID, validate format
if [ -n "$SESSION_ID" ] && ! printf '%s' "$SESSION_ID" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    SESSION_ID=""  # Clear invalid ID, fall back to no-session behavior
fi
```

**grep -F where possible** (teammate-idle-gate.sh:133-134):
Replace `grep -qE "... ${TASK_ID}\b"` with `grep -qF` for fixed-string matching where regex features not needed.

### Component C: POSIX Compliance (H4)
**Purpose**: Remove bash-only constructs

**Here-strings `<<<`** (3 locations):
```bash
# Before (bashism):
done <<< "$OWNED_FILES"

# After (POSIX):
done << EOF_VARNAME
$OWNED_FILES
EOF_VARNAME

# Or use printf pipe:
printf '%s\n' "$OWNED_FILES" | while IFS= read -r owned; do
```

Note: `printf | while` creates a subshell, so variables set inside don't propagate. Use heredoc approach for file-ownership-guard.sh:89 and teammate-idle-gate.sh:137 where the while loop sets variables (ALLOWED, UNCOMPLETED). For task-completed-gate.sh:250, restructure the file list parsing.

**Bash arrays** (task-completed-gate.sh:250-251):
```bash
# Before (bashism):
IFS=',' read -ra FILE_LIST <<< "$TASK_FILES"
for f in "${FILE_LIST[@]}"; do

# After (POSIX):
printf '%s\n' "$TASK_FILES" | tr ',' '\n' | while IFS= read -r f; do
```

Note: Since file check sets MISSING inside loop, use heredoc or restructure to avoid subshell variable loss.

### Component D: Robustness Fixes (H1, H2, H3)

**H1 -- Pipeline failure in session-setup.sh**:
Line 270 `TEAM_SPEC=$(basename "$team_dir" | sed ...)` can fail under `set -eo pipefail`.
Fix: Add `|| continue` so the loop skips on failure instead of crashing.

**H2 -- SHA validation before rev-list**:
```bash
# Before:
behind=$(git -C "$mktplace_dir" rev-list --count "${installed_sha}..origin/HEAD" 2>/dev/null)

# After:
if ! git -C "$mktplace_dir" cat-file -e "$installed_sha" 2>/dev/null; then
    echo "ralph-parallel: Installed SHA $installed_sha not found in marketplace repo (may need fetch)"
    return 0
fi
behind=$(git -C "$mktplace_dir" rev-list --count "${installed_sha}..origin/HEAD" 2>/dev/null)
```

**H3 -- printf '%b' escape sequences**:
```bash
# Before:
UNCOMPLETED="${UNCOMPLETED}  - ${TASK_ID}: ${DESC}\n"
printf '%b\n' "$UNCOMPLETED" >&2

# After:
UNCOMPLETED="${UNCOMPLETED}  - ${TASK_ID}: ${DESC}
"
printf '%s' "$UNCOMPLETED" >&2
```

### Component E: Medium Priority Fixes (M1-M10)

| ID | Fix | File |
|----|-----|------|
| M1 | `command -v timeout >/dev/null 2>&1 \|\| timeout() { shift; "$@"; }` | session-setup.sh |
| M2 | `jq -r '.[] \| select(.name == "ralph-parallel-marketplace") \| .path'` | session-setup.sh |
| M3 | Anchor test count patterns: `^[0-9]+ passed` with `[[:space:]]` | task-completed-gate.sh, capture-baseline.sh |
| M4 | Add `rm -f "$COUNTER_FILE"` on terminal status (allow idle path) | teammate-idle-gate.sh |
| M5 | Already handled by test isolation spec -- verify only | test scripts |
| M6 | Add `encoding='utf-8'` to all `open()` calls | 7 Python files |
| M7 | Skip -- Python 3.11 supports `dict \| None` natively | N/A |
| M8 | Add `$0` fallback: `${BASH_SOURCE[0]:-$0}` | test_stop_hook.sh, test_session_isolation.sh |
| M9 | Replace `.tmp.$$` with `mktemp` | session-setup.sh, dispatch-coordinator.sh |
| M10 | Strip only outer backtick pairs from verify commands | task-completed-gate.sh |

## Data Flow

1. Hook receives JSON on stdin
2. Parse fields with jq (existing)
3. **NEW**: Validate parsed IDs against allowlist patterns
4. Use validated values in grep/sed/file paths
5. **NEW**: Sanitize commands more strictly before eval
6. Execute and report results (existing)

## Technical Decisions

| Decision | Options | Choice | Rationale |
|----------|---------|--------|-----------|
| Here-string replacement | printf pipe vs heredoc | Heredoc | Avoids subshell variable loss |
| Array replacement | tr+while vs IFS loop | tr+while with restructure | POSIX compatible, clear intent |
| Session ID pattern | `[a-zA-Z0-9-]+` vs `[a-zA-Z0-9_-]+` | `[a-zA-Z0-9_-]+` | Allow underscores for safety |
| M7 (future annotations) | Add vs skip | Skip | Python 3.11 already supports native syntax |
| M5 (test cleanup traps) | Implement vs skip | Verify only | Prior spec already addressed this |
| H5 (race conditions) | Locking vs document | Document | File locking adds complexity, races are low-probability |

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `hooks/scripts/task-completed-gate.sh` | Modify | C1, C2, H4, M3, M10 |
| `hooks/scripts/teammate-idle-gate.sh` | Modify | C2, H3, H4, M4 |
| `hooks/scripts/session-setup.sh` | Modify | C3, H1, H2, M1, M2, M9 |
| `hooks/scripts/dispatch-coordinator.sh` | Modify | C3, M9 |
| `hooks/scripts/file-ownership-guard.sh` | Modify | H4 |
| `scripts/capture-baseline.sh` | Modify | C1, M3 |
| `hooks/scripts/test_gate.sh` | Modify | Add sanitizer tests |
| `hooks/scripts/test_teammate_idle_gate.sh` | Modify | Add validation tests |
| `scripts/test_stop_hook.sh` | Modify | M8 |
| `scripts/test_session_isolation.sh` | Modify | M8 |
| `scripts/*.py` (7 production files) | Modify | M6 (encoding) |

## Error Handling

| Error | Handling | User Impact |
|-------|----------|-------------|
| Invalid TASK_ID format | Allow through (exit 0) | Task completes without verify |
| Invalid SESSION_ID format | Clear to empty, no-session behavior | Legacy fallback, still functional |
| Command with separators | Block (exit 2 from sanitizer) | User must simplify verify command |
| Missing timeout command | Inline fallback runs command without timeout | Git fetch may hang (15s was limit) |
| Orphaned SHA in rev-list | Print warning, return 0 | Update check skipped gracefully |

## Existing Patterns to Follow
- `_sanitize_name()` pattern in session-setup.sh:12-23 -- reuse for ID validation
- `mktemp` pattern in capture-baseline.sh:93 -- reuse for temp file creation
- `|| continue` pattern throughout loop iterations -- reuse for H1 fix
- `2>/dev/null || true` pattern for non-fatal operations -- maintain consistency
