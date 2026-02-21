"""Tests for build-teammate-prompt.py quality section."""
import importlib.util
import json
import os
import subprocess
import pytest

# Load module
_spec = importlib.util.spec_from_file_location(
    'build_teammate_prompt',
    os.path.join(os.path.dirname(__file__), 'build-teammate-prompt.py'),
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

build_quality_section = mod.build_quality_section
build_prompt = mod.build_prompt


def _make_group(**kwargs):
    return {
        "name": "test-group",
        "taskDetails": [{"id": "1.1", "description": "Test task", "files": ["a.ts"],
                         "doSteps": [], "verify": "echo ok", "commit": "", "doneWhen": "",
                         "phase": 1}],
        "ownedFiles": ["a.ts"],
        "hasMultiplePhases": False,
        "phases": [1],
        **kwargs,
    }


class TestBuildQualitySection:
    def test_with_typecheck(self):
        lines = build_quality_section({"typecheck": "npx tsc --noEmit"})
        text = "\n".join(lines)
        assert "After EACH task, run typecheck" in text
        assert "npx tsc --noEmit" in text

    def test_with_test_runner(self):
        lines = build_quality_section({"test": "pytest"})
        text = "\n".join(lines)
        assert "Write at least one test" in text
        assert "pytest" in text

    def test_with_build_only(self):
        lines = build_quality_section({"build": "make build"})
        text = "\n".join(lines)
        assert "Verify your code builds" in text
        assert "Write at least one test" not in text

    def test_no_commands(self):
        lines = build_quality_section({})
        text = "\n".join(lines)
        assert "Run any available project checks" in text


class TestBuildPromptIntegration:
    def test_quality_section_present(self):
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"],
                              quality_commands={"typecheck": "npx tsc"})
        assert "## Quality Checks" in prompt

    def test_quality_section_ordering(self):
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"],
                              quality_commands={"typecheck": "npx tsc"})
        ownership_pos = prompt.index("File Ownership")
        quality_pos = prompt.index("Quality Checks")
        rules_pos = prompt.index("## Rules")
        assert ownership_pos < quality_pos < rules_pos


class TestQualityCommandsCLI:
    def test_cli_arg_parsed(self, tmp_path):
        """Run the script with --quality-commands and verify output."""
        # Create minimal partition JSON
        partition = {
            "groups": [{
                "index": 0, "name": "test", "tasks": ["1.1"],
                "taskDetails": [{"id": "1.1", "description": "Test", "files": ["a.ts"],
                                 "doSteps": [], "verify": "", "commit": "", "doneWhen": "",
                                 "phase": 1}],
                "ownedFiles": ["a.ts"], "hasMultiplePhases": False, "phases": [1],
                "dependencies": [],
            }]
        }
        pf = tmp_path / "partition.json"
        pf.write_text(json.dumps(partition))

        script = os.path.join(os.path.dirname(__file__), "build-teammate-prompt.py")
        result = subprocess.run(
            ["python3", script, "--partition-file", str(pf), "--group-index", "0",
             "--spec-name", "test", "--project-root", "/tmp", "--task-ids", "#1",
             "--quality-commands", '{"typecheck":"echo ok"}'],
            capture_output=True, text=True,
        )
        assert result.returncode == 0
        assert "Quality Checks" in result.stdout
        assert "echo ok" in result.stdout
