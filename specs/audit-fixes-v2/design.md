---
spec: audit-fixes-v2
phase: design
created: 2026-03-09
generated: auto
---

# Design: audit-fixes-v2

## Overview

Fix-only design targeting all 36+ audit findings. No new features or architectural changes. Each finding maps to a specific code change in an existing file. Changes grouped by file to minimize context switching.

## Architecture

No architectural changes. The existing plugin structure remains:

```
plugins/ralph-parallel/
  hooks/scripts/   -- shell hook scripts (6 files)
  scripts/         -- Python scripts (6 files) + tests
  commands/        -- markdown commands (3 files)
  skills/          -- SKILL.md
```

## Components

### Component A: Command Sanitizer (Shell)
**Purpose**: Validate commands before execution, replacing raw `eval`
**Responsibilities**:
- Validate command strings against character allowlist
- Reject commands with dangerous metacharacters not in known-safe patterns
- Execute validated commands via `eval` (still needed for shell expansion of pipes/redirects in legitimate commands)
- Log rejected commands to stderr

**Implementation**: Shell function `sanitize_and_run()` defined in each hook that uses eval. Checks for:
- Null bytes
- Backticks outside single-quotes
- `$()` command substitution outside known patterns
- Semicolons not preceded by known safe patterns (e.g., `npm test; echo done`)
- Path traversal (`../` sequences in command string)

Allowlist approach: legitimate commands from `qualityCommands` are JSON values set by the coordinator via `write-dispatch-state.py`. Verify commands come from tasks.md. Both are "trusted at write time" but could be manipulated if files are tampered. The sanitizer adds defense-in-depth.

### Component B: File Locking (Shell)
**Purpose**: Prevent concurrent read-modify-write corruption of dispatch-state.json
**Responsibilities**:
- Acquire exclusive lock before reading dispatch-state.json
- Release lock after write completes
- Timeout after 5 seconds to prevent deadlock

**Implementation**: Use `flock` if available, fall back to `mkdir`-based locking:
```bash
_lock_state() {
  local lockfile="${1}.lock"
  local timeout=5
  local start=$(date +%s)
  while ! mkdir "$lockfile" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge $timeout ]; then
      echo "WARNING: Lock timeout on $lockfile" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "$lockfile"
}
_unlock_state() { rmdir "$1" 2>/dev/null || true; }
```

### Component C: Atomic Write with fsync (Python)
**Purpose**: Ensure data reaches disk before rename
**Responsibilities**:
- Flush and fsync temp file before `os.replace`
- Clean up temp file on failure

**Implementation** (write-dispatch-state.py `_atomic_write`):
```python
def _atomic_write(path: str, data: dict) -> None:
    dir_name = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile(mode='w', dir=dir_name,
                                     suffix='.tmp', delete=False) as f:
        json.dump(data, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
        tmp_path = f.name
    os.replace(tmp_path, path)
```

### Component D: Safe Subprocess (Python)
**Purpose**: Execute commands without `shell=True`
**Responsibilities**:
- Split command strings using `shlex.split()`
- Execute via `subprocess.run` with list args
- Handle commands that legitimately need shell features via controlled `shell=True` with validation

**Implementation** (validate-pre-merge.py):
```python
import shlex

def _run_command(cmd, cwd, timeout=300):
    try:
        args = shlex.split(cmd)
        result = subprocess.run(
            args, cwd=cwd,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=timeout
        )
        return result.returncode, False
    except subprocess.TimeoutExpired:
        return -1, True
```

### Component E: Path Sanitizer (Shell)
**Purpose**: Prevent path traversal via spec/team names
**Responsibilities**:
- Reject names containing `..`, `/`, null bytes
- Reject names starting with `-` or `.`
- Validate against `^[a-zA-Z0-9_-]+$` pattern

**Implementation**:
```bash
_sanitize_name() {
  local name="$1"
  if [ -z "$name" ] || echo "$name" | grep -qE '(\.\.|/|\\|[[:cntrl:]])' || \
     echo "$name" | grep -qE '^[-.]'; then
    echo "ERROR: Invalid spec/team name: $name" >&2
    return 1
  fi
  echo "$name"
}
```

### Component F: Circular Dependency Detector (Python)
**Purpose**: Detect cycles in task dependency graph
**Responsibilities**:
- Build directed graph from task dependencies
- Run topological sort
- Exit with code 4 if cycle detected, listing the cycle

## Data Flow

