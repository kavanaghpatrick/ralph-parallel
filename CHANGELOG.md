# Changelog

## [0.2.4] - 2026-03-09

### Security
- Command sanitizer (`_sanitize_cmd()`) guards all 6 `eval` call sites in `task-completed-gate.sh` and `capture-baseline.sh` — rejects null bytes, command substitution, path traversal
- `shell=True` replaced with `shlex.split` in `validate-pre-merge.py` subprocess calls
- `fsync` added before `os.replace` in `write-dispatch-state.py` for crash-safe atomic writes
- `_sanitize_name()` path validation added to all shell scripts (dispatch-coordinator, session-setup, teammate-idle-gate)
- Rsync source validation in `session-setup.sh` prevents syncing from non-plugin directories

### Fixed
- `fcntl.LOCK_EX` file locking on `mark-tasks-complete.py` prevents concurrent write corruption
- Deep-copy task dependencies in `parse-and-partition.py` prevents cross-group mutation
- Circular dependency detection via Kahn's algorithm (exit code 4 on cycle)
- Duplicate task ID detection with warning
- `grep -oE` calls under `set -e` guarded with `|| true`
- Word-splitting fix in `teammate-idle-gate.sh` (`while read` replaces `for x in $var`)
- `max_teammates` bounds validation (1-20) in `write-dispatch-state.py`
- `typecheck` added to quality command loop in `validate-pre-merge.py`
- `BASH_SOURCE` fallback with `CLAUDE_PLUGIN_ROOT` in `merge-guard.sh`
- Pre-merge conflict check reordered before worktree merge step in `merge.md`
- KeyError guards (`.get()`) across `build-teammate-prompt.py` and `create-task-plan.py`
- `try/except` wrappers on all Python `main()` functions
- Consolidated `baselineSnapshot` jq reads to reduce TOCTOU in `task-completed-gate.sh`
- `merge-guard.sh` and `teammate-idle-gate.sh` documented in SKILL.md hooks table
- `TaskGet` → `TaskList` corrected in `status.md` allowed-tools

### Added
- 25 new tests across 5 test files (155 total)

## [0.2.3] - 2026-03-02

### Added
- `validate-pre-merge.py` pre-merge gate script with 5 checks (checkboxes, groups, build/test/lint quality commands)
- `merge-guard.sh` PreToolUse hook blocking unsafe `status="merged"` writes when tasks are incomplete
- VERIFY task phase gate in `task-completed-gate.sh` (Stage 1.5): detects `[VERIFY]` marker, enforces all preceding tasks complete, runs full quality commands
- `hardFail` baseline comparison in `task-completed-gate.sh` (Stage 5): distinguishes pre-existing failures from new regressions
- `--strict` mode in `mark-tasks-complete.py`: skips unchecked tasks instead of force-marking them
- `hardFail: true` flag in `capture-baseline.sh` when tests fail at dispatch time
- 13 new edge case tests for validate-pre-merge.py (malformed JSON, subprocess timeout, empty tasks, null quality commands)
- 3 new stop hook test scenarios (merged+incomplete, merged+complete, aborted unchanged)
- 4 new strict mode tests for mark-tasks-complete.py

### Fixed
- Stop hook (`dispatch-coordinator.sh`) now checks completion for `status="merged"` instead of allowing immediately — prevents coordinator from bypassing quality gates
- Scan mode includes `status="merged"` dispatches (prevents silent bypass in session restart scenarios)

## [0.2.2] - 2026-03-02

### Added
- `--kb-context` flag in `build-teammate-prompt.py` for injecting knowledge base context into teammate prompts
- Auto-sync plugin source to cache on SessionStart (no manual rsync needed during development)
- Heartbeat-based reclaim safety: active coordinators write heartbeat timestamps, preventing premature reclaim by new sessions
- Configurable reclaim threshold via `RALPH_RECLAIM_THRESHOLD_MINUTES` env var (default: 10)
- 5 new tests for KB context injection and heartbeat/reclaim edge cases (62 total)

### Fixed
- Stop hook rewritten with JSON decision control (`{"decision":"block","reason":"..."}`) replacing exit-2 stderr pattern for reliable blocking
- Block counter with `MAX_BLOCKS` safety valve prevents infinite stop-hook loops (default: 3, configurable via `RALPH_MAX_STOP_BLOCKS`)
- Session-setup distinguishes explicitly released coordinators (`coordinatorSessionId: null`) from missing/legacy state
- Error paths hardened across all hooks with safe defaults and detailed inline comments
- Stale dispatch marking in session-setup restores `gc.auto` immediately

## [0.2.1] - 2026-02-26

### Fixed
- Task ID sorting now uses numeric comparison (fixes dependency ordering for specs with 10+ tasks per phase)
- Quality Commands parser supports bold markdown format (`- **Build**: \`cmd\``) as primary, with code-fence and bare dash as fallbacks
- `CLAUDE_SESSION_ID` now written with `export` keyword for proper env propagation
- Rebalance correctly recomputes `ownedFiles` from remaining tasks (prevents false ownership violations)
- All `eval` calls in task-completed-gate wrapped in subshells (prevents CWD leakage between stages)
- `$PROJECT_ROOT` quoted in parameter expansion (prevents glob injection)
- PROJECT_ROOT derivation standardized to `git rev-parse --show-toplevel` across all hooks
- Stop hook re-injection now includes `mark-tasks-complete.py` reminder
- `git commit -s` advice removed from teammate prompts (wrong format for provenance tracking)
- dispatch.md: `--strategy` flag added to Step 3, partition JSON save path documented, Phase 2 hardcoding replaced with dynamic references, stall recovery uses re-spawn instead of reassign-to-self
- `SendMessage`, `TeamCreate`, `TeamDelete` added to dispatch allowed-tools
- Step number references corrected in templates
- Stale dispatch handling added to `/status` and `/merge` commands

### Added
- `_task_id_key()` helper for correct numeric task ID comparison
- 12 new regression tests (57 total)

## [0.2.0] - 2026-02-22

### Added
- Baseline test snapshot capture and validation
- `validate-tasks-format.py` script for task file format checking
- Worktree strategy support in `parse-and-partition.py`
- Lint gate enforcement in `task-completed-gate.sh` (Stage 6)
- Task completion writeback via `mark-tasks-complete.py`
- Commit provenance tracking via `Signed-off-by` trailers in teammate prompts

### Fixed
- Stale cache symlink resolution during plugin sync
- Worktree isolation strategy mismatch between dispatch and partition
- INVALID display bug in task format validator
- `--strategy` flag wiring in `parse-and-partition.py`

## [0.1.0] - 2026-02-20

### Added
- Initial release
- `/dispatch` command for parallel task execution via Agent Teams
- `/status` command for monitoring parallel execution progress
- `/merge` command for verifying and integrating results after completion
- File-ownership guard hook for preventing cross-team file conflicts
- Task-completed-gate hook for per-task verification
