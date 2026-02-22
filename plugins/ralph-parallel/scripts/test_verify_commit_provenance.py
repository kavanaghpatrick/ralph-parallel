"""Tests for verify-commit-provenance.py commit provenance audit."""
import importlib.util
import json
import os
from unittest.mock import patch, MagicMock

import pytest

# Load module from hyphenated filename
_spec = importlib.util.spec_from_file_location(
    'verify_commit_provenance',
    os.path.join(os.path.dirname(__file__), 'verify-commit-provenance.py'),
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

get_group_names = mod.get_group_names
get_git_commits = mod.get_git_commits
audit_provenance = mod.audit_provenance


# ── Helpers ───────────────────────────────────────────────────


def _make_git_output(*records):
    """Build synthetic git log output with null-byte record separators.

    Each record is a tuple of (hash, subject, [signed_off_by_values]).
    Returns a string matching the format produced by:
        git log --format="%x00%H %s%n%(trailers:key=Signed-off-by,valueonly)"
    """
    parts = []
    for commit_hash, subject, trailers in records:
        lines = [f"{commit_hash} {subject}"]
        for t in trailers:
            lines.append(t)
        parts.append('\n'.join(lines))
    return '\x00'.join([''] + parts)  # leading null byte matches git format


def _mock_subprocess_result(stdout):
    """Create a mock subprocess.CompletedProcess with given stdout."""
    result = MagicMock()
    result.stdout = stdout
    result.returncode = 0
    return result


# ── Test Case 1: All commits have proper trailers ────────────


class TestAllCommitsAttributed:
    """All commits have Signed-off-by trailers matching known groups."""

    def test_all_attributed(self):
        known_groups = ['group-alpha', 'group-beta']
        commits = [
            {
                'hash': 'aaaa1111bbbb2222cccc3333dddd4444eeee5555',
                'subject': 'feat: add login page',
                'signed_off_by': ['group-alpha'],
            },
            {
                'hash': 'ffff6666aaaa7777bbbb8888cccc9999dddd0000',
                'subject': 'feat: add dashboard',
                'signed_off_by': ['group-beta'],
            },
            {
                'hash': '1111aaaa2222bbbb3333cccc4444dddd5555eeee',
                'subject': 'fix: typo in config',
                'signed_off_by': ['group-alpha'],
            },
        ]

        result = audit_provenance(commits, known_groups)

        assert result['total'] == 3
        assert result['attributed'] == 3
        assert result['unattributed'] == 0
        assert result['unknown_agent'] == 0
        assert all(d['status'] == 'attributed' for d in result['details'])

    @patch('subprocess.run')
    def test_all_attributed_via_git_log(self, mock_run):
        """End-to-end: mock git log output where all commits have trailers."""
        git_output = _make_git_output(
            ('aaaa1111bbbb2222cccc3333dddd4444eeee5555', 'feat: add login page', ['group-alpha']),
            ('ffff6666aaaa7777bbbb8888cccc9999dddd0000', 'feat: add dashboard', ['group-beta']),
        )
        mock_run.return_value = _mock_subprocess_result(git_output)

        commits = get_git_commits('2026-02-01')

        assert len(commits) == 2
        assert commits[0]['signed_off_by'] == ['group-alpha']
        assert commits[1]['signed_off_by'] == ['group-beta']

        result = audit_provenance(commits, ['group-alpha', 'group-beta'])
        assert result['attributed'] == 2
        assert result['unattributed'] == 0


# ── Test Case 2: Some commits missing trailers ───────────────


class TestSomeCommitsMissingTrailers:
    """Mix of attributed and unattributed commits."""

    def test_partial_attribution(self):
        known_groups = ['group-alpha', 'group-beta']
        commits = [
            {
                'hash': 'aaaa1111bbbb2222cccc3333dddd4444eeee5555',
                'subject': 'feat: add login page',
                'signed_off_by': ['group-alpha'],
            },
            {
                'hash': 'ffff6666aaaa7777bbbb8888cccc9999dddd0000',
                'subject': 'chore: update deps',
                'signed_off_by': [],  # no trailer
            },
            {
                'hash': '1111aaaa2222bbbb3333cccc4444dddd5555eeee',
                'subject': 'fix: typo',
                'signed_off_by': [],  # no trailer
            },
        ]

        result = audit_provenance(commits, known_groups)

        assert result['total'] == 3
        assert result['attributed'] == 1
        assert result['unattributed'] == 2
        assert result['unknown_agent'] == 0

        # Check details
        statuses = [d['status'] for d in result['details']]
        assert statuses.count('attributed') == 1
        assert statuses.count('unattributed') == 2

    @patch('subprocess.run')
    def test_partial_attribution_via_git_log(self, mock_run):
        """End-to-end: mock git log with some missing trailers."""
        git_output = _make_git_output(
            ('aaaa1111bbbb2222cccc3333dddd4444eeee5555', 'feat: add login', ['group-alpha']),
            ('ffff6666aaaa7777bbbb8888cccc9999dddd0000', 'chore: update deps', []),
        )
        mock_run.return_value = _mock_subprocess_result(git_output)

        commits = get_git_commits('2026-02-01')

        assert len(commits) == 2
        assert commits[0]['signed_off_by'] == ['group-alpha']
        assert commits[1]['signed_off_by'] == []

        result = audit_provenance(commits, ['group-alpha', 'group-beta'])
        assert result['attributed'] == 1
        assert result['unattributed'] == 1


# ── Test Case 3: Unknown agent name in trailer ───────────────


class TestUnknownAgentTrailer:
    """Commits with trailers that don't match any known group."""

    def test_unknown_agent(self):
        known_groups = ['group-alpha', 'group-beta']
        commits = [
            {
                'hash': 'aaaa1111bbbb2222cccc3333dddd4444eeee5555',
                'subject': 'feat: add login page',
                'signed_off_by': ['group-alpha'],
            },
            {
                'hash': 'ffff6666aaaa7777bbbb8888cccc9999dddd0000',
                'subject': 'feat: rogue commit',
                'signed_off_by': ['unknown-rogue-agent'],
            },
            {
                'hash': '1111aaaa2222bbbb3333cccc4444dddd5555eeee',
                'subject': 'fix: another rogue',
                'signed_off_by': ['also-not-known'],
            },
        ]

        result = audit_provenance(commits, known_groups)

        assert result['total'] == 3
        assert result['attributed'] == 1
        assert result['unattributed'] == 0
        assert result['unknown_agent'] == 2

        # Verify the unknown details have the trailer value
        unknown_details = [d for d in result['details'] if d['status'] == 'unknown_agent']
        assert len(unknown_details) == 2
        assert unknown_details[0]['trailer'] == 'unknown-rogue-agent'
        assert unknown_details[1]['trailer'] == 'also-not-known'

    @patch('subprocess.run')
    def test_unknown_agent_via_git_log(self, mock_run):
        """End-to-end: mock git log with unknown agent trailers."""
        git_output = _make_git_output(
            ('aaaa1111bbbb2222cccc3333dddd4444eeee5555', 'feat: add login', ['group-alpha']),
            ('ffff6666aaaa7777bbbb8888cccc9999dddd0000', 'feat: rogue', ['unknown-agent']),
        )
        mock_run.return_value = _mock_subprocess_result(git_output)

        commits = get_git_commits('2026-02-01')
        result = audit_provenance(commits, ['group-alpha', 'group-beta'])

        assert result['attributed'] == 1
        assert result['unknown_agent'] == 1
        assert result['details'][1]['trailer'] == 'unknown-agent'


# ── Additional edge cases ─────────────────────────────────────


class TestEdgeCases:
    """Edge cases for get_group_names and empty outputs."""

    def test_get_group_names_from_state(self):
        state = {
            'groups': [
                {'name': 'group-alpha', 'tasks': ['1.1', '1.2']},
                {'name': 'group-beta', 'tasks': ['2.1']},
            ]
        }
        assert get_group_names(state) == ['group-alpha', 'group-beta']

    def test_get_group_names_empty_groups(self):
        assert get_group_names({'groups': []}) == []
        assert get_group_names({}) == []

    @patch('subprocess.run')
    def test_empty_git_log(self, mock_run):
        mock_run.return_value = _mock_subprocess_result('')
        commits = get_git_commits('2026-02-01')
        assert commits == []

    def test_audit_empty_commits(self):
        result = audit_provenance([], ['group-alpha'])
        assert result['total'] == 0
        assert result['attributed'] == 0
        assert result['unattributed'] == 0
        assert result['unknown_agent'] == 0
        assert result['details'] == []
