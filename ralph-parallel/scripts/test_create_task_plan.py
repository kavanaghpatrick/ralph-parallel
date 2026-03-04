"""Tests for create-task-plan.py task plan generation."""
import importlib.util
import json
import os
import pytest

# Load module from hyphenated filename
_spec = importlib.util.spec_from_file_location(
    'create_task_plan',
    os.path.join(os.path.dirname(__file__), 'create-task-plan.py'),
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

create_task_plan = mod.create_task_plan


def _make_task(tid, phase=1, desc=None, raw=''):
    return {
        'id': tid,
        'phase': phase,
        'description': desc or f'Task {tid}',
        'rawBlock': raw or f'raw block for {tid}',
        'files': [],
        'doSteps': [],
        'verify': '',
        'commit': '',
        'doneWhen': '',
    }


def _make_partition(groups=None, verify_tasks=None, serial_tasks=None):
    return {
        'groups': groups or [],
        'verifyTasks': verify_tasks or [],
        'serialTasks': serial_tasks or [],
    }


class TestSinglePhase:
    def test_single_phase_no_verify(self):
        """1 group, 3 tasks, 0 verify -> 3 entries, all blockedBy=[]."""
        partition = _make_partition(
            groups=[{
                'index': 0, 'name': 'g0', 'tasks': ['1.1', '1.2', '1.3'],
                'taskDetails': [
                    _make_task('1.1'), _make_task('1.2'), _make_task('1.3'),
                ],
                'ownedFiles': [], 'dependencies': [],
            }],
        )
        plan = create_task_plan(partition)
        assert len(plan) == 3
        for entry in plan:
            assert entry['blockedBy'] == []
        assert plan[0]['subject'] == '1.1: Task 1.1'
        assert plan[0]['activeForm'] == 'Implementing 1.1'

    def test_single_phase_with_verify(self):
        """1 group, 2 tasks, 1 verify -> 3 entries, verify.blockedBy=[0,1]."""
        partition = _make_partition(
            groups=[{
                'index': 0, 'name': 'g0', 'tasks': ['1.1', '1.2'],
                'taskDetails': [_make_task('1.1'), _make_task('1.2')],
                'ownedFiles': [], 'dependencies': [],
            }],
            verify_tasks=[{
                'id': '1.3', 'phase': 1,
                'description': '[VERIFY] Phase 1', 'rawBlock': 'verify',
            }],
        )
        plan = create_task_plan(partition)
        assert len(plan) == 3
        assert plan[0]['blockedBy'] == []
        assert plan[1]['blockedBy'] == []
        assert plan[2]['blockedBy'] == [0, 1]
        assert plan[2]['activeForm'] == 'Running 1.3 verify'


class TestMultiPhase:
    def test_multi_phase_with_verify(self):
        """2 phases, verify each -> Phase 2 tasks blockedBy=[verify1_idx]."""
        partition = _make_partition(
            groups=[{
                'index': 0, 'name': 'g0',
                'tasks': ['1.1', '2.1'],
                'taskDetails': [
                    _make_task('1.1', phase=1),
                    _make_task('2.1', phase=2),
                ],
                'ownedFiles': [], 'dependencies': [],
            }],
            verify_tasks=[
                {'id': '1.2', 'phase': 1, 'description': '[VERIFY] Phase 1', 'rawBlock': ''},
                {'id': '2.2', 'phase': 2, 'description': '[VERIFY] Phase 2', 'rawBlock': ''},
            ],
        )
        plan = create_task_plan(partition)
        # Expected order: 1.1, 1.2(verify), 2.1, 2.2(verify)
        assert len(plan) == 4
        assert plan[0]['subject'].startswith('1.1')
        assert plan[0]['blockedBy'] == []
        assert plan[1]['subject'].startswith('1.2')  # verify phase 1
        assert plan[1]['blockedBy'] == [0]
        assert plan[2]['subject'].startswith('2.1')
        assert plan[2]['blockedBy'] == [1]  # blocked by phase 1 verify
        assert plan[3]['subject'].startswith('2.2')  # verify phase 2
        assert plan[3]['blockedBy'] == [2]


class TestSerialTasks:
    def test_serial_tasks_after_parallel(self):
        """2 groups + 1 serial -> serial blockedBy=[last_verify_idx]."""
        partition = _make_partition(
            groups=[
                {
                    'index': 0, 'name': 'g0', 'tasks': ['1.1'],
                    'taskDetails': [_make_task('1.1')],
                    'ownedFiles': [], 'dependencies': [],
                },
                {
                    'index': 1, 'name': 'g1', 'tasks': ['1.2'],
                    'taskDetails': [_make_task('1.2')],
                    'ownedFiles': [], 'dependencies': [],
                },
            ],
            verify_tasks=[
                {'id': '1.3', 'phase': 1, 'description': '[VERIFY] Phase 1', 'rawBlock': ''},
            ],
            serial_tasks=[
                {'id': '2.1', 'phase': 2, 'description': 'Serial task', 'rawBlock': ''},
            ],
        )
        plan = create_task_plan(partition)
        # Order: 1.1, 1.2, 1.3(verify), 2.1(serial)
        assert len(plan) == 4
        verify_idx = 2
        assert plan[verify_idx]['activeForm'] == 'Running 1.3 verify'
        assert plan[3]['blockedBy'] == [verify_idx]

    def test_serial_tasks_chain(self):
        """3 serial, no groups -> each blockedBy=[prev]."""
        partition = _make_partition(
            serial_tasks=[
                {'id': '1.1', 'phase': 1, 'description': 'Serial 1', 'rawBlock': ''},
                {'id': '1.2', 'phase': 1, 'description': 'Serial 2', 'rawBlock': ''},
                {'id': '1.3', 'phase': 1, 'description': 'Serial 3', 'rawBlock': ''},
            ],
        )
        plan = create_task_plan(partition)
        assert len(plan) == 3
        assert plan[0]['blockedBy'] == []
        assert plan[1]['blockedBy'] == [0]
        assert plan[2]['blockedBy'] == [1]


class TestEdgeCases:
    def test_empty_partition(self):
        """0 groups, 0 serial, 0 verify -> []."""
        partition = _make_partition()
        plan = create_task_plan(partition)
        assert plan == []

    def test_verify_depends_on_all_same_phase_tasks(self):
        """2 groups, 4 tasks, 1 verify -> verify has 4 blockedBy entries."""
        partition = _make_partition(
            groups=[
                {
                    'index': 0, 'name': 'g0', 'tasks': ['1.1', '1.2'],
                    'taskDetails': [_make_task('1.1'), _make_task('1.2')],
                    'ownedFiles': [], 'dependencies': [],
                },
                {
                    'index': 1, 'name': 'g1', 'tasks': ['1.3', '1.4'],
                    'taskDetails': [_make_task('1.3'), _make_task('1.4')],
                    'ownedFiles': [], 'dependencies': [],
                },
            ],
            verify_tasks=[
                {'id': '1.5', 'phase': 1, 'description': '[VERIFY] Phase 1', 'rawBlock': ''},
            ],
        )
        plan = create_task_plan(partition)
        verify_entry = plan[-1]
        assert verify_entry['activeForm'] == 'Running 1.5 verify'
        assert len(verify_entry['blockedBy']) == 4
        assert verify_entry['blockedBy'] == [0, 1, 2, 3]

    def test_index_ordering_guarantee(self):
        """For all entries, all blockedBy indices < current index."""
        partition = _make_partition(
            groups=[
                {
                    'index': 0, 'name': 'g0',
                    'tasks': ['1.1', '2.1'],
                    'taskDetails': [
                        _make_task('1.1', phase=1),
                        _make_task('2.1', phase=2),
                    ],
                    'ownedFiles': [], 'dependencies': [],
                },
            ],
            verify_tasks=[
                {'id': '1.2', 'phase': 1, 'description': '[VERIFY] Phase 1', 'rawBlock': ''},
                {'id': '2.2', 'phase': 2, 'description': '[VERIFY] Phase 2', 'rawBlock': ''},
            ],
            serial_tasks=[
                {'id': '3.1', 'phase': 3, 'description': 'Serial', 'rawBlock': ''},
            ],
        )
        plan = create_task_plan(partition)
        for i, entry in enumerate(plan):
            for dep_idx in entry['blockedBy']:
                assert dep_idx < i, (
                    f"Entry {i} ({entry['subject']}) has blockedBy index "
                    f"{dep_idx} which is >= its own index"
                )

    def test_description_field_from_raw_block(self):
        """description field should come from rawBlock."""
        partition = _make_partition(
            groups=[{
                'index': 0, 'name': 'g0', 'tasks': ['1.1'],
                'taskDetails': [_make_task('1.1', raw='custom raw content')],
                'ownedFiles': [], 'dependencies': [],
            }],
        )
        plan = create_task_plan(partition)
        assert plan[0]['description'] == 'custom raw content'
