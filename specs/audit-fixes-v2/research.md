---
spec: audit-fixes-v2
phase: research
created: 2026-03-09
generated: auto
---

# Research: audit-fixes-v2

## Executive Summary

Comprehensive security and reliability audit (GitHub issue #8) identified 36+ findings across the ralph-parallel plugin. All critical findings involve `eval`/`shell=True` on untrusted input. High findings involve race conditions, missing atomicity, and documentation gaps. All fixes are feasible within existing architecture -- no structural redesign needed.

## Codebase Analysis

### Existing Patterns
- Shell hooks use `set -euo pipefail` consistently (`hooks/scripts/*.sh`)
- Python scripts use `argparse` + `json.load` pattern (`scripts/*.py`)
- Atomic writes exist in `write-dispatch-state.py` via `tempfile.NamedTemporaryFile` + `os.replace`
- Test files exist for most Python scripts (`scripts/test_*.py`)
- Quality command values come from `dispatch-state.json` which is written from `tasks.md` parse output

### Dependencies
- `jq` (all shell scripts)
- `python3` (all Python scripts)
- `flock` (needed for H2 fix -- available on macOS via `flock` or emulated with `mkdir`)
- `mktemp` with template (already used in capture-baseline.sh)

### Constraints
- Shell scripts must remain POSIX-compatible where possible (BSD date vs GNU)
- `eval` cannot simply be removed -- commands must still execute. Allowlist validation is the mitigation.
- `flock` not universally available on macOS -- use `mkdir`-based locking as fallback
- Hooks timeout limits: task-completed-gate 300s, merge-guard 30s, others 10s

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | High | All fixes use standard shell/Python patterns |
| Effort Estimate | L | 36+ findings across 15+ files |
| Risk Level | Medium | eval sanitization must not break legitimate commands |

## Recommendations
1. Replace `eval` with allowlist-validated execution in all shell hooks
2. Add `f.flush(); os.fsync(f.fileno())` before `os.replace` in write-dispatch-state.py
3. Use `subprocess.run` with list args (no `shell=True`) in validate-pre-merge.py
4. Add `flock`/`mkdir`-based locking for dispatch-state.json read-modify-write
5. Add `.get()` guards for all dict accesses in Python scripts
6. Implement circular dependency detection in parse-and-partition.py
7. Use `mktemp -d` for unique tmp paths instead of predictable names
8. Add path sanitization for spec/team names
