#!/usr/bin/env python3
"""
Parse tasks.md and partition into parallelizable groups by file ownership.

Usage:
    python3 parse-and-partition.py --tasks-md <path> [--max-teammates N] [--strategy file-ownership] [--format]

If tasks.md contains pre-defined group annotations (### Group N: Name [P] with
**Files owned**), those groups are used directly. Otherwise falls back to
automatic file-ownership partitioning.

Exit codes:
    0 = success
    1 = tasks.md not found or unreadable
    2 = all tasks complete
    3 = single task remaining (no parallelism benefit)
    4 = unresolvable circular dependencies
"""

import argparse
import json
import re
import sys
from pathlib import Path


# ──────────────────────────────────────────────────────────────────
# Parsing
# ──────────────────────────────────────────────────────────────────

def parse_predefined_groups(content: str) -> list[dict] | None:
    """Extract pre-defined group annotations from tasks.md.

    Looks for markdown headers like:
        ### Group 1: Infrastructure [P]
        **Files owned** (8): `file1`, `file2`, ...

    Returns list of groups with name, files, and task IDs,
    or None if no pre-defined groups found.
    """
    groups = []
    lines = content.split('\n')
    current_group = None

    for line in lines:
        # Match group header: ### Group N: Name [P]
        gm = re.match(r'^###\s+Group\s+\d+:\s+(.+?)(?:\s+\[P\])?\s*$', line)
        if gm:
            if current_group:
                groups.append(current_group)
            current_group = {
                'name': gm.group(1).strip().lower().replace(' ', '-'),
                'files': [],
                'taskIds': [],
            }
            continue

        # Match files owned line within a group
        if current_group and '**Files owned**' in line:
            fm = re.search(r'\*\*Files owned\*\*.*?:\s*(.+)', line)
            if fm:
                for part in fm.group(1).split(','):
                    f = part.strip().strip('`').strip()
                    if f:
                        current_group['files'].append(f)
            continue

        # Match task within current group
        if current_group:
            tm = re.match(r'^- \[.\]\s*(\d+\.\d+)', line)
            if tm:
                current_group['taskIds'].append(tm.group(1))

        # Group boundary: --- or ## Phase header
        if current_group and (line.strip() == '---' or re.match(r'^## ', line)):
            groups.append(current_group)
            current_group = None

    if current_group:
        groups.append(current_group)

    # Only return if we found actual groups with tasks
    valid = [g for g in groups if g['taskIds'] and g['files']]
    return valid if len(valid) >= 2 else None


def parse_tasks(content: str) -> list[dict]:
    """Parse tasks.md content into structured task objects."""
    tasks = []
    lines = content.split('\n')
    i = 0

    while i < len(lines):
        line = lines[i]

        # Match task line: - [ ] X.Y or - [x] X.Y
        m = re.match(r'^- \[(.)\]\s*(\d+\.\d+)\s*(.*)', line)
        if not m:
            i += 1
            continue

        completed = m.group(1).lower() == 'x'
        task_id = m.group(2)
        rest = m.group(3).strip()

        # Extract markers [P], [VERIFY] from the rest
        markers = []
        for marker in ['[P]', '[VERIFY]']:
            if marker in rest:
                markers.append(marker.strip('[]'))
                rest = rest.replace(marker, '').strip()

        description = rest

        # Parse phase from task ID
        phase = int(task_id.split('.')[0])

        # Collect task body (indented lines until next task or section)
        i += 1
        body_lines = []
        while i < len(lines):
            if re.match(r'^- \[.\]\s*\d+\.\d+', lines[i]):
                break
            if re.match(r'^## ', lines[i]):
                break
            body_lines.append(lines[i])
            i += 1

        body = '\n'.join(body_lines)

        # Extract fields from body
        files = extract_files(body)
        do_steps = extract_do_steps(body)
        verify = extract_field(body, 'Verify')
        commit = extract_field(body, 'Commit')
        done_when = extract_field(body, 'Done when')

        # Build raw block for prompt inclusion
        raw_block = f"- [ ] {task_id} {' '.join(f'[{m}]' for m in markers)} {description}\n"
        raw_block += '\n'.join(body_lines)

        tasks.append({
            'id': task_id,
            'description': description,
            'files': files,
            'doSteps': do_steps,
            'verify': verify,
            'commit': commit,
            'doneWhen': done_when,
            'markers': markers,
            'phase': phase,
            'completed': completed,
            'dependencies': [],
            'rawBlock': raw_block.rstrip(),
        })

    return tasks


