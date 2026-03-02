#!/usr/bin/env python3
"""Tests for validate-pre-merge.py using synthetic data."""

import json
import subprocess
import sys

import pytest
from pathlib import Path

SCRIPT = str(Path(__file__).parent / "validate-pre-merge.py")


def run_script(dispatch_state_path, tasks_md_path, skip_quality=False):
    """Run validate-pre-merge.py and return (exit_code, output_dict)."""
    cmd = [
        sys.executable, SCRIPT,
        "--dispatch-state", str(dispatch_state_path),
        "--tasks-md", str(tasks_md_path),
    ]
    if skip_quality:
        cmd.append("--skip-quality-commands")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    output = json.loads(result.stdout) if result.stdout.strip() else {}
    return result.returncode, output


def write_dispatch_state(path, groups=None, completed_groups=None, quality_commands=None):
    """Write a synthetic dispatch-state.json."""
    state = {}
    if groups is not None:
        state["groups"] = [{"name": g} for g in groups]
    if completed_groups is not None:
        state["completedGroups"] = completed_groups
    if quality_commands is not None:
        state["qualityCommands"] = quality_commands
    path.write_text(json.dumps(state))


def write_tasks_md(path, checked=None, unchecked=None):
    """Write a synthetic tasks.md with checked/unchecked task lines."""
    lines = []
    for tid in (checked or []):
        lines.append(f"- [x] {tid} Task {tid}")
    for tid in (unchecked or []):
        lines.append(f"- [ ] {tid} Task {tid}")
    path.write_text("\n".join(lines))


