---
spec: portability-and-autoupdate
phase: research
created: 2026-03-17T12:30:00Z
---

# Research: portability-and-autoupdate

## Executive Summary

Five portability issues and one missing feature across the ralph-parallel plugin. Issue #3 (`grep -qP`) is a **security bypass** on macOS -- null byte sanitization silently fails. Issue #1 (version sync) is a one-line fix. Issues #2-5 are straightforward portable replacements. Issue #6 (auto-update) should leverage Claude Code's native marketplace auto-update via `known_marketplaces.json` `autoUpdate` field rather than a custom SessionStart hook.

## External Research

### POSIX Shell Portability Best Practices

| Pattern | Issue | Portable Alternative | Source |
|---------|-------|---------------------|--------|
| `grep -qP '\x00'` | `-P` (Perl regex) absent on macOS BSD grep | `tr -d '\0' \| wc -c` length comparison, or remove entirely (shell vars can't hold null bytes) | [Apple Community](https://discussions.apple.com/thread/5832809) |
| `[[ expr ]]` | bash/ksh only, fails in dash/sh | `[ expr ]` with `case` for pattern matching | [Baeldung](https://www.baeldung.com/linux/bash-single-vs-double-brackets) |
| `sed $'\x1b...'` | ANSI-C quoting, bash-only syntax | `sed "s/$(printf '\033')\[[0-9;]*m//g"` or keep `$'...'` (works in bash 3.2+) | [ANSI-C Quoting Reference](https://www.gnu.org/software/bash/manual/html_node/ANSI_002dC-Quoting.html) |
| `/tmp` hardcoded | No user isolation, predictable names | `${TMPDIR:-/tmp}` with `mktemp` | [BashFAQ/062](https://mywiki.wooledge.org/BashFAQ/062), [systemd.io](https://systemd.io/TEMPORARY_DIRECTORIES/) |
| `echo -e` | Behavior varies across shells/platforms | `printf '%b\n'` | [POSIX echo spec](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/echo.html) |

### Claude Code Auto-Update Mechanism

| Aspect | Finding | Source |
|--------|---------|--------|
| Native auto-update | Claude Code 2.1.72+ supports marketplace auto-update on session start | [Issue #26744](https://github.com/anthropics/claude-code/issues/26744) |
| Activation | Requires `autoUpdate: true` in `known_marketplaces.json` entry | [Issue #26744 comments](https://github.com/anthropics/claude-code/issues/26744) |
| Third-party default | `autoUpdate` defaults to `false` for non-official marketplaces | [Issue #26744](https://github.com/anthropics/claude-code/issues/26744) |
| Custom hook approach | SessionStart hook comparing `gitCommitSha` to remote HEAD | [Issue #31462](https://github.com/anthropics/claude-code/issues/31462) |
| Cache structure | `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` | Verified locally |
| Version tracking | `installed_plugins.json` has `version`, `gitCommitSha`, `installPath` | Verified locally |

### Pitfalls to Avoid

- **Don't replace `$'...'` unnecessarily**: All scripts use `#!/bin/bash` shebang. `$'\x1b'` works in bash 3.2+ (macOS default). Only an issue if scripts are run via `sh` or `dash`.
- **Don't over-engineer null byte check**: Shell variables in bash cannot contain null bytes (C strings). The `_sanitize_cmd` function receives `$1` which is already null-byte-free. The check is defense-in-depth for theoretical piped input paths.
- **Auto-update hook network calls**: Must timeout quickly (15s max) and cache check timestamp to avoid slowing every session start.
- **Don't break test scripts**: Test files also reference `/tmp/ralph-*` paths; must be updated consistently.

## Codebase Analysis

### Issue 1: marketplace.json Version Sync

| File | Version | Status |
|------|---------|--------|
| `.claude-plugin/marketplace.json` | `0.2.3` | **STALE** |
| `plugins/ralph-parallel/.claude-plugin/plugin.json` | `0.2.4` | Current |
| `~/.claude/plugins/installed_plugins.json` | `0.2.4` | Current |

**Fix**: One-line change in marketplace.json line 13: `"0.2.3"` -> `"0.2.4"`.

### Issue 2: Hardcoded `/tmp` Paths (No User Isolation)

**Production scripts** (3 files, 3 locations):

| File | Line | Usage | Risk |
|------|------|-------|------|
| `dispatch-coordinator.sh` | 219 | `COUNTER_FILE="/tmp/ralph-stop-${SPEC_NAME}-${SESSION_ID}"` | Multi-user collision, symlink attacks |
| `teammate-idle-gate.sh` | 92 | `COUNTER_FILE="/tmp/ralph-idle-${SPEC_NAME}-${TEAMMATE_NAME_SAFE}"` | Multi-user collision, symlink attacks |
| `dispatch.md` | 69,96,136,178 | `/tmp/$specName-partition.json` | Multi-user collision |

**Test scripts** (3 files, 14+ locations):

| File | Lines | Usage |
|------|-------|-------|
| `test_stop_hook.sh` | 108-110, 281, 349, 622, 662, 697, 739-760 | Counter file assertions |
| `test_session_isolation.sh` | 84 | Cleanup: `rm -f /tmp/ralph-stop-*` |
| `test_teammate_idle_gate.sh` | 77, 92, 107, 121, 160 | Counter file operations |

**Recommended fix**: Replace `/tmp` with `${TMPDIR:-/tmp}` in production scripts. Use a helper variable:
```bash
_RALPH_TMP="${TMPDIR:-/tmp}"
```
Test scripts should follow the same pattern.
dispatch.md should use `${TMPDIR:-/tmp}/$specName-partition.json`.

### Issue 3: `grep -qP` macOS Incompatibility (SECURITY)

**Affected files** (2):

| File | Line | Code | Impact |
|------|------|------|--------|
| `task-completed-gate.sh` | 20 | `grep -qP '\x00'` | **Null byte sanitizer bypassed on macOS** |
| `capture-baseline.sh` | 21 | `grep -qP '\x00'` | **Null byte sanitizer bypassed on macOS** |

**Verified on macOS**: `/usr/bin/grep -qP` exits with code 2 (invalid option). Since the check uses `2>/dev/null`, the error is silenced. The `if` condition evaluates the exit code: 2 != 0, so the null byte check **always passes** on macOS.

**However**: Bash variables cannot contain null bytes (C strings are null-terminated). The `_sanitize_cmd` function receives `cmd` via `$1`, which already strips null bytes. The check is defense-in-depth. Still, it should work correctly for the rare path where binary data reaches the function.

**Recommended fix**: Replace with POSIX-compatible check:
```bash
# Option A: Check if tr removal changes byte count (works everywhere)
if [ "$(printf '%s' "$cmd" | wc -c)" -ne "$(printf '%s' "$cmd" | tr -d '\0' | wc -c)" ]; then

# Option B: Remove the check entirely (document that shell vars can't hold null bytes)
# This is the pragmatic choice since _sanitize_cmd always receives shell variables.
```

### Issue 4: `[[ ]]` Bash-ism

**Affected files** (2):

| File | Line | Code | Portable Alternative |
|------|------|------|---------------------|
| `teammate-idle-gate.sh` | 71 | `[[ "$TEAM_NAME" != *-parallel ]]` | `case "$TEAM_NAME" in *-parallel) ;; *) exit 0 ;; esac` |
| `capture-baseline.sh` | 40 | `while [[ $# -gt 0 ]]` | `while [ $# -gt 0 ]` |

**Context**: All scripts use `#!/bin/bash` shebang so `[[ ]]` works in practice. The risk is if Claude Code's hook runner uses `sh` instead of respecting the shebang. Based on hooks.json, commands are invoked directly (no explicit `bash` prefix), so the shebang is respected.

**Severity**: Low. But fixing is trivial and improves defensive portability.

### Issue 5: `sed $'...'` ANSI-C Quoting

**Affected files** (2):

| File | Line | Code |
|------|------|------|
| `task-completed-gate.sh` | 363 | `sed $'s/\x1b\\[[0-9;]*m//g'` |
| `capture-baseline.sh` | 110 | `sed $'s/\x1b\\[[0-9;]*m//g'` |

**Verified**: `$'\x1b'` works correctly in macOS bash 3.2.57. Both BSD and GNU sed handle the resulting literal ESC character.

**Severity**: Low. Works on all bash versions including macOS default. Only fails if run via `sh`/`dash`.

**Recommended fix** (for maximum portability):
```bash
# Use printf to generate the escape character
ESC=$(printf '\033')
... | sed "s/${ESC}\[[0-9;]*m//g"
```

### Issue 6: Additional Portability Issues Discovered

| File | Line | Issue | Fix |
|------|------|-------|-----|
| `teammate-idle-gate.sh` | 149 | `echo -e "$UNCOMPLETED"` | `printf '%b\n' "$UNCOMPLETED"` |
| `task-completed-gate.sh` | 250 | `IFS=',' read -ra FILE_LIST <<< "$TASK_FILES"` | `echo "$TASK_FILES" \| tr ',' '\n' \| while read f; do ... done` |
| `file-ownership-guard.sh` | 89 | `done <<< "$OWNED_FILES"` | `echo "$OWNED_FILES" \| while ...` (but note subshell scoping) |
| `teammate-idle-gate.sh` | 128 | `done <<< "$GROUP_TASKS"` | `echo "$GROUP_TASKS" \| while ...` |

**Note**: `<<<` here-strings and `read -ra` are bash-isms but safe given `#!/bin/bash`. Include only if goal is strict POSIX compliance.

### Auto-Update Hook Research

**Current state**: `session-setup.sh` already has a dev-source auto-sync mechanism (lines 26-37) that copies from dev source to cache on each session start. This is different from marketplace-level auto-update.

**Marketplace auto-update options**:

| Approach | Pros | Cons |
|----------|------|------|
| **A: Set `autoUpdate: true` in known_marketplaces.json** | Zero code, uses Claude Code native mechanism | Requires CLI 2.1.72+; user must set manually or via `/plugin marketplace update` |
| **B: Custom SessionStart hook** | Works on any CLI version; full control | Adds complexity; network calls on every start; reinvents native feature |
| **C: Hybrid — document `autoUpdate: true` + add lightweight version-check notification** | Best UX; native update + user notification | Most code |

**Recommended**: Approach A (native auto-update) as primary, with a lightweight version-check in `session-setup.sh` that compares `plugin.json` version against `marketplace.json` version and logs a warning if mismatched. No network calls needed -- just compare local files.

**Implementation sketch** for session-setup.sh:
```bash
# Check if marketplace version matches plugin version
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN_VER=$(jq -r '.version // empty' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null) || PLUGIN_VER=""
  MARKETPLACE_DIR=$(dirname "$(dirname "$CLAUDE_PLUGIN_ROOT")")
  # Walk up to find marketplace.json
  MKTPLACE_VER=$(jq -r '.plugins[0].version // empty' "$MARKETPLACE_DIR/../../../.claude-plugin/marketplace.json" 2>/dev/null) || MKTPLACE_VER=""
  if [ -n "$PLUGIN_VER" ] && [ -n "$MKTPLACE_VER" ] && [ "$PLUGIN_VER" != "$MKTPLACE_VER" ]; then
    echo "ralph-parallel: WARNING: plugin version ($PLUGIN_VER) != marketplace version ($MKTPLACE_VER). Run /plugin update to get the latest."
  fi
fi
```

**Better approach**: Use `git` in the marketplace clone to check for new commits:
```bash
MARKETPLACE_CLONE="$HOME/.claude/plugins/marketplaces/ralph-parallel"
if [ -d "$MARKETPLACE_CLONE/.git" ]; then
  INSTALLED_SHA=$(jq -r '.gitCommitSha // empty' "$HOME/.claude/plugins/installed_plugins.json" ... )
  REMOTE_SHA=$(cd "$MARKETPLACE_CLONE" && git fetch origin --quiet 2>/dev/null && git rev-parse origin/HEAD 2>/dev/null) || REMOTE_SHA=""
  if [ -n "$INSTALLED_SHA" ] && [ -n "$REMOTE_SHA" ] && [ "$INSTALLED_SHA" != "$REMOTE_SHA" ]; then
    BEHIND=$(cd "$MARKETPLACE_CLONE" && git rev-list --count "$INSTALLED_SHA".."$REMOTE_SHA" 2>/dev/null) || BEHIND="?"
    echo "ralph-parallel: Update available ($BEHIND commits behind). Run: claude plugin update ralph-parallel@ralph-parallel"
  fi
fi
```

With 24-hour cache to avoid repeated git fetch on every session start.

## Related Specs

| Spec | Relevance | Overlap | mayNeedUpdate |
|------|-----------|---------|---------------|
| `audit-fixes-v2` | **High** | Introduced `_sanitize_cmd` and `_sanitize_name` functions that have the `grep -qP` issue. Counter file paths were considered during audit (see learning about predictable names). | false (already merged) |
| `worktree-default-strategy` | **Low** | Changes default dispatch strategy. No overlap with portability fixes. dispatch.md `/tmp` usage affects both strategies equally. | false |

## Quality Commands

| Type | Command | Source |
|------|---------|--------|
| Lint | Not found | No package.json, Makefile, or CI |
| TypeCheck | Not found | Shell scripts + Python (no type checking configured) |
| Unit Test (shell) | `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh` | test_gate.sh |
| Unit Test (shell) | `bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh` | test_teammate_idle_gate.sh |
| Unit Test (shell) | `bash plugins/ralph-parallel/scripts/test_stop_hook.sh` | test_stop_hook.sh |
| Unit Test (shell) | `bash plugins/ralph-parallel/scripts/test_session_isolation.sh` | test_session_isolation.sh |
| Unit Test (python) | `python3 -m pytest plugins/ralph-parallel/scripts/` | Convention (155 tests per worktree-default-strategy spec) |
| Build | Not found | No build step |

**Local CI**: `bash plugins/ralph-parallel/hooks/scripts/test_gate.sh && bash plugins/ralph-parallel/hooks/scripts/test_teammate_idle_gate.sh && bash plugins/ralph-parallel/scripts/test_stop_hook.sh && python3 -m pytest plugins/ralph-parallel/scripts/`

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | **High** | All fixes are well-understood patterns with clear POSIX alternatives |
| Effort Estimate | **S** | 5 files to modify for portability + 1 for version sync + session-setup.sh for auto-update |
| Risk Level | **Low** | Changes are localized to string/pattern replacements. Test suite exists for validation. |

## Recommendations for Requirements

1. **Fix `grep -qP` first** (Issue #3) -- it's a security bypass on macOS, not just a portability issue. The pragmatic fix is replacing with `tr -d '\0' | wc -c` comparison, or removing the check with a comment explaining shell vars can't hold null bytes.

2. **Use `${TMPDIR:-/tmp}` consistently** (Issue #2) -- define `_RALPH_TMP="${TMPDIR:-/tmp}"` once per script. Update test scripts and dispatch.md accordingly. This also improves multi-user isolation on shared machines.

3. **Fix marketplace.json version** (Issue #1) -- trivial one-line change. Consider adding a version-sync check to the release process.

4. **Replace `[[ ]]` with `[ ]` and `case`** (Issue #4) -- trivial changes, 2 locations.

5. **Replace `sed $'\x1b...'`** (Issue #5) -- use `printf '\033'` to generate ESC character portably. 2 locations.

6. **Auto-update**: Recommend documenting how users can enable native Claude Code marketplace auto-update (`autoUpdate: true` in known_marketplaces.json). Add a lightweight version-mismatch check to session-setup.sh (no network calls, just local file comparison). Optionally add a git-fetch-based update check with 24-hour cache for users who want proactive notifications.

7. **Fix `echo -e`** (discovered) -- replace with `printf '%b\n'` in teammate-idle-gate.sh:149.

8. **Update test scripts** -- test_stop_hook.sh, test_teammate_idle_gate.sh, test_session_isolation.sh reference hardcoded `/tmp/ralph-*` paths. These must be updated to use `${TMPDIR:-/tmp}` consistently.

## Open Questions

1. **Scope of POSIX compliance**: Scripts use `#!/bin/bash` shebang. Should we target strict POSIX sh, or just "works on bash 3.2+ including macOS"? Issues #4 and #5 only matter for strict POSIX. The `grep -qP` issue (#3) is a real problem regardless.

2. **Auto-update approach**: Should the hook do a `git fetch` to check for remote updates (requires network, needs cache), or just compare local version files (simpler, but only catches version mismatches after marketplace is already pulled)?

3. **Test script portability**: Should test scripts also be made POSIX-portable, or are they developer-only tools where bash-isms are acceptable?

## Sources

- [Apple Community - BSD grep lacks -P flag](https://discussions.apple.com/thread/5832809)
- [Portable Shell Scripts Guide](https://oneuptime.com/blog/post/2026-01-24-portable-shell-scripts/view)
- [ANSI-C Quoting - Bash Reference](https://www.gnu.org/software/bash/manual/html_node/ANSI_002dC-Quoting.html)
- [Baeldung - Single vs Double Brackets](https://www.baeldung.com/linux/bash-single-vs-double-brackets)
- [BashFAQ/062 - Temporary Files](https://mywiki.wooledge.org/BashFAQ/062)
- [systemd.io - Using /tmp Safely](https://systemd.io/TEMPORARY_DIRECTORIES/)
- [Claude Code Issue #26744 - Third-party plugin auto-update](https://github.com/anthropics/claude-code/issues/26744)
- [Claude Code Issue #31462 - Plugin update detection](https://github.com/anthropics/claude-code/issues/31462)
- [Claude Code Issue #10265 - Automatic updating feature request](https://github.com/anthropics/claude-code/issues/10265)
- Verified on macOS: `/usr/bin/grep -qP` exits code 2 (invalid option)
- Verified on macOS: `$'\x1b'` works in bash 3.2.57
- Verified locally: `~/.claude/plugins/installed_plugins.json`, `known_marketplaces.json`
