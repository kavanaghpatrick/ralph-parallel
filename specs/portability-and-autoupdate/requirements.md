# Requirements: Portability Fixes and Auto-Update

## Goal

Fix 7 portability/correctness issues in the ralph-parallel plugin (including a security bypass on macOS where null byte sanitization silently fails) and add a lightweight auto-update notification mechanism.

## User Stories

### US-1: Security — Null Byte Sanitization Works on macOS

**As a** plugin user on macOS
**I want** the `_sanitize_cmd` null byte check to actually execute
**So that** command sanitization is not silently bypassed on my platform

**Acceptance Criteria:**

- [ ] AC-1.1: `task-completed-gate.sh` line 20 no longer uses `grep -qP`
- [ ] AC-1.2: `capture-baseline.sh` line 21 no longer uses `grep -qP`
- [ ] AC-1.3: Replacement uses POSIX-compatible approach: `printf '%s' "$cmd" | tr -d '\0' | wc -c` compared against original byte count
- [ ] AC-1.4: Both files use identical `_sanitize_cmd` implementation (no drift)
- [ ] AC-1.5: Existing test suite passes after change (`bash test_gate.sh`)

### US-2: Temp File Isolation — State Files Use $TMPDIR

**As a** user on a shared machine (or macOS with per-user TMPDIR)
**I want** counter/state files to use `${TMPDIR:-/tmp}` instead of hardcoded `/tmp`
**So that** parallel sessions from different users don't collide and symlink attacks are mitigated

**Acceptance Criteria:**

- [ ] AC-2.1: `dispatch-coordinator.sh` line 219 uses `${TMPDIR:-/tmp}` for `COUNTER_FILE`
- [ ] AC-2.2: `teammate-idle-gate.sh` line 92 uses `${TMPDIR:-/tmp}` for `COUNTER_FILE`
- [ ] AC-2.3: Each script defines `_RALPH_TMP="${TMPDIR:-/tmp}"` as a shared variable (or inline `${TMPDIR:-/tmp}` directly)
- [ ] AC-2.4: `dispatch.md` lines 69, 96, 136, 178 use `${TMPDIR:-/tmp}/$specName-partition.json`
- [ ] AC-2.5: `test_stop_hook.sh` all `/tmp/ralph-stop-*` references updated to use `${TMPDIR:-/tmp}`
- [ ] AC-2.6: `test_teammate_idle_gate.sh` all `/tmp/ralph-idle-*` references updated to use `${TMPDIR:-/tmp}`
- [ ] AC-2.7: `test_session_isolation.sh` `/tmp/ralph-stop-*` references updated to use `${TMPDIR:-/tmp}`
- [ ] AC-2.8: All test scripts pass after change
- [ ] AC-2.9: Error-path comments in `dispatch-coordinator.sh` referencing `/tmp` are updated (lines 46, 75)

### US-3: Version Sync — marketplace.json Matches plugin.json

**As a** marketplace consumer
**I want** the marketplace listing version to match the actual plugin version
**So that** version checks and update detection work correctly

**Acceptance Criteria:**

- [ ] AC-3.1: `.claude-plugin/marketplace.json` `plugins[0].version` reads `"0.2.4"` (matching `plugin.json`)
- [ ] AC-3.2: No other fields in marketplace.json are changed

### US-4: Portability — Replace `[[ ]]` Bash-isms

**As a** plugin user in environments where hook runner may not respect shebang
**I want** conditional expressions to use POSIX-compatible syntax
**So that** hooks don't fail in edge-case shell environments

**Acceptance Criteria:**

- [ ] AC-4.1: `teammate-idle-gate.sh` line 71 `[[ "$TEAM_NAME" != *-parallel ]]` replaced with `case` statement
- [ ] AC-4.2: `capture-baseline.sh` line 40 `while [[ $# -gt 0 ]]` replaced with `while [ $# -gt 0 ]`
- [ ] AC-4.3: Both files pass their respective test suites after change

### US-5: Portability — Replace `sed $'\x1b...'` ANSI-C Quoting

**As a** plugin user
**I want** ANSI escape stripping to use `printf '\033'` instead of `$'\x1b'`
**So that** sed commands work even in non-bash execution contexts

**Acceptance Criteria:**

- [ ] AC-5.1: `task-completed-gate.sh` line 363 uses `ESC=$(printf '\033')` pattern
- [ ] AC-5.2: `capture-baseline.sh` line 110 uses same `ESC=$(printf '\033')` pattern
- [ ] AC-5.3: Both files define `ESC` once near top of file (or before first use), not inline per `sed` call
- [ ] AC-5.4: ANSI escape stripping produces identical results to the current implementation

### US-6: Portability — Replace `echo -e` with `printf`

