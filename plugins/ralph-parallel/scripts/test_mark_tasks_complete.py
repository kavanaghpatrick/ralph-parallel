#!/usr/bin/env python3
"""Tests for mark-tasks-complete.py using synthetic data."""

import json
import os
import subprocess
import sys
import tempfile
import threading

import pytest

SCRIPT = os.path.join(os.path.dirname(__file__), "mark-tasks-complete.py")


def run_script(dispatch_state_path, tasks_md_path, dry_run=False, strict=False):
    """Run mark-tasks-complete.py and return (exit_code, stdout_json, tasks_md_content)."""
    cmd = [
        sys.executable, SCRIPT,
        "--dispatch-state", dispatch_state_path,
        "--tasks-md", tasks_md_path,
    ]
    if dry_run:
        cmd.append("--dry-run")
    if strict:
        cmd.append("--strict")
    result = subprocess.run(cmd, capture_output=True, text=True)
    stdout_json = json.loads(result.stdout) if result.stdout.strip() else {}
    tasks_content = ""
    if os.path.isfile(tasks_md_path):
        with open(tasks_md_path, "r") as f:
            tasks_content = f.read()
    return result.returncode, stdout_json, tasks_content


class TestNormalCompletion:
    """Test case 1: Normal completion -- 2 groups completed, 4 tasks marked."""

    def test_two_groups_four_tasks(self, tmp_path):
        dispatch_state = {
            "completedGroups": ["group-a", "group-b"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2"]},
                {"name": "group-b", "tasks": ["2.1", "2.2"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [ ] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
            "- [ ] 2.1 Third task\n"
            "- [ ] 2.2 Fourth task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path)

        assert exit_code == 0
        assert output["marked"] == 4
        assert output["alreadyComplete"] == 0
        assert output["notFound"] == 0
        assert "- [x] 1.1 First task" in content
        assert "- [x] 1.2 Second task" in content
        assert "- [x] 2.1 Third task" in content
        assert "- [x] 2.2 Fourth task" in content
        assert "- [ ]" not in content


class TestPartialCompletion:
    """Test case 2: Partial completion -- 1 of 2 groups completed."""

    def test_one_group_completed(self, tmp_path):
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2"]},
                {"name": "group-b", "tasks": ["2.1", "2.2"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [ ] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
            "- [ ] 2.1 Third task\n"
            "- [ ] 2.2 Fourth task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path)

        assert exit_code == 0
        assert output["marked"] == 2
        assert output["alreadyComplete"] == 0
        assert output["notFound"] == 0
        # group-a tasks marked
        assert "- [x] 1.1 First task" in content
        assert "- [x] 1.2 Second task" in content
        # group-b tasks still incomplete
        assert "- [ ] 2.1 Third task" in content
        assert "- [ ] 2.2 Fourth task" in content


class TestIdempotency:
    """Test case 3: Idempotency -- already-marked tasks stay marked."""

    def test_already_marked_tasks(self, tmp_path):
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [x] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path)

        assert exit_code == 0
        assert output["marked"] == 1
        assert output["alreadyComplete"] == 1
        assert output["notFound"] == 0
        assert "- [x] 1.1 First task" in content
        assert "- [x] 1.2 Second task" in content


class TestMissingCompletedGroups:
    """Test case 4: Missing completedGroups key -- no changes."""

    def test_no_completed_groups_key(self, tmp_path):
        dispatch_state = {
            "groups": [
                {"name": "group-a", "tasks": ["1.1"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [ ] 1.1 First task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path)

        assert exit_code == 0
        assert output["marked"] == 0
        assert output["alreadyComplete"] == 0
        assert output["notFound"] == 0
        # File should be unchanged
        assert "- [ ] 1.1 First task" in content


class TestDryRun:
    """Test case 5: --dry-run doesn't modify file."""

    def test_dry_run_no_modification(self, tmp_path):
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [ ] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path, dry_run=True)

        assert exit_code == 0
        assert output["marked"] == 2
        assert output["dryRun"] is True
        # File should NOT be modified
        assert "- [ ] 1.1 First task" in content
        assert "- [ ] 1.2 Second task" in content


class TestStrictMode:
    """Test case 6: --strict mode cross-check behavior."""

    def test_strict_all_already_checked(self, tmp_path):
        """All tasks in completedGroup are already [x] -> exit 0, skipped=[]."""
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [x] 1.1 First task\n"
            "- [x] 1.2 Second task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path, strict=True)

        assert exit_code == 0
        assert output["strict"] is True
        assert output["skipped"] == []
        assert output["alreadyComplete"] == 2
        assert output["marked"] == 0
        # File unchanged
        assert "- [x] 1.1 First task" in content
        assert "- [x] 1.2 Second task" in content

    def test_strict_unchecked_in_completed_group(self, tmp_path):
        """Task 2.1 is [ ] in tasks.md but in completedGroup -> exit 2, skipped=["2.1"]."""
        dispatch_state = {
            "completedGroups": ["group-b"],
            "groups": [
                {"name": "group-b", "tasks": ["2.1"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [ ] 2.1 Third task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path, strict=True)

        assert exit_code == 2
        assert output["strict"] is True
        assert output["skipped"] == ["2.1"]
        assert output["marked"] == 0
        # File should NOT be modified (strict skips, doesn't mark)
        assert "- [ ] 2.1 Third task" in content

    def test_strict_mixed_checked_unchecked(self, tmp_path):
        """Some [x] some [ ] -> exit 2, alreadyComplete counts [x], skipped lists [ ]."""
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2", "1.3"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [x] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
            "- [ ] 1.3 Third task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path, strict=True)

        assert exit_code == 2
        assert output["strict"] is True
        assert output["alreadyComplete"] == 1
        assert output["skipped"] == ["1.2", "1.3"]
        assert output["marked"] == 0
        # File should NOT be modified
        assert "- [x] 1.1 First task" in content
        assert "- [ ] 1.2 Second task" in content
        assert "- [ ] 1.3 Third task" in content

    def test_no_strict_unchanged(self, tmp_path):
        """Same input without --strict -> exit 0, tasks marked [x] (backward compat)."""
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2", "1.3"]},
            ],
        }
        tasks_md = (
            "# Tasks\n"
            "- [x] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
            "- [ ] 1.3 Third task\n"
        )

        state_path = str(tmp_path / "dispatch-state.json")
        tasks_path = str(tmp_path / "tasks.md")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        exit_code, output, content = run_script(state_path, tasks_path, strict=False)

        assert exit_code == 0
        assert output["marked"] == 2
        assert output["alreadyComplete"] == 1
        assert "strict" not in output
        assert "skipped" not in output
        # Tasks should be marked complete
        assert "- [x] 1.1 First task" in content
        assert "- [x] 1.2 Second task" in content
        assert "- [x] 1.3 Third task" in content


class TestConcurrentWriteLocking:
    """Test case 7: Concurrent writes -- file lock prevents lost updates."""

    def test_concurrent_write_locking(self, tmp_path):
        """Spawn two threads that mark different tasks complete simultaneously.

        Thread A marks group-a tasks (1.1, 1.2).
        Thread B marks group-b tasks (2.1, 2.2).
        Both write to the same tasks.md file.
        The file lock should serialize the writes so neither update is lost.
        """
        tasks_md = (
            "# Tasks\n"
            "- [ ] 1.1 First task\n"
            "- [ ] 1.2 Second task\n"
            "- [ ] 2.1 Third task\n"
            "- [ ] 2.2 Fourth task\n"
        )

        tasks_path = str(tmp_path / "tasks.md")
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        # Create separate dispatch-state files for each thread
        state_a = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1", "1.2"]},
            ],
        }
        state_b = {
            "completedGroups": ["group-b"],
            "groups": [
                {"name": "group-b", "tasks": ["2.1", "2.2"]},
            ],
        }

        state_a_path = str(tmp_path / "dispatch-state-a.json")
        state_b_path = str(tmp_path / "dispatch-state-b.json")
        with open(state_a_path, "w") as f:
            json.dump(state_a, f)
        with open(state_b_path, "w") as f:
            json.dump(state_b, f)

        results = {}

        def run_in_thread(name, state_path):
            exit_code, output, _ = run_script(state_path, tasks_path)
            results[name] = (exit_code, output)

        thread_a = threading.Thread(target=run_in_thread, args=("a", state_a_path))
        thread_b = threading.Thread(target=run_in_thread, args=("b", state_b_path))

        thread_a.start()
        thread_b.start()
        thread_a.join(timeout=30)
        thread_b.join(timeout=30)

        # Both threads should have exited successfully
        assert results["a"][0] == 0, f"Thread A failed: {results['a']}"
        assert results["b"][0] == 0, f"Thread B failed: {results['b']}"

        # Read final state of tasks.md
        with open(tasks_path, "r") as f:
            final_content = f.read()

        # All four tasks must be marked complete -- no lost updates
        assert "- [x] 1.1 First task" in final_content
        assert "- [x] 1.2 Second task" in final_content
        assert "- [x] 2.1 Third task" in final_content
        assert "- [x] 2.2 Fourth task" in final_content
        assert "- [ ]" not in final_content


class TestMainErrorHandling:
    """Test case 8: main() handles missing files without unhandled exceptions."""

    def test_missing_dispatch_state(self, tmp_path):
        """Missing dispatch-state.json -> exits 0 with error in JSON (graceful)."""
        tasks_md = "# Tasks\n- [ ] 1.1 First task\n"
        tasks_path = str(tmp_path / "tasks.md")
        with open(tasks_path, "w") as f:
            f.write(tasks_md)

        nonexistent_state = str(tmp_path / "nonexistent-dispatch-state.json")

        exit_code, output, content = run_script(nonexistent_state, tasks_path)

        # Script handles FileNotFoundError gracefully and exits 0
        assert exit_code == 0
        assert "error" in output
        assert output["marked"] == 0
        # tasks.md should be untouched
        assert "- [ ] 1.1 First task" in content

    def test_missing_tasks_md(self, tmp_path):
        """Missing tasks.md -> exits 1 with error message (no unhandled crash)."""
        dispatch_state = {
            "completedGroups": ["group-a"],
            "groups": [
                {"name": "group-a", "tasks": ["1.1"]},
            ],
        }
        state_path = str(tmp_path / "dispatch-state.json")
        with open(state_path, "w") as f:
            json.dump(dispatch_state, f)

        nonexistent_tasks = str(tmp_path / "nonexistent-tasks.md")

        exit_code, output, _ = run_script(state_path, nonexistent_tasks)

        # Script exits 1 (not a crash traceback) with structured error
        assert exit_code == 1
        assert "error" in output
        assert output["marked"] == 0

    def test_both_files_missing(self, tmp_path):
        """Both files missing -> exits cleanly (dispatch-state error caught first)."""
        nonexistent_state = str(tmp_path / "no-state.json")
        nonexistent_tasks = str(tmp_path / "no-tasks.md")

        exit_code, output, _ = run_script(nonexistent_state, nonexistent_tasks)

        # dispatch-state.json FileNotFoundError is caught first -> exit 0
        assert exit_code == 0
        assert "error" in output
        assert output["marked"] == 0