def extract_files(body: str) -> list[str]:
    """Extract file paths from **Files**: line."""
    m = re.search(r'\*\*Files\*\*:\s*(.+)', body)
    if not m:
        return []
    raw = m.group(1)
    files = []
    for part in raw.split(','):
        f = part.strip().strip('`').strip()
        if f:
            files.append(f)
    return files


def extract_do_steps(body: str) -> list[str]:
    """Extract numbered steps from **Do**: section."""
    steps = []
    in_do = False
    for line in body.split('\n'):
        if '**Do**:' in line:
            in_do = True
            continue
        if in_do:
            if re.match(r'\s+\d+\.', line):
                steps.append(line.strip())
            elif re.match(r'\s+-\s+\*\*', line) or re.match(r'^- \[', line):
                break
    return steps


def extract_field(body: str, field_name: str) -> str:
    """Extract a single-line field like **Verify**: or **Commit**:."""
    m = re.search(rf'\*\*{field_name}\*\*:\s*(.+)', body)
    if not m:
        return ''
    return m.group(1).strip().strip('`')


# ──────────────────────────────────────────────────────────────────
# Dependency Graph
# ──────────────────────────────────────────────────────────────────

def build_dependency_graph(tasks: list[dict]) -> list[dict]:
    """Add dependency edges based on file overlap and phase ordering."""
    # File overlap detection within same phase
    for i, a in enumerate(tasks):
        for b in tasks[i + 1:]:
            if a['phase'] != b['phase']:
                continue
            overlap = set(a['files']) & set(b['files'])
            if overlap:
                b['dependencies'].append(a['id'])

    # [VERIFY] tasks depend on ALL preceding tasks in same phase
    for t in tasks:
        if 'VERIFY' in t['markers']:
            for other in tasks:
                if other['phase'] == t['phase'] and other['id'] < t['id']:
                    if other['id'] not in t['dependencies']:
                        t['dependencies'].append(other['id'])
            # All tasks after VERIFY in same phase depend on it
            for other in tasks:
                if other['phase'] == t['phase'] and other['id'] > t['id']:
                    if t['id'] not in other['dependencies']:
                        other['dependencies'].append(t['id'])

    # Phase ordering: phase N+1 tasks depend on phase N VERIFY task
    phases = sorted(set(t['phase'] for t in tasks))
    for idx in range(len(phases) - 1):
        current_phase = phases[idx]
        next_phase = phases[idx + 1]
        verify_task = None
        for t in tasks:
            if t['phase'] == current_phase and 'VERIFY' in t['markers']:
                verify_task = t
        if verify_task:
            for t in tasks:
                if t['phase'] == next_phase:
                    if verify_task['id'] not in t['dependencies']:
                        t['dependencies'].append(verify_task['id'])

    return tasks


# ──────────────────────────────────────────────────────────────────
# Partitioning
# ──────────────────────────────────────────────────────────────────

def partition_tasks(tasks: list[dict], max_teammates: int, content: str = '') -> dict:
    """Partition tasks into groups.

    If tasks.md contains pre-defined group annotations (### Group N: Name),
    those are used directly. Falls back to automatic file-ownership
    partitioning when no annotations exist.
    """
    incomplete = [t for t in tasks if not t['completed']]
    if not incomplete:
        return None

    parallel_tasks = [t for t in incomplete if 'VERIFY' not in t['markers']]
    verify_tasks = [t for t in incomplete if 'VERIFY' in t['markers']]

    # Check for pre-defined groups
    predefined = parse_predefined_groups(content) if content else None

    if predefined:
        groups, serial_tasks = _build_groups_from_predefined(
            predefined, tasks, parallel_tasks, max_teammates)
    else:
        groups, serial_tasks = _build_groups_automatic(
            parallel_tasks, max_teammates)

    # Build inter-group dependencies
    _add_group_dependencies(groups)

    return _format_result(groups, serial_tasks, verify_tasks, tasks, incomplete)


def _build_groups_from_predefined(predefined, all_tasks, parallel_tasks, max_teammates):
    """Build groups from pre-defined annotations in tasks.md.

    Pre-defined groups are explicitly independent — VERIFY tasks within a group
    are group-internal barriers, not global ones. Cross-group task dependencies
    from build_dependency_graph are stripped since group boundaries define
    the real parallelism.
    """
    task_map = {t['id']: t for t in all_tasks}
    groups = []
    grouped_ids = set()

    for pg in predefined[:max_teammates]:
        group_task_ids = set(pg['taskIds'])
        group_tasks = []
        for tid in pg['taskIds']:
            if tid in task_map and not task_map[tid]['completed']:
                task = task_map[tid]
                # Strip dependencies that point outside this group
                task['dependencies'] = [
                    d for d in task['dependencies'] if d in group_task_ids
                ]
                group_tasks.append(task)
                grouped_ids.add(tid)

        if group_tasks:
            groups.append({
                'tasks': group_tasks,
                'ownedFiles': set(pg['files']),
                'dependencies': set(),
                'predefinedName': pg['name'],
            })

    # Tasks not in any pre-defined group become serial
    serial = [t for t in parallel_tasks if t['id'] not in grouped_ids]
    return groups, serial