**As a** plugin user
**I want** escaped string output to use `printf '%b\n'` instead of `echo -e`
**So that** output renders correctly across all platforms

**Acceptance Criteria:**

- [ ] AC-6.1: `teammate-idle-gate.sh` line 149 `echo -e "$UNCOMPLETED"` replaced with `printf '%b\n' "$UNCOMPLETED"`
- [ ] AC-6.2: Idle-gate test suite passes after change

### US-7: Auto-Update Notification

**As a** plugin user
**I want** to be notified on session start when a newer version is available
**So that** I can update without manually checking the marketplace

**Acceptance Criteria:**

- [ ] AC-7.1: `session-setup.sh` includes a version-check block that runs on SessionStart
- [ ] AC-7.2: Check compares installed `gitCommitSha` (from `installed_plugins.json`) against remote `origin/HEAD` via `git fetch`
- [ ] AC-7.3: `git fetch` uses a 24-hour cache: skip fetch if `~/.cache/ralph-parallel/last-update-check` timestamp is less than 24 hours old
- [ ] AC-7.4: `git fetch` has a 15-second timeout (`timeout 15 git fetch ...` or `GIT_HTTP_LOW_SPEED_TIME`)
- [ ] AC-7.5: If update is available, prints actionable message to stdout: "ralph-parallel: Update available (N commits behind). Run: claude plugin update ralph-parallel@ralph-parallel"
- [ ] AC-7.6: All failures (no network, no git, no cache dir, timeout) are silent -- never blocks session start
- [ ] AC-7.7: Cache directory is `${XDG_CACHE_HOME:-$HOME/.cache}/ralph-parallel/`
- [ ] AC-7.8: When `CLAUDE_PLUGIN_ROOT` is unset (dev mode / not installed via marketplace), the check is skipped entirely

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | Replace `grep -qP '\x00'` with POSIX-compatible null byte check in `_sanitize_cmd` | **Critical** | AC-1.1 through AC-1.5 |
| FR-2 | Replace hardcoded `/tmp` with `${TMPDIR:-/tmp}` in production scripts | High | AC-2.1 through AC-2.3 |
| FR-3 | Replace hardcoded `/tmp` with `${TMPDIR:-/tmp}` in dispatch.md command documentation | High | AC-2.4 |
| FR-4 | Replace hardcoded `/tmp` with `${TMPDIR:-/tmp}` in test scripts | High | AC-2.5 through AC-2.8 |
| FR-5 | Update error-path comments that reference `/tmp` | Medium | AC-2.9 |
| FR-6 | Bump marketplace.json version from `0.2.3` to `0.2.4` | High | AC-3.1, AC-3.2 |
| FR-7 | Replace `[[ ]]` with POSIX `[ ]` and `case` | Medium | AC-4.1 through AC-4.3 |
| FR-8 | Replace `sed $'\x1b...'` with `printf '\033'` variable | Medium | AC-5.1 through AC-5.4 |
| FR-9 | Replace `echo -e` with `printf '%b\n'` | Medium | AC-6.1, AC-6.2 |
| FR-10 | Add git-fetch-based update notification to session-setup.sh | Medium | AC-7.1 through AC-7.8 |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | Auto-update check latency | Session start overhead | < 100ms when cached (no fetch); < 15s worst case (fetch timeout) |
| NFR-2 | Backward compatibility | Existing test suite | All 4 test suites pass (test_gate, test_teammate_idle_gate, test_stop_hook, test_session_isolation) |
| NFR-3 | Shell compatibility | Target shell | bash 3.2+ (macOS default). Strict POSIX not required given `#!/bin/bash` shebangs. |
| NFR-4 | No regressions | Python test suite | `python3 -m pytest plugins/ralph-parallel/scripts/` passes |

## Implementation Notes

### Null Byte Check Strategy (FR-1)

Use byte-count comparison:
```bash
if [ "$(printf '%s' "$cmd" | wc -c)" -ne "$(printf '%s' "$cmd" | tr -d '\0' | wc -c)" ]; then
```
Alternative: remove the check entirely with a comment explaining shell vars cannot hold null bytes. The byte-count approach is preferred because it preserves defense-in-depth for theoretical piped-input paths.

### TMPDIR Pattern (FR-2, FR-3, FR-4)

Define once per script:
```bash
_RALPH_TMP="${TMPDIR:-/tmp}"
```
Then use `$_RALPH_TMP` in counter file paths. In dispatch.md, use `${TMPDIR:-/tmp}` inline since it's documentation, not a script.

### `[[ ]]` Replacement (FR-7)

- `[[ "$TEAM_NAME" != *-parallel ]]` becomes:
  ```bash
  case "$TEAM_NAME" in *-parallel) ;; *) exit 0 ;; esac
  ```
