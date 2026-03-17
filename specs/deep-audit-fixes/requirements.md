---
spec: deep-audit-fixes
phase: requirements
created: 2026-03-17
generated: auto
---

# Requirements: deep-audit-fixes

## Summary

Fix all 18 findings from a 10-agent deep audit: harden command sanitization, validate regex inputs, enforce POSIX compliance, and improve defensive coding across the ralph-parallel plugin.

## User Stories

### US-1: Command injection prevention
As a plugin user, I want the command sanitizer to reject all injection vectors so that eval'd commands cannot chain arbitrary shell operations.

**Acceptance Criteria**:
- AC-1.1: `_sanitize_cmd()` rejects commands containing `;`, `&&`, `||`, `|` (pipe)
- AC-1.2: Both copies (task-completed-gate.sh and capture-baseline.sh) are updated identically
- AC-1.3: Existing valid verify commands still pass sanitization

### US-2: Regex injection prevention
As a plugin user, I want task IDs and session IDs validated before use in patterns so that malformed IDs cannot cause regex injection or path traversal.

**Acceptance Criteria**:
- AC-2.1: COMPLETED_SPEC_TASK validated to match `^[0-9]+\.[0-9]+$` before grep/sed use
- AC-2.2: SESSION_ID validated to match `^[a-zA-Z0-9-]+$` before file path use
- AC-2.3: `grep -F` used where fixed-string matching suffices

### US-3: POSIX compliance
As a developer, I want all scripts to use POSIX-compatible constructs so that the plugin works reliably across bash 3.2+ environments.

**Acceptance Criteria**:
- AC-3.1: No `<<<` here-strings in production scripts
- AC-3.2: No bash arrays `${arr[@]}` in production scripts
- AC-3.3: No `IFS=',' read -ra` in production scripts
- AC-3.4: `BASH_SOURCE[0]` has `$0` fallback where used without one

### US-4: Robustness improvements
As a plugin user, I want edge cases handled gracefully so that pipeline failures, missing commands, and escape sequences don't cause silent errors.

**Acceptance Criteria**:
- AC-4.1: `session-setup.sh` orphaned team cleanup handles basename/sed failure
- AC-4.2: `git rev-list --count` validates SHA exists before counting
- AC-4.3: `printf '%b'` replaced with `printf '%s'` + real newlines
- AC-4.4: `timeout` usage has `command -v` fallback
- AC-4.5: Marketplace query uses name-based lookup instead of `[0]`
- AC-4.6: `.tmp.$$` replaced with `mktemp` for temp files

## Functional Requirements

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| FR-1 | Strengthen `_sanitize_cmd()` to reject `;`, `&&`, `\|\|`, `\|` | Must | US-1, C1 |
| FR-2 | Validate TASK_ID matches `^[0-9]+\.[0-9]+$` before regex use | Must | US-2, C2 |
| FR-3 | Validate SESSION_ID matches `^[a-zA-Z0-9-]+$` before path use | Must | US-2, C3 |
| FR-4 | Replace `<<<` with `echo ... \| while read` or `printf ... \| while read` | Must | US-3, H4 |
| FR-5 | Replace bash arrays with POSIX alternatives | Must | US-3, H4 |
| FR-6 | Add `\|\| continue` to session-setup.sh pipeline | Should | US-4, H1 |
| FR-7 | Validate SHA before `git rev-list --count` | Should | US-4, H2 |
| FR-8 | Use `printf '%s'` instead of `printf '%b'` | Should | US-4, H3 |
| FR-9 | Add race condition documentation comments | Should | US-4, H5 |
| FR-10 | Add `command -v timeout` check with fallback | Could | US-4, M1 |
| FR-11 | Query marketplace by name instead of `[0]` | Could | US-4, M2 |
| FR-12 | Use anchored patterns for test count parsing | Could | M3 |
| FR-13 | Add counter file cleanup on terminal status | Could | M4 |
| FR-14 | Add trap for global team config in test scripts | Could | M5 |
| FR-15 | Add `encoding='utf-8'` to Python file operations | Could | M6 |
| FR-16 | Add `from __future__ import annotations` to Python files | Could | M7 |
| FR-17 | Add `$0` fallback for `BASH_SOURCE[0]` | Could | M8 |
| FR-18 | Replace `.tmp.$$` with `mktemp` | Could | M9 |
| FR-19 | Fix verify command backtick stripping | Could | M10 |

## Non-Functional Requirements

| ID | Requirement | Category |
|----|-------------|----------|
| NFR-1 | All 328 existing tests must continue to pass | Quality |
| NFR-2 | No performance regression (each fix is O(1) overhead) | Performance |
| NFR-3 | Changes must be backward compatible with existing dispatch states | Compatibility |

## Out of Scope
- Refactoring `_sanitize_cmd()` into a shared sourced file (future work)
- Adding file locking for race conditions (H5 is document-only)
- Replacing `eval` entirely (would require architectural changes)

## Dependencies
- mktemp (POSIX standard -- already available)
- No new external dependencies required
