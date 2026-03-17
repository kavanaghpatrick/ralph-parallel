---
spec: deep-audit-fixes
phase: research
created: 2026-03-17
generated: auto
---

# Research: deep-audit-fixes

## Executive Summary

A 10-agent deep audit identified 18 issues across the ralph-parallel plugin (3 critical, 5 high, 10 medium). All relate to input validation gaps, POSIX compliance, and defensive coding. The codebase is well-structured with 328 passing tests providing a safety net. All fixes are localized edits with no architectural changes needed.

## Codebase Analysis

### Existing Patterns
- `_sanitize_cmd()` in `task-completed-gate.sh:17-35` and `capture-baseline.sh:19-37` -- duplicate functions, both need strengthening
- `_sanitize_name()` in 4 files validates `^[a-zA-Z0-9][a-zA-Z0-9_-]*$` -- good existing pattern to reuse for SESSION_ID
- `mktemp` already used in `capture-baseline.sh:93` for atomic writes -- pattern to replicate for `.tmp.$$` replacements
- `grep -qE` used extensively for regex matching -- some instances can switch to `grep -qF` for literal matching
- `printf '%s'` used correctly in most places -- one `printf '%b'` slip in teammate-idle-gate.sh:158

### Dependencies
- `jq` -- used for all JSON operations (available on all targets)
- `mktemp` -- POSIX standard, already used in capture-baseline.sh
- `timeout` -- GNU coreutils, may not be on macOS by default (gtimeout via Homebrew)
- Python 3.11+ -- `dict | None` syntax works natively, no `__future__` needed

### Constraints
- bash 3.2+ on macOS (no `${var,,}`, no `readarray`, no `|&`)
- All changes must maintain backward compatibility with existing dispatch states
- Test suites must continue to pass (328 tests baseline)
- No architectural changes -- all fixes are localized function/line edits

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All fixes are well-understood code changes |
| Effort Estimate | M | 18 issues, mostly 1-5 line changes each |
| Risk Level | Low | Strong test coverage, localized changes |

## Recommendations
1. Fix CRITICAL issues first, run full test suite as checkpoint
2. Group HIGH/MEDIUM fixes by file to minimize file-switching overhead
3. Add tests for new validation logic (C1, C2, C3 especially)
4. Document race condition (H5) rather than attempt complex locking