- `while [[ $# -gt 0 ]]` becomes `while [ $# -gt 0 ]`

### ESC Variable Pattern (FR-8)

Define once per script, before first sed usage:
```bash
ESC=$(printf '\033')
```
Then: `sed "s/${ESC}\[[0-9;]*m//g"`

### Auto-Update Cache (FR-10)

```bash
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ralph-parallel"
CACHE_FILE="$CACHE_DIR/last-update-check"
# Skip if checked within 24 hours
if [ -f "$CACHE_FILE" ]; then
  LAST_CHECK=$(cat "$CACHE_FILE" 2>/dev/null) || LAST_CHECK=0
  NOW=$(date +%s)
  if [ $((NOW - LAST_CHECK)) -lt 86400 ]; then
    # Skip fetch
  fi
fi
```

### Files Modified (Summary)

| File | Changes |
|------|---------|
| `.claude-plugin/marketplace.json` | Version bump |
| `hooks/scripts/task-completed-gate.sh` | grep -qP fix, sed $'\x1b' fix |
| `hooks/scripts/teammate-idle-gate.sh` | /tmp fix, [[ ]] fix, echo -e fix |
| `hooks/scripts/dispatch-coordinator.sh` | /tmp fix, comment updates |
| `scripts/capture-baseline.sh` | grep -qP fix, [[ ]] fix, sed $'\x1b' fix |
| `hooks/scripts/session-setup.sh` | Auto-update notification |
| `commands/dispatch.md` | /tmp references |
| `scripts/test_stop_hook.sh` | /tmp references |
| `scripts/test_session_isolation.sh` | /tmp references |
| `hooks/scripts/test_teammate_idle_gate.sh` | /tmp references |

### Excluded Files (Not Changed)

Python test files using `/tmp` as a literal path argument (e.g., `test_build_teammate_prompt.py` passing `/tmp` as `--project-root`) are **not** in scope. These are using `/tmp` as a dummy directory path, not as a state-file location.

## Glossary

- **TMPDIR**: Environment variable set by the OS to point to the user-specific temporary directory. On macOS, typically `/var/folders/.../T/`. Falls back to `/tmp` when unset.
- **_sanitize_cmd**: Security function that validates commands before `eval`, rejecting null bytes, command substitution, and path traversal.
- **_sanitize_name**: Security function that validates spec/team names against `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`.
- **Counter file**: Temp file tracking how many times a hook has blocked an action. Used by stop-hook and idle-gate safety valves.
- **known_marketplaces.json**: Claude Code config file tracking installed marketplace sources and settings.
- **installed_plugins.json**: Claude Code config file tracking installed plugin versions and git commit SHAs.

## Out of Scope

- Replacing `<<<` here-strings (`task-completed-gate.sh:250`, `file-ownership-guard.sh:89`, `teammate-idle-gate.sh:128`) -- these are bash-isms but safe with `#!/bin/bash` and not worth the subshell scoping risk of piped alternatives
- Replacing `read -ra` (`task-completed-gate.sh:250`) -- same rationale
- Python test files using `/tmp` as dummy path arguments (not state files)
- Strict POSIX sh compliance -- target is bash 3.2+
- Native Claude Code `autoUpdate: true` configuration -- document it but don't modify user config files
- Adding CI/CD or automated linting
- Version bump beyond 0.2.4 (this spec fixes existing release, doesn't create a new one)

## Dependencies

- bash 3.2+ (macOS default) on target systems
- `jq` available on PATH (already a dependency for all hooks)
- `git` available on PATH (for auto-update check)
- `tr`, `wc`, `printf`, `sed`, `date` -- standard POSIX utilities

## Success Criteria

- All 4 shell test suites pass: `test_gate.sh`, `test_teammate_idle_gate.sh`, `test_stop_hook.sh`, `test_session_isolation.sh`
- Python test suite passes: `python3 -m pytest plugins/ralph-parallel/scripts/`
- `grep -qP` appears nowhere in the codebase
- Hardcoded `/tmp/ralph-` appears nowhere in production scripts or test scripts
- `echo -e` appears nowhere in production scripts
- `[[ ]]` appears nowhere in production scripts
- `sed $'` appears nowhere in production scripts
- marketplace.json version matches plugin.json version
- Session start with update available prints notification; session start without update available adds no output

## Unresolved Questions

- None. All open questions from research resolved pragmatically:
  - Target: bash 3.2+ (not strict POSIX)
  - Auto-update: git-fetch with 24-hour cache
  - Test scripts: yes, update for TMPDIR consistency

## Next Steps

1. Approve these requirements
2. Generate tasks.md with implementation tasks (ordered: FR-1 security fix first)
3. Implement changes (estimated: 10 files, ~50 line-level edits)
4. Run full test suite to verify zero regressions
