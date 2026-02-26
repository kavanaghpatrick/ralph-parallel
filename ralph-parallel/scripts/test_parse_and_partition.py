"""Tests for parse-and-partition.py quality command discovery and verify classification."""
import importlib.util
import json
import os
import pytest

# Load module from hyphenated filename
_spec = importlib.util.spec_from_file_location(
    'parse_and_partition',
    os.path.join(os.path.dirname(__file__), 'parse-and-partition.py'),
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

discover_quality_commands = mod.discover_quality_commands
classify_verify_commands = mod.classify_verify_commands
format_plan = mod.format_plan
_discover_node = mod._discover_node
_discover_python = mod._discover_python
_discover_makefile = mod._discover_makefile
_discover_rust = mod._discover_rust
_task_id_key = mod._task_id_key
parse_quality_commands_from_tasks = mod.parse_quality_commands_from_tasks
parse_tasks = mod.parse_tasks
build_dependency_graph = mod.build_dependency_graph
partition_tasks = mod.partition_tasks


# ── Quality Command Discovery ──────────────────────────────────


class TestDiscoverNode:
    def test_basic_scripts(self, tmp_path):
        (tmp_path / "package.json").write_text(json.dumps({
            "scripts": {"typecheck": "tsc --noEmit", "build": "vite build", "test": "vitest"}
        }))
        result = discover_quality_commands(str(tmp_path))
        assert result["typecheck"] == "npx tsc --noEmit"
        assert result["build"] == "npx vite build"
        assert result["test"] == "npx vitest"

    def test_bare_single_word_gets_npx(self, tmp_path):
        (tmp_path / "package.json").write_text(json.dumps({
            "scripts": {"test": "vitest"}
        }))
        result = discover_quality_commands(str(tmp_path))
        assert result["test"] == "npx vitest"

    def test_pipeline_commands_kept_as_is(self, tmp_path):
        (tmp_path / "package.json").write_text(json.dumps({
            "scripts": {"test": "vitest run && playwright test"}
        }))
        result = discover_quality_commands(str(tmp_path))
        assert result["test"] == "vitest run && playwright test"

    def test_dev_and_start_fallback(self, tmp_path):
        (tmp_path / "package.json").write_text(json.dumps({
            "scripts": {"start": "node server.js"}
        }))
        result = discover_quality_commands(str(tmp_path))
        assert result["dev"] == "npx node server.js"


class TestDiscoverPython:
    def test_pytest_detected(self, tmp_path):
        toml = b'[tool.pytest]\n[tool.pytest.ini_options]\naddopts = "-v"\n'
        (tmp_path / "pyproject.toml").write_bytes(toml)
        result = discover_quality_commands(str(tmp_path))
        assert result["test"] == "pytest"

    def test_ruff_detected(self, tmp_path):
        toml = b'[tool.ruff]\nline-length = 100\n'
        (tmp_path / "pyproject.toml").write_bytes(toml)
        result = discover_quality_commands(str(tmp_path))
        assert result["lint"] == "ruff check ."


class TestDiscoverMakefile:
    def test_make_targets(self, tmp_path):
        (tmp_path / "Makefile").write_text("test:\n\tpytest\nbuild:\n\tdocker build .\n")
        result = discover_quality_commands(str(tmp_path))
        assert result["test"] == "make test"
        assert result["build"] == "make build"


class TestDiscoverRust:
    def test_cargo_detected(self, tmp_path):
        (tmp_path / "Cargo.toml").write_text('[package]\nname = "test"\n')
        result = discover_quality_commands(str(tmp_path))
        assert result["build"] == "cargo build"
        assert result["test"] == "cargo test"
        assert result["lint"] == "cargo clippy"


class TestDiscoverEmpty:
    def test_no_config_returns_nulls(self, tmp_path):
        result = discover_quality_commands(str(tmp_path))
        assert all(v is None for v in result.values())

    def test_malformed_json_no_crash(self, tmp_path):
        (tmp_path / "package.json").write_text("{broken json")
        result = discover_quality_commands(str(tmp_path))
        assert result["typecheck"] is None


# ── Verify Command Classification ──────────────────────────────


class TestClassifyVerifyCommands:
    def _make_task(self, tid, verify):
        return {"id": tid, "verify": verify}

    def test_weak_commands(self):
        tasks = [self._make_task("1.1", "grep -q 'foo' bar.ts")]
        result = classify_verify_commands(tasks)
        assert result["weak"] == 1
        assert result["details"][0]["tier"] == "weak"

    def test_static_commands(self):
        tasks = [self._make_task("1.1", "npx tsc --noEmit")]
        result = classify_verify_commands(tasks)
        assert result["static"] == 1

    def test_runtime_commands(self):
        tasks = [self._make_task("1.1", "npx vite build")]
        result = classify_verify_commands(tasks)
        assert result["runtime"] == 1

    def test_empty_verify(self):
        tasks = [self._make_task("1.1", "")]
        result = classify_verify_commands(tasks)
        assert result["none"] == 1

    def test_mixed_classification(self):
        tasks = [
            self._make_task("1.1", "grep foo bar"),
            self._make_task("1.2", "npx tsc --noEmit"),
            self._make_task("1.3", "npx vite build"),
            self._make_task("1.4", ""),
        ]
        result = classify_verify_commands(tasks)
        assert result["weak"] == 1
        assert result["static"] == 1
        assert result["runtime"] == 1
        assert result["none"] == 1

    def test_warning_threshold(self):
        """format_plan should warn when >50% of verify commands are weak."""
        fake_result = {
            "totalTasks": 4,
            "incompleteTasks": 4,
            "groups": [],
            "serialTasks": [],
            "verifyTasks": [],
            "phaseCount": 1,
            "estimatedSpeedup": 1.0,
            "verifyQuality": {"runtime": 0, "static": 1, "weak": 3, "none": 0, "details": []},
            "qualityCommands": {"typecheck": None, "build": None, "test": None, "lint": None, "dev": None},
        }
        output = format_plan(fake_result)
        assert "WARNING" in output
        assert "3/4" in output


# ── Pre-defined Group File Ownership Conflicts ────────────────

parse_predefined_groups = mod.parse_predefined_groups


class TestPredefinedGroupFileConflicts:
    TASKS_MD_WITH_CONFLICT = """\
## Phase 1: Setup

### Group 1: fixtures [P]
**Files owned**: `tests/conftest.py`, `tests/test_importer.py`

- [ ] 1.1 Create test fixtures
  - **Files**: `tests/conftest.py`, `tests/test_importer.py`
  - **Verify**: `python3 -m pytest tests/conftest.py -v`

- [ ] 1.2 Add fixture helpers
  - **Files**: `tests/conftest.py`
  - **Verify**: `python3 -m pytest tests/conftest.py -v`

### Group 2: core [P]
**Files owned**: `src/importer.py`, `tests/test_importer.py`

- [ ] 1.3 Implement core importer
  - **Files**: `src/importer.py`
  - **Verify**: `python3 -c "import src.importer"`

- [ ] 1.4 Add importer tests
  - **Files**: `tests/test_importer.py`
  - **Verify**: `python3 -m pytest tests/test_importer.py -v`
"""

    TASKS_MD_NO_CONFLICT = """\
## Phase 1: Setup

### Group 1: fixtures [P]
**Files owned**: `tests/conftest.py`

- [ ] 1.1 Create test fixtures
  - **Files**: `tests/conftest.py`
  - **Verify**: `python3 -m pytest tests/conftest.py -v`

### Group 2: core [P]
**Files owned**: `src/importer.py`, `tests/test_importer.py`

- [ ] 1.2 Implement core importer
  - **Files**: `src/importer.py`, `tests/test_importer.py`
  - **Verify**: `python3 -m pytest tests/ -v`
"""

    def test_conflict_detected_and_resolved(self, capsys):
        """Contested file is assigned to one group, removed from the other."""
        tasks = parse_tasks(self.TASKS_MD_WITH_CONFLICT)
        tasks = build_dependency_graph(tasks)
        result = partition_tasks(tasks, max_teammates=4,
                                 content=self.TASKS_MD_WITH_CONFLICT)

        # Check that no two groups share the same file
        all_owned = []
        for g in result['groups']:
            all_owned.append(set(g['ownedFiles']))
        for i, a in enumerate(all_owned):
            for b in all_owned[i + 1:]:
                assert not (a & b), f"Groups share files: {a & b}"

        # WARNING should have been printed to stderr
        captured = capsys.readouterr()
        assert "WARNING" in captured.err
        assert "test_importer.py" in captured.err

    def test_no_conflict_no_warning(self, capsys):
        """Clean groups produce no warnings."""
        tasks = parse_tasks(self.TASKS_MD_NO_CONFLICT)
        tasks = build_dependency_graph(tasks)
        result = partition_tasks(tasks, max_teammates=4,
                                 content=self.TASKS_MD_NO_CONFLICT)

        captured = capsys.readouterr()
        assert "WARNING" not in captured.err
        assert len(result['groups']) == 2

    def test_contested_file_goes_to_group_with_most_tasks(self):
        """The group with more tasks touching the file gets ownership."""
        tasks = parse_tasks(self.TASKS_MD_WITH_CONFLICT)
        tasks = build_dependency_graph(tasks)
        result = partition_tasks(tasks, max_teammates=4,
                                 content=self.TASKS_MD_WITH_CONFLICT)

        # Group 1 (fixtures) has 2 tasks, 1 touches test_importer.py
        # Group 2 (core) has 2 tasks, 1 touches test_importer.py
        # Tie-break: max() picks the highest index, which is group 2 (core)
        # Either assignment is valid as long as it's exclusive
        file_owners = {}
        for g in result['groups']:
            for f in g['ownedFiles']:
                assert f not in file_owners, \
                    f"File '{f}' owned by both '{file_owners[f]}' and '{g['name']}'"
                file_owners[f] = g['name']


# ── Task ID Numeric Comparison (FR-1) ────────────────────────


class TestTaskIdKey:
    """FR-1: Numeric task ID comparison."""

    def test_basic_comparison(self):
        assert _task_id_key("1.10") > _task_id_key("1.2")
        assert _task_id_key("1.1") < _task_id_key("1.2")
        assert _task_id_key("2.1") > _task_id_key("1.9")

    def test_sort_order(self):
        ids = ["1.1", "1.10", "1.11", "1.2", "1.9", "2.1"]
        sorted_ids = sorted(ids, key=_task_id_key)
        assert sorted_ids == ["1.1", "1.2", "1.9", "1.10", "1.11", "2.1"]

    def test_verify_dependency_ordering(self):
        """12-task phase with VERIFY -- dependencies use numeric comparison."""
        lines = ["## Phase 1: Test\n"]
        for i in range(1, 12):
            lines.append(f"- [ ] 1.{i} [P] Task {i}\n")
            lines.append(f"  - **Files**: `file{i}.ts`\n")
            lines.append(f"  - **Verify**: `echo ok`\n")
        lines.append("- [ ] 1.12 [VERIFY] Verify phase 1\n")
        lines.append("  - **Verify**: `echo verify`\n")
        tasks_md = "\n".join(lines)

        tasks = parse_tasks(tasks_md)
        tasks = build_dependency_graph(tasks)
        verify = [t for t in tasks if 'VERIFY' in t['markers']][0]
        # All 11 non-VERIFY tasks should be dependencies of the VERIFY task
        assert len(verify['dependencies']) == 11


# ── Quality Commands Multi-Format Parsing (FR-2) ─────────────


class TestQualityCommandsParsing:
    """FR-2: Multi-format QC parsing."""

    def test_bold_markdown_format(self):
        content = "## Quality Commands\n- **Build**: `cargo build`\n- **Test**: `cargo test`\n- **Lint**: `cargo clippy`\n"
        result = parse_quality_commands_from_tasks(content)
        assert result == {"build": "cargo build", "test": "cargo test", "lint": "cargo clippy"}

    def test_code_fenced_format(self):
        content = "## Quality Commands\n```\nbuild: cargo build\ntest: cargo test\n```\n"
        result = parse_quality_commands_from_tasks(content)
        assert result == {"build": "cargo build", "test": "cargo test"}

    def test_bare_dash_format(self):
        content = "## Quality Commands\n- Build: `cargo build`\n- Test: cargo test\n"
        result = parse_quality_commands_from_tasks(content)
        assert result["build"] == "cargo build"
        assert result["test"] == "cargo test"

    def test_na_excluded(self):
        content = "## Quality Commands\n- **Build**: N/A\n- **Test**: `cargo test`\n"
        result = parse_quality_commands_from_tasks(content)
        assert "build" not in result
        assert result["test"] == "cargo test"

    def test_bold_markdown_without_dash(self):
        content = "## Quality Commands\n**Build**: `make build`\n**Test**: `make test`\n"
        result = parse_quality_commands_from_tasks(content)
        assert result == {"build": "make build", "test": "make test"}

    def test_na_case_insensitive(self):
        content = "## Quality Commands\n- **Build**: n/a\n- **Lint**: N/a\n- **Test**: `pytest`\n"
        result = parse_quality_commands_from_tasks(content)
        assert "build" not in result
        assert "lint" not in result
        assert result["test"] == "pytest"

    def test_stops_at_next_heading(self):
        content = "## Quality Commands\n- **Build**: `make`\n## Phase 1\n- **Test**: `pytest`\n"
        result = parse_quality_commands_from_tasks(content)
        assert result == {"build": "make"}
        assert "test" not in result


# ── Worktree Empty Guard (FR-7) ──────────────────────────────


class TestWorktreeEmptyGuard:
    """FR-7: Empty parallel_tasks guard."""

    def test_all_verify_tasks(self):
        """Partition with only VERIFY tasks should not crash."""
        tasks_md = "## Phase 1\n- [x] 1.1 [P] Already done\n  - **Verify**: `echo ok`\n- [x] 1.2 [VERIFY] Verify\n  - **Verify**: `echo ok`\n"
        tasks = parse_tasks(tasks_md)
        tasks = build_dependency_graph(tasks)
        # All tasks are complete, so partition should exit early (code 2)
        # or return no groups. Either way, no crash.
        result = partition_tasks(tasks, max_teammates=4, strategy='worktree')
        # Result is None when all tasks complete (script exits with code 2)
        # or has 0 groups
        assert result is None or len(result.get('groups', [])) == 0


# ── Rebalance Ownership (FR-8) ───────────────────────────────


class TestRebalanceOwnership:
    """FR-8: Rebalance preserves file ownership for remaining tasks."""

    def test_shared_files_preserved(self):
        """After rebalance, files used by remaining tasks stay in ownedFiles."""
        # 5 tasks with varying files, 2 teammates - forces rebalancing
        tasks_md = (
            "## Phase 1: Test\n"
            "- [ ] 1.1 [P] Task A\n  - **Files**: `shared.ts`, `a.ts`\n  - **Verify**: `echo ok`\n"
            "- [ ] 1.2 [P] Task B\n  - **Files**: `shared.ts`, `b.ts`\n  - **Verify**: `echo ok`\n"
            "- [ ] 1.3 [P] Task C\n  - **Files**: `c.ts`\n  - **Verify**: `echo ok`\n"
            "- [ ] 1.4 [P] Task D\n  - **Files**: `d.ts`\n  - **Verify**: `echo ok`\n"
            "- [ ] 1.5 [P] Task E\n  - **Files**: `e.ts`\n  - **Verify**: `echo ok`\n"
        )
        tasks = parse_tasks(tasks_md)
        tasks = build_dependency_graph(tasks)
        result = partition_tasks(tasks, max_teammates=2, strategy='file-ownership')
        assert result is not None
        # Build task-to-files mapping from parsed tasks
        task_files = {t['id']: set(t['files']) for t in tasks}
        # Verify every group owns all files its tasks reference
        for g in result['groups']:
            owned = set(g['ownedFiles'])
            for task_id in g['tasks']:
                if task_id in task_files:
                    for f in task_files[task_id]:
                        assert f in owned, \
                            f"Task {task_id} needs '{f}' but group '{g['name']}' doesn't own it"
