---
spec: audit-fixes-v2
phase: requirements
created: 2026-03-09
generated: auto
---

# Requirements: audit-fixes-v2

## Summary

Fix all 4 critical, 12 high, and 20+ medium findings from the 10-agent security audit (GitHub issue #8) of the ralph-parallel plugin.

## User Stories

### US-1: Secure command execution
As a plugin user, I want all executed commands to be validated against an allowlist so that malicious task content cannot execute arbitrary shell commands.

**Acceptance Criteria**:
- AC-1.1: `eval` in task-completed-gate.sh replaced with allowlist-validated execution
- AC-1.2: `eval` in capture-baseline.sh replaced with allowlist-validated execution
- AC-1.3: `subprocess.run(shell=True)` in validate-pre-merge.py replaced with list-based execution
- AC-1.4: Commands containing shell metacharacters (`;`, `&&`, `||`, `|`, `$()`, backticks) are rejected unless in allowlist

### US-2: Crash-safe state persistence
As a plugin user, I want dispatch-state.json writes to be crash-safe so that power loss or crashes don't produce zero-byte files.

**Acceptance Criteria**:
- AC-2.1: `write-dispatch-state.py` calls `fsync` before `os.replace`
- AC-2.2: All shell scripts using `jq > tmp && mv` pattern also use fsync equivalent

### US-3: Concurrent access safety
As a coordinator, I want dispatch-state.json reads and writes to be atomic so that concurrent hooks don't corrupt state.

**Acceptance Criteria**:
- AC-3.1: All shell read-modify-write cycles use file locking
- AC-3.2: tasks.md concurrent writes in mark-tasks-complete.py use file locking
- AC-3.3: TOCTOU on dispatch-state reads mitigated by single jq invocation

### US-4: Robust error handling
As a plugin user, I want all scripts to handle missing keys, malformed input, and edge cases gracefully.

**Acceptance Criteria**:
- AC-4.1: All Python dict accesses use `.get()` with defaults
- AC-4.2: All Python `main()` functions wrapped in try/except
- AC-4.3: `json.loads` for quality_commands guarded with try/except
- AC-4.4: Unguarded `grep -oE` under `set -e` protected with `|| true`

### US-5: Security hardening
As a plugin user, I want protection against symlink attacks, path traversal, and unsafe rsync operations.

**Acceptance Criteria**:
- AC-5.1: Predictable /tmp file names replaced with `mktemp`
- AC-5.2: Path traversal via spec/team names prevented by sanitization
- AC-5.3: rsync --delete guarded with source validation
- AC-5.4: Unquoted shell variables fixed

### US-6: Documentation accuracy
As a developer, I want SKILL.md, merge.md, and dispatch.md to accurately reflect the codebase.

**Acceptance Criteria**:
- AC-6.1: merge.md Step 5 reordered before Step 4
- AC-6.2: SKILL.md hooks table includes merge-guard.sh and teammate-idle-gate.sh
- AC-6.3: allowed-tools in commands corrected (TaskCreate vs Task)
- AC-6.4: .progress.md template documented
- AC-6.5: verify-commit-provenance.py documented as unwired/optional

### US-7: Missing implementation
As a plugin user, I want documented features to actually work.

**Acceptance Criteria**:
- AC-7.1: Circular dependency detection implemented (exit code 4)
- AC-7.2: typecheck included in validate-pre-merge.py quality loop
- AC-7.3: max_teammates bounds validated
- AC-7.4: Duplicate task IDs detected and rejected

## Functional Requirements

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| FR-1 | Validate commands against character allowlist before execution | Must | C1, C2 |
| FR-2 | Use `subprocess.run` with list args, no `shell=True` | Must | C3 |
| FR-3 | Call `fsync` before `os.replace` in atomic writes | Must | C4 |
| FR-4 | Guard `grep -oE` with `|| true` under `set -e` | Must | H1 |
| FR-5 | Add file locking to dispatch-state.json read-modify-write | Must | H2 |
| FR-6 | Reduce TOCTOU with single jq invocations | Should | H3 |
| FR-7 | Add file locking to mark-tasks-complete.py | Must | H4 |
| FR-8 | Add heartbeat age check before auto-reclaim | Must | H5 |
| FR-9 | Deep-copy task deps before mutation in `_build_groups_from_predefined` | Must | H6 |
| FR-10 | Implement circular dependency detection | Should | H7 |
| FR-11 | Use `mktemp` for all temporary files | Must | H8 |
| FR-12 | Sanitize spec/team names against path traversal | Must | H9 |
| FR-13 | Validate rsync source before `--delete` | Must | H10 |
| FR-14 | Reorder merge.md Step 5 before Step 4 | Must | H11 |
| FR-15 | Add missing hooks to SKILL.md | Must | H12 |
| FR-16 | Guard all Python dict accesses with `.get()` | Should | M-python |
| FR-17 | Wrap Python `main()` in try/except | Should | M-python |
| FR-18 | Fix unquoted shell variables | Must | M-shell |
| FR-19 | Add typecheck to validate-pre-merge.py loop | Should | M-integration |
| FR-20 | Validate max_teammates bounds | Should | M-python |
| FR-21 | Detect duplicate task IDs | Should | M-python |
| FR-22 | Fix documentation inaccuracies | Should | M-docs |

## Non-Functional Requirements

| ID | Requirement | Category |
|----|-------------|----------|
| NFR-1 | No performance regression from locking (lock timeout < 5s) | Performance |
| NFR-2 | All existing tests must continue to pass | Reliability |
| NFR-3 | Command allowlist must permit all legitimate project commands | Usability |

## Out of Scope
- Rewriting shell hooks in Python
- Adding end-to-end integration test framework
- Changing hook timeout values in hooks.json
- Adding new features beyond what audit findings require

## Dependencies
- None external -- all fixes use standard library features
