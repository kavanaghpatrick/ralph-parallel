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
        assert "Typecheck:" in text
        assert "npx tsc --noEmit" in text

    def test_with_test_runner(self):
        lines = build_quality_section({"test": "pytest"})
        text = "\n".join(lines)
        assert "Full test suite:" in text
        assert "pytest" in text
        assert "Zero regressions policy" in text

    def test_with_build_only(self):
        lines = build_quality_section({"build": "make build"})
        text = "\n".join(lines)
        assert "Build:" in text
        assert "make build" in text

    def test_no_commands(self):
        lines = build_quality_section({})
        text = "\n".join(lines)
        assert "Run any available project checks" in text


class TestLintInQualitySection:
    def test_lint_appears(self):
        """lint command should appear in quality section."""
        lines = build_quality_section({"lint": "eslint ."})
        text = "\n".join(lines)
        assert "Lint:" in text
        assert "eslint ." in text

    def test_lint_after_test(self):
        """Lint step number must be higher than test step number."""
        lines = build_quality_section({"test": "pytest", "lint": "ruff"})
        text = "\n".join(lines)
        test_line = next(l for l in lines if "Full test suite:" in l)
        lint_line = next(l for l in lines if "Lint:" in l)
        test_step = int(test_line.strip()[0])
        lint_step = int(lint_line.strip()[0])
        assert lint_step > test_step

    def test_no_lint_no_change(self):
        """Without lint, no 'Lint:' line should appear."""
        lines = build_quality_section({"test": "pytest"})
        text = "\n".join(lines)
        assert "Lint:" not in text

    def test_lint_only_no_fallback(self):
        """With only lint, no fallback 'Run any available' line should appear."""
        lines = build_quality_section({"lint": "ruff"})
        text = "\n".join(lines)
        assert "Lint:" in text
        assert "Run any available" not in text


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


class TestWorktreeStrategy:
    def test_worktree_file_ownership_section(self):
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"], strategy="worktree")
        assert "WORKTREE MODE" in prompt
        assert "isolated git worktree" in prompt
        assert "STRICTLY ENFORCED" not in prompt
        assert "PreToolUse hook" not in prompt

    def test_file_ownership_default(self):
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"], strategy="file-ownership")
        assert "STRICTLY ENFORCED" in prompt
        assert "WORKTREE MODE" not in prompt

    def test_worktree_has_create_from_scratch_note(self):
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"], strategy="worktree")
        assert "create them from scratch" in prompt

    def test_worktree_has_post_merge_skip_note(self):
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"], strategy="worktree")
        assert "post-merge" in prompt


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


# --- KB Context Tests ---

_KB_JSON_FULL = json.dumps({
    "kb_available": True,
    "total_findings": 2,
    "skill_contexts": [{
        "skill_name": "motor-design",
        "finding_count": 2,
        "confidence_summary": {"high": 1, "verified": 1},
        "findings": [
            {"confidence": "high", "topic": "cogging", "claim": "Skewing reduces cogging",
             "evidence": "Measured on prototype", "source_title": "IEEE Handbook"},
            {"confidence": "verified", "topic": "magnets", "claim": "NdFeB optimal for BLDC",
             "evidence": "Cost-performance analysis"},
        ],
    }],
})

_KB_JSON_UNAVAILABLE = json.dumps({"kb_available": False, "total_findings": 0, "skill_contexts": []})


class TestKBContext:
    def test_kb_section_appears_first(self):
        """KB section must render BEFORE 'Your Tasks' in the prompt."""
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"],
                              kb_context_json=_KB_JSON_FULL)
        kb_pos = prompt.index("# Knowledge Base Context")
        tasks_pos = prompt.index("Your Tasks")
        assert kb_pos < tasks_pos, "KB section must appear before Your Tasks"

    def test_skill_contexts_render_with_findings_and_confidence(self):
        """Skill name, findings, and confidence summary should all be present."""
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"],
                              kb_context_json=_KB_JSON_FULL)
        assert "motor-design" in prompt
        assert "Skewing reduces cogging" in prompt
        assert "NdFeB optimal for BLDC" in prompt
        assert "1 high" in prompt
        assert "1 verified" in prompt
        assert "IEEE Handbook" in prompt

    def test_kb_unavailable_shows_notice(self):
        """kb_available=false should produce a 'not available' notice, not crash."""
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"],
                              kb_context_json=_KB_JSON_UNAVAILABLE)
        assert "# Knowledge Base Context" in prompt
        assert "not available" in prompt
        # Should NOT contain skill findings
        assert "motor-design" not in prompt

    def test_invalid_json_shows_parse_error(self):
        """Invalid JSON for kb_context should produce a parse-error notice, not crash."""
        group = _make_group()
        prompt = build_prompt(group, "test-spec", "/tmp", ["#1"],
                              kb_context_json="NOT VALID JSON {{{")
        assert "# Knowledge Base Context" in prompt
        assert "could not be parsed" in prompt
        # Prompt should still contain normal sections
        assert "Your Tasks" in prompt

    def test_no_kb_context_produces_original_prompt(self):
        """When kb_context_json is None, prompt should be unchanged (no KB section)."""
        group = _make_group()
        prompt_without = build_prompt(group, "test-spec", "/tmp", ["#1"])
        prompt_none = build_prompt(group, "test-spec", "/tmp", ["#1"],
                                   kb_context_json=None)
        assert prompt_without == prompt_none
        assert "Knowledge Base Context" not in prompt_none