def _build_groups_automatic(parallel_tasks, max_teammates):
    """Build groups via automatic file-ownership partitioning."""
    parallel_tasks.sort(key=lambda t: (t['phase'], t['id']))

    groups = []
    file_ownership = {}
    serial_tasks = []

    for task in parallel_tasks:
        task_files = set(task['files'])

        if not task_files:
            # No files — assign to least-loaded group
            if not groups:
                groups.append({'tasks': [], 'ownedFiles': set(), 'dependencies': set()})
            target = min(range(len(groups)), key=lambda i: len(groups[i]['tasks']))
            groups[target]['tasks'].append(task)
            continue

        # Find which groups own these files
        owning = set()
        for f in task_files:
            if f in file_ownership:
                owning.add(file_ownership[f])

        if len(owning) == 0:
            if len(groups) < max_teammates:
                target = len(groups)
                groups.append({'tasks': [], 'ownedFiles': set(), 'dependencies': set()})
            else:
                target = min(range(len(groups)), key=lambda i: len(groups[i]['tasks']))
            groups[target]['tasks'].append(task)
            groups[target]['ownedFiles'].update(task_files)
            for f in task_files:
                file_ownership[f] = target

        elif len(owning) == 1:
            target = list(owning)[0]
            groups[target]['tasks'].append(task)
            groups[target]['ownedFiles'].update(task_files)
            for f in task_files:
                file_ownership[f] = target

        else:
            serial_tasks.append(task)

    # Balance check
    _rebalance_groups(groups, file_ownership)

    return groups, serial_tasks


def _rebalance_groups(groups, file_ownership):
    """Redistribute tasks if any group has >2x tasks of smallest."""
    if len(groups) < 2:
        return
    for _ in range(10):
        counts = [len(g['tasks']) for g in groups]
        if not counts:
            break
        if max(counts) <= 2 * max(min(counts), 1):
            break
        largest = counts.index(max(counts))
        smallest = counts.index(min(counts))
        moved = False
        for t_idx in range(len(groups[largest]['tasks']) - 1, -1, -1):
            task = groups[largest]['tasks'][t_idx]
            task_files = set(task['files'])
            if task_files & groups[smallest]['ownedFiles']:
                continue
            groups[largest]['tasks'].pop(t_idx)
            groups[largest]['ownedFiles'] -= task_files
            groups[smallest]['tasks'].append(task)
            groups[smallest]['ownedFiles'].update(task_files)
            for f in task_files:
                file_ownership[f] = smallest
            moved = True
            break
        if not moved:
            break


def _add_group_dependencies(groups):
    """Add inter-group dependency edges based on task dependencies."""
    for i, group in enumerate(groups):
        for task in group['tasks']:
            for dep_id in task.get('dependencies', []):
                for j, other in enumerate(groups):
                    if j == i:
                        continue
                    if any(t['id'] == dep_id for t in other['tasks']):
                        group['dependencies'].add(j)


def _format_result(groups, serial_tasks, verify_tasks, all_tasks, incomplete):
    """Build the final result dict from groups."""
    # Verify tasks output
    verify_output = [
        {'id': vt['id'], 'phase': vt['phase'], 'rawBlock': vt['rawBlock'],
         'verify': vt['verify'], 'description': vt['description']}
        for vt in verify_tasks
    ]

    # Serial tasks output
    serial_output = [
        {'id': st['id'], 'phase': st['phase'], 'rawBlock': st['rawBlock'],
         'verify': st['verify'], 'description': st['description']}
        for st in serial_tasks
    ]

    # Format groups
    result_groups = []
    for i, g in enumerate(groups):
        if not g['tasks']:
            continue
        task_phases = sorted(set(t['phase'] for t in g['tasks']))
        # Use predefined name if available, otherwise auto-name
        name = g.get('predefinedName') or name_group(list(g['ownedFiles']), i)
        result_groups.append({
            'index': i,
            'name': name,
            'tasks': [t['id'] for t in g['tasks']],
            'taskDetails': g['tasks'],
            'ownedFiles': sorted(g['ownedFiles']),
            'dependencies': sorted(g['dependencies']),
            'phases': task_phases,
            'hasMultiplePhases': len(task_phases) > 1,
        })

    # Speedup estimate
    total_parallel = sum(len(g['tasks']) for g in result_groups)
    max_group = max((len(g['tasks']) for g in result_groups), default=1)
    speedup = round(total_parallel / max(max_group, 1), 1) if max_group > 0 else 1.0

    return {
        'totalTasks': len(all_tasks),
        'incompleteTasks': len(incomplete),
        'groups': result_groups,
        'serialTasks': serial_output,
        'verifyTasks': verify_output,
        'phaseCount': len(set(t['phase'] for t in incomplete)),
        'estimatedSpeedup': speedup,
    }