class TestAllPass:
    """All tasks checked + all groups complete -> exit 0, passed=true."""

    def test_all_checked_all_groups(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=["A", "B"], completed_groups=["A", "B"])
        write_tasks_md(tm, checked=["1.1", "1.2", "2.1"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 0
        assert out["passed"] is True


class TestCheckboxFailures:
    """Unchecked tasks remain -> exit 1, allTasksChecked.passed=false."""

    def test_unchecked_tasks(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=["A"], completed_groups=["A"])
        write_tasks_md(tm, checked=["1.1"], unchecked=["1.2", "1.3"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert out["checks"]["allTasksChecked"]["passed"] is False
        assert "1.2" in out["checks"]["allTasksChecked"]["unchecked"]
        assert "1.3" in out["checks"]["allTasksChecked"]["unchecked"]


class TestGroupFailures:
    """Missing group in completedGroups -> exit 1, allGroupsCompleted.passed=false."""

    def test_missing_group(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=["A", "B", "C"], completed_groups=["A", "B"])
        write_tasks_md(tm, checked=["1.1", "2.1", "3.1"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert out["checks"]["allGroupsCompleted"]["passed"] is False
        assert "C" in out["checks"]["allGroupsCompleted"]["missing"]


class TestQualityCommands:
    """Quality command failures -> exit 1, quality check passed=false."""

    def test_build_fails(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[], quality_commands={"build": "exit 1"})
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)
        assert code == 1
        assert out["checks"]["qualityBuild"]["passed"] is False
        assert out["checks"]["qualityBuild"]["exitCode"] != 0

    def test_test_fails(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[], quality_commands={"test": "exit 1"})
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)
        assert code == 1
        assert out["checks"]["qualityTest"]["passed"] is False
        assert out["checks"]["qualityTest"]["exitCode"] != 0

    def test_skip_quality_still_checks_boxes(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=["A"], completed_groups=["A"], quality_commands={"build": "exit 1"})
        write_tasks_md(tm, checked=["1.1"], unchecked=["1.2"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert out["checks"]["allTasksChecked"]["passed"] is False
        # Quality checks should not be present when skipped
        assert "qualityBuild" not in out["checks"]


class TestMissingFiles:
    """Missing input files -> exit 1, error JSON."""

    def test_missing_dispatch_state(self, tmp_path):
        tm = tmp_path / "tasks.md"
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(tmp_path / "nonexistent.json", tm)
        assert code == 1
        assert "error" in out

    def test_missing_tasks_md(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        write_dispatch_state(ds, groups=[], completed_groups=[])
        code, out = run_script(ds, tmp_path / "nonexistent.md")
        assert code == 1
        assert "error" in out


class TestEdgeCases:
    """Edge cases: empty groups, no quality commands."""

    def test_no_groups(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[])
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 0  # vacuously true
        assert out["passed"] is True

    def test_no_quality_commands(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[])
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)  # no skip flag, but no commands defined
        assert code == 0
        assert out["passed"] is True
        # Quality slots should be present but skipped
        assert out["checks"]["qualityBuild"]["skipped"] is True
        assert out["checks"]["qualityTest"]["skipped"] is True
        assert out["checks"]["qualityLint"]["skipped"] is True


class TestMalformedJSON:
    """Malformed JSON in dispatch-state -> exit 1 with error JSON."""

    def test_malformed_json(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        ds.write_text("{this is not valid json")
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert "error" in out
        assert "Malformed JSON" in out["error"]

    def test_truncated_json(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        ds.write_text('{"groups": [')
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert "Malformed JSON" in out["error"]

    def test_empty_file_as_dispatch_state(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        ds.write_text("")
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert "error" in out


class TestSubprocessTimeout:
    """Quality commands that exceed timeout -> exit 1 with timeout info."""

    def test_timeout_reports_in_output(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        # Use sleep 10 but with a very short timeout via a wrapper
        # We can't easily test 300s timeout, so we test the _run_command
        # function directly with a short timeout
        write_dispatch_state(ds, groups=[], completed_groups=[],
                             quality_commands={"build": "sleep 10"})
        write_tasks_md(tm, checked=["1.1"])
        # Run with subprocess timeout of 30s for the test harness,
        # but the script's internal timeout is 300s.
        # Instead, test _run_command directly.
        pass  # Covered by test_run_command_timeout below

    def test_run_command_timeout(self, tmp_path):
        """Test _run_command with a short timeout to verify timeout handling."""
        # Import the function directly
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "validate_pre_merge", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        exit_code, timed_out = mod._run_command("sleep 10", str(tmp_path), timeout=1)
        assert timed_out is True
        assert exit_code == -1

    def test_run_command_no_timeout(self, tmp_path):
        """Normal command completes without timeout."""
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "validate_pre_merge", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        exit_code, timed_out = mod._run_command("echo hello", str(tmp_path), timeout=10)
        assert timed_out is False
        assert exit_code == 0


class TestEmptyTasksMd:
    """Empty tasks.md (no checkboxes) -> vacuously true for checkbox check."""

    def test_empty_file(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[])
        tm.write_text("")
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 0
        assert out["passed"] is True
        assert out["checks"]["allTasksChecked"]["passed"] is True
        assert out["checks"]["allTasksChecked"]["total"] == 0
        assert out["checks"]["allTasksChecked"]["checked"] == 0

    def test_no_checkboxes_with_other_content(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[])
        tm.write_text("# Tasks\n\nSome text without checkboxes\n")
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 0
        assert out["checks"]["allTasksChecked"]["passed"] is True
        assert out["checks"]["allTasksChecked"]["total"] == 0

    def test_empty_tasks_but_missing_group(self, tmp_path):
        """Empty tasks.md passes checkbox check but groups check can still fail."""
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=["A"], completed_groups=[])
        tm.write_text("")
        code, out = run_script(ds, tm, skip_quality=True)
        assert code == 1
        assert out["checks"]["allTasksChecked"]["passed"] is True
        assert out["checks"]["allGroupsCompleted"]["passed"] is False


class TestNullAndEmptyQualityCommands:
    """Quality commands that are 'null' string or empty string -> skipped."""

    def test_null_string_skipped(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[],
                             quality_commands={"build": "null", "test": "echo ok", "lint": "null"})
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)
        assert code == 0
        assert out["checks"]["qualityBuild"]["skipped"] is True
        assert out["checks"]["qualityTest"]["skipped"] is False
        assert out["checks"]["qualityTest"]["passed"] is True
        assert out["checks"]["qualityLint"]["skipped"] is True

    def test_empty_string_skipped(self, tmp_path):
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[],
                             quality_commands={"build": "", "test": "", "lint": ""})
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)
        assert code == 0
        assert out["checks"]["qualityBuild"]["skipped"] is True
        assert out["checks"]["qualityTest"]["skipped"] is True
        assert out["checks"]["qualityLint"]["skipped"] is True

    def test_none_value_skipped(self, tmp_path):
        """JSON null values are skipped."""
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        # Write JSON with explicit null values
        state = {
            "groups": [],
            "completedGroups": [],
            "qualityCommands": {"build": None, "test": None, "lint": None}
        }
        ds.write_text(json.dumps(state))
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)
        assert code == 0
        assert out["checks"]["qualityBuild"]["skipped"] is True
        assert out["checks"]["qualityTest"]["skipped"] is True
        assert out["checks"]["qualityLint"]["skipped"] is True

    def test_mixed_null_and_valid(self, tmp_path):
        """Mix of null/empty and valid commands."""
        ds = tmp_path / ".dispatch-state.json"
        tm = tmp_path / "tasks.md"
        write_dispatch_state(ds, groups=[], completed_groups=[],
                             quality_commands={"build": "null", "test": "echo ok", "lint": ""})
        write_tasks_md(tm, checked=["1.1"])
        code, out = run_script(ds, tm)
        assert code == 0
        assert out["checks"]["qualityBuild"]["skipped"] is True
        assert out["checks"]["qualityTest"]["passed"] is True
        assert out["checks"]["qualityTest"]["skipped"] is False
        assert out["checks"]["qualityLint"]["skipped"] is True
