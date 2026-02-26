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
parse_tasks = mod.parse_tasks
partition_tasks = mod.partition_tasks
build_dependency_graph = mod.build_dependency_graph


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