1. `tasks.md` parsed by `parse-and-partition.py` -- sanitized output written to temp file
2. `write-dispatch-state.py` reads partition, writes dispatch-state.json with fsync
3. Shell hooks read dispatch-state.json with file locking, execute validated commands
4. `mark-tasks-complete.py` updates tasks.md with file locking
5. `validate-pre-merge.py` runs quality commands via safe subprocess

## Technical Decisions

| Decision | Options | Choice | Rationale |
|----------|---------|--------|-----------|
| eval replacement | Remove eval entirely / Allowlist + eval | Allowlist + eval | Some commands legitimately use shell features (pipes, redirects). Full removal would break them. |
| File locking | flock / mkdir-based | mkdir with flock fallback | macOS doesn't ship flock. mkdir is atomic on all POSIX systems. |
| shell=True replacement | shlex.split always / Validate then shell | shlex.split with shell fallback | Most quality commands are simple. For complex ones with pipes, use controlled shell=True after validation. |
| Circular dep detection | DFS / Kahn's algorithm | Kahn's (topological sort) | Simpler to implement, naturally produces the cycle when it fails |
| tmp file naming | mktemp / UUID | mktemp | Already used in capture-baseline.sh. Consistent pattern. |

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `hooks/scripts/task-completed-gate.sh` | Modify | C1: Add command sanitizer, H1: guard grep, H3: reduce TOCTOU, H8: mktemp, H9: path sanitize |
| `scripts/capture-baseline.sh` | Modify | C2: Add command sanitizer |
| `scripts/validate-pre-merge.py` | Modify | C3: Remove shell=True, M: add typecheck to loop |
| `scripts/write-dispatch-state.py` | Modify | C4: Add fsync, M: max_teammates bounds |
| `hooks/scripts/dispatch-coordinator.sh` | Modify | H2: file locking, H3: reduce TOCTOU, H8: mktemp, H9: path sanitize |
| `hooks/scripts/session-setup.sh` | Modify | H2: file locking, H5: reclaim race, H9: path sanitize, H10: rsync guard, M: unquoted SESSION_ID |
| `hooks/scripts/teammate-idle-gate.sh` | Modify | H8: mktemp, H9: path sanitize, M: unquoted GROUP_TASKS |
| `scripts/parse-and-partition.py` | Modify | H6: deep-copy deps, H7: circular dep detection, M: duplicate task IDs, M: serial task deps |
| `scripts/mark-tasks-complete.py` | Modify | H4: file locking |
| `scripts/create-task-plan.py` | Modify | M: KeyError guards, main() error handling |
| `scripts/build-teammate-prompt.py` | Modify | M: KeyError guards, json.loads guard, main() error handling |
| `hooks/scripts/merge-guard.sh` | Modify | M: BASH_SOURCE consistency |
| `commands/merge.md` | Modify | H11: Reorder Step 5 before Step 4 |
| `skills/parallel-workflow/SKILL.md` | Modify | H12: Add missing hooks, M: docs fixes |
| `commands/dispatch.md` | Modify | M: allowed-tools fix |
| `scripts/test_parse_and_partition.py` | Modify | Add tests for _parse_tasks_headers, circular deps, duplicate IDs |
| `scripts/test_write_dispatch_state.py` | Modify | Add fsync verification test |
| `scripts/test_validate_pre_merge.py` | Modify | Add shell=True removal test, typecheck test |
| `scripts/test_build_teammate_prompt.py` | Modify | Add KeyError/malformed input tests |
| `scripts/test_mark_tasks_complete.py` | Modify | Add concurrent write test |

## Error Handling

| Error | Handling | User Impact |
|-------|----------|-------------|
| Command fails sanitization | Log rejection to stderr, exit 2 (block) | Task completion blocked with clear message about rejected command |
| Lock acquisition timeout | Log warning, proceed without lock | Slight race condition risk, better than deadlock |
| fsync fails | Exception propagates, temp file cleaned | Write fails visibly rather than silently corrupting |
| Circular dependency detected | Exit code 4 with cycle description | Clear error message, user must fix tasks.md |
| Path traversal attempt | Reject with error, exit 0 (allow through) | Spec not found = no quality gate = pass-through |

## Existing Patterns to Follow
- `set -euo pipefail` at top of all shell scripts (`hooks/scripts/*.sh`)
- `|| true` / `|| VAR=""` for non-fatal jq reads (all shell hooks)
- `tempfile.NamedTemporaryFile` + `os.replace` for atomic writes (`write-dispatch-state.py:23-31`)
- `argparse` + `json.load` in all Python script mains
- Conventional commits in commit messages (`fix(scope): description`)