def name_group(owned_files: list[str], group_index: int) -> str:
    """Generate a human-readable group name from file paths."""
    if not owned_files:
        return f"group-{group_index}"

    dirs = set()
    for f in owned_files:
        parts = Path(f).parts
        if len(parts) > 1:
            dirs.add(parts[-2])

    if len(dirs) == 1:
        name = list(dirs)[0]
        if name in ('src', 'lib', 'app'):
            stems = set()
            for f in owned_files:
                stems.add(Path(f).stem.split('.')[0].lower())
            if stems:
                return '-'.join(sorted(stems)[:2])
        return name

    if len(dirs) == 2:
        return '-'.join(sorted(dirs))

    return f"group-{group_index}"


# ──────────────────────────────────────────────────────────────────
# Output
# ──────────────────────────────────────────────────────────────────

def format_plan(result: dict) -> str:
    """Format partition result as a human-readable plan."""
    lines = [
        f"Strategy: file-ownership",
        f"Teams: {len(result['groups'])} teammates + 1 lead",
        f"Tasks: {result['incompleteTasks']} incomplete / {result['totalTasks']} total",
        '',
    ]

    for g in result['groups']:
        deps = ', '.join(f"Group {d}" for d in g['dependencies']) or 'none'
        lines.append(f"Group {g['index'] + 1}: {g['name']} ({len(g['tasks'])} tasks)")
        lines.append(f"  Tasks: {', '.join(g['tasks'])}")
        lines.append(f"  Files: {', '.join(g['ownedFiles'])}")
        lines.append(f"  Deps: {deps}")
        lines.append('')

    if result['serialTasks']:
        ids = ', '.join(t['id'] for t in result['serialTasks'])
        lines.append(f"Serial tasks (lead handles): {ids}")

    if result['verifyTasks']:
        ids = ', '.join(f"{t['id']} (phase {t['phase']})" for t in result['verifyTasks'])
        lines.append(f"Verify checkpoints: {ids}")

    lines.append('')
    lines.append(f"Estimated speedup: ~{result['estimatedSpeedup']}x "
                 f"({result['incompleteTasks']} tasks across {len(result['groups'])} parallel groups)")

    return '\n'.join(lines)


# ──────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='Parse tasks.md and partition for parallel execution')
    parser.add_argument('--tasks-md', required=True, help='Path to tasks.md')
    parser.add_argument('--max-teammates', type=int, default=4, help='Max teammate groups (default: 4)')
    parser.add_argument('--strategy', default='file-ownership', help='Partition strategy')
    parser.add_argument('--format', action='store_true', help='Output formatted plan instead of JSON')
    args = parser.parse_args()

    tasks_path = Path(args.tasks_md)
    if not tasks_path.exists():
        print(f"Error: tasks.md not found at {tasks_path}", file=sys.stderr)
        sys.exit(1)

    content = tasks_path.read_text()

    tasks = parse_tasks(content)
    if not tasks:
        print("Error: No tasks found in tasks.md", file=sys.stderr)
        sys.exit(1)

    tasks = build_dependency_graph(tasks)

    # Pass content so partition_tasks can check for pre-defined groups
    result = partition_tasks(tasks, args.max_teammates, content)

    if result is None:
        print("All tasks complete. Nothing to dispatch.", file=sys.stderr)
        sys.exit(2)

    if result['incompleteTasks'] == 1:
        print("Only 1 task remaining — no parallelism benefit.", file=sys.stderr)
        sys.exit(3)

    if len(result['groups']) == 0:
        print("Error: Could not create any parallel groups.", file=sys.stderr)
        sys.exit(4)

    if args.format:
        print(format_plan(result))
    else:
        for g in result['groups']:
            for t in g['taskDetails']:
                t['dependencies'] = list(t['dependencies']) if isinstance(t['dependencies'], set) else t['dependencies']
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
