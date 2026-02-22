# Changelog

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
