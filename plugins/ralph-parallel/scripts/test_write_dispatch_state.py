"""Tests for write-dispatch-state.py dispatch state construction and transitions."""
import importlib.util
import json
import os
import subprocess
import sys
from unittest.mock import patch

import pytest

# Load module from hyphenated filename
_spec = importlib.util.spec_from_file_location(
    'write_dispatch_state',
    os.path.join(os.path.dirname(__file__), 'write-dispatch-state.py'),
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

_atomic_write = _mod._atomic_write
check_existing_state = _mod.check_existing_state
build_dispatch_state = _mod.build_dispatch_state


def _make_partition():
    """Return a minimal valid partition dict."""
    return {
        'groups': [
            {
                'index': 0,
                'name': 'group-0',
                'tasks': ['1.1', '1.2'],
                'ownedFiles': ['src/a.py'],
                'dependencies': [],
                'taskDetails': [{'id': '1.1', 'extra': 'should be stripped'}],
            },
        ],
        'serialTasks': [{'id': '6.1', 'description': 'serial'}],
        'verifyTasks': [{'id': '1.3', 'description': 'verify'}],
        'qualityCommands': {'build': 'npx tsc', 'test': 'pytest'},
    }


def _make_args(partition_file, spec_dir, strategy='file-ownership', max_teammates=4):
    """Create a mock args namespace."""
    import argparse
    return argparse.Namespace(
        partition_file=partition_file,
        strategy=strategy,
        max_teammates=max_teammates,
        spec_dir=spec_dir,
    )


class TestAtomicWrite:
    """Tests for _atomic_write function."""

    def test_writes_json_file(self, tmp_path):
        path = str(tmp_path / 'test.json')
        data = {'key': 'value', 'num': 42}
        _atomic_write(path, data)
        with open(path) as f:
            result = json.load(f)
        assert result == data

    def test_overwrites_existing(self, tmp_path):
        path = str(tmp_path / 'test.json')
        _atomic_write(path, {'v': 1})
        _atomic_write(path, {'v': 2})
        with open(path) as f:
            result = json.load(f)
        assert result == {'v': 2}

    def test_trailing_newline(self, tmp_path):
        path = str(tmp_path / 'test.json')
        _atomic_write(path, {'a': 1})
        with open(path) as f:
            content = f.read()
        assert content.endswith('\n')

    def test_atomic_write_calls_fsync(self, tmp_path):
        path = str(tmp_path / 'test.json')
        with patch('os.fsync') as mock_fsync:
            _atomic_write(path, {'key': 'value'})
            mock_fsync.assert_called()

    def test_atomic_write_cleans_up_on_failure(self, tmp_path):
        path = str(tmp_path / 'test.json')
        with patch('os.replace', side_effect=OSError('mock replace failure')):
            with pytest.raises(OSError, match='mock replace failure'):
                _atomic_write(path, {'key': 'value'})
        # The temp file should have been cleaned up
        remaining = [f for f in os.listdir(tmp_path) if f.endswith('.tmp')]
        assert remaining == [], f"Temp file not cleaned up: {remaining}"


class TestMaxTeammatesValidation:
    """Tests for max_teammates CLI validation."""

    _script = os.path.join(os.path.dirname(__file__), 'write-dispatch-state.py')

    def _run_script(self, max_teammates, tmp_path):
        """Run the script with a given --max-teammates value."""
        partition_file = str(tmp_path / 'partition.json')
        with open(partition_file, 'w') as f:
            json.dump({'groups': [], 'serialTasks': [], 'verifyTasks': [],
                        'qualityCommands': {}}, f)
        spec_dir = str(tmp_path / 'spec')
        os.makedirs(spec_dir, exist_ok=True)
        return subprocess.run(
            [sys.executable, self._script,
             '--partition-file', partition_file,
             '--strategy', 'file-ownership',
             '--max-teammates', str(max_teammates),
             '--spec-dir', spec_dir],
            capture_output=True, text=True,
        )

    def test_max_teammates_below_minimum(self, tmp_path):
        result = self._run_script(0, tmp_path)
        assert result.returncode == 1

    def test_max_teammates_above_maximum(self, tmp_path):
        result = self._run_script(21, tmp_path)
        assert result.returncode == 1


class TestCheckExistingState:
    """Tests for check_existing_state function."""

    def test_no_existing_state(self, tmp_path):
        result = check_existing_state(str(tmp_path))
        assert result is None

    def test_merging_state_exits(self, tmp_path):
        state_file = tmp_path / '.dispatch-state.json'
        state_file.write_text(json.dumps({'status': 'merging'}))
        with pytest.raises(SystemExit) as exc:
            check_existing_state(str(tmp_path))
        assert exc.value.code == 2

    def test_dispatched_state_supersedes(self, tmp_path):
        state_file = tmp_path / '.dispatch-state.json'
        state_file.write_text(json.dumps({
            'status': 'dispatched',
            'dispatchedAt': '2026-01-01T00:00:00Z',
        }))
        result = check_existing_state(str(tmp_path))
        assert result is not None
        assert result['status'] == 'superseded'
        assert 'supersededAt' in result
        # Verify the file on disk was also updated
        with open(state_file) as f:
            on_disk = json.load(f)
        assert on_disk['status'] == 'superseded'

    def test_merged_state_returns_none(self, tmp_path):
        state_file = tmp_path / '.dispatch-state.json'
        state_file.write_text(json.dumps({'status': 'merged'}))
        result = check_existing_state(str(tmp_path))
        assert result is None

    def test_aborted_state_returns_none(self, tmp_path):
        state_file = tmp_path / '.dispatch-state.json'
        state_file.write_text(json.dumps({'status': 'aborted'}))
        result = check_existing_state(str(tmp_path))
        assert result is None

    def test_stale_state_returns_none(self, tmp_path):
        state_file = tmp_path / '.dispatch-state.json'
        state_file.write_text(json.dumps({'status': 'stale'}))
        result = check_existing_state(str(tmp_path))
        assert result is None


class TestBuildDispatchState:
    """Tests for build_dispatch_state function."""

    def test_all_11_fields_present(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test-session-123')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        expected_fields = [
            'dispatchedAt', 'coordinatorSessionId', 'strategy',
            'maxTeammates', 'groups', 'serialTasks', 'verifyTasks',
            'qualityCommands', 'baselineSnapshot', 'status', 'completedGroups',
        ]
        for field in expected_fields:
            assert field in state, f"Missing field: {field}"
        assert len(state) == 11

    def test_strips_task_details(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test-session')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        group = state['groups'][0]
        assert 'taskDetails' not in group
        assert 'index' in group
        assert 'name' in group
        assert 'tasks' in group
        assert 'ownedFiles' in group

    def test_session_id_from_env(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'my-session-42')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        assert state['coordinatorSessionId'] == 'my-session-42'

    def test_session_id_none_when_unset(self, tmp_path, monkeypatch):
        monkeypatch.delenv('CLAUDE_SESSION_ID', raising=False)
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        assert state['coordinatorSessionId'] is None

    def test_status_is_dispatched(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        assert state['status'] == 'dispatched'
        assert state['completedGroups'] == []
        assert state['baselineSnapshot'] is None

    def test_serial_and_verify_task_ids(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        assert state['serialTasks'] == ['6.1']
        assert state['verifyTasks'] == ['1.3']

    def test_strategy_passed_through(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path), strategy='worktree', max_teammates=8)
        state = build_dispatch_state(partition, args)
        assert state['strategy'] == 'worktree'
        assert state['maxTeammates'] == 8

    def test_quality_commands_preserved(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        assert state['qualityCommands'] == {'build': 'npx tsc', 'test': 'pytest'}

    def test_dispatched_at_iso8601_with_z(self, tmp_path, monkeypatch):
        monkeypatch.setenv('CLAUDE_SESSION_ID', 'test')
        partition = _make_partition()
        args = _make_args('/tmp/p.json', str(tmp_path))
        state = build_dispatch_state(partition, args)
        ts = state['dispatchedAt']
        assert ts.endswith('Z'), f"Expected ISO 8601 ending in Z, got: {ts}"
        assert '+' not in ts, f"Should not contain +00:00, got: {ts}"
