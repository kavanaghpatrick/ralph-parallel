# Changelog

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
