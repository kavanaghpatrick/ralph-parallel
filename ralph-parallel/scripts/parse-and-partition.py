#!/usr/bin/env python3
"""
Parse tasks.md and partition into parallelizable groups by file ownership.

Usage:
    python3 parse-and-partition.py --tasks-md <path> [--max-teammates N] [--strategy file-ownership] [--format]

Output (JSON to stdout):
    {
        "totalTasks": 12,
        "incompleteTasks": 8,
        "groups": [...],
        "serialTasks": [...],
        "verifyTasks": [...],
        "phaseCount": 2,
        "estimatedSpeedup": 2.5
    }

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
from collections import defaultdict
from pathlib import Path


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
            # Stop at next task line or phase header
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
    # Split on commas, strip backticks and whitespace
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


def build_dependency_graph(tasks: list[dict]) -> list[dict]:
    """Add dependency edges based on file overlap and phase ordering."""
    task_map = {t['id']: t for t in tasks}

    # File overlap detection
    for i, a in enumerate(tasks):
        for b in tasks[i + 1:]:
            if a['phase'] != b['phase']:
                continue
            overlap = set(a['files']) & set(b['files'])
            if overlap:
                # Lower ID goes first
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
        # Find VERIFY task in current phase (last task typically)
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


def name_group(owned_files: list[str], group_index: int) -> str:
    """Generate a human-readable group name from file paths."""
    if not owned_files:
        return f"group-{group_index}"

    # Collect parent directory names
    dirs = set()
    for f in owned_files:
        parts = Path(f).parts
        if len(parts) > 1:
            dirs.add(parts[-2])

    if len(dirs) == 1:
        name = list(dirs)[0]
        # Clean up common suffixes
        if name in ('src', 'lib', 'app'):
            # Use grandparent or file-based naming
            stems = set()
            for f in owned_files:
                stems.add(Path(f).stem.split('.')[0].lower())
            if stems:
                return '-'.join(sorted(stems)[:2])
        return name

    if len(dirs) == 2:
        return '-'.join(sorted(dirs))

    # Fallback
    return f"group-{group_index}"


def partition_tasks(tasks: list[dict], max_teammates: int) -> dict:
    """Partition tasks into groups by file ownership."""
    # Separate task types
    incomplete = [t for t in tasks if not t['completed']]
    parallel_tasks = [t for t in incomplete if 'VERIFY' not in t['markers']]
    verify_tasks = [t for t in incomplete if 'VERIFY' in t['markers']]

    # Identify serial tasks (tasks with dependencies on multiple groups)
    # — computed after initial grouping

    if not incomplete:
        return None  # Signal: all complete

    # Sort by phase, then ID
    parallel_tasks.sort(key=lambda t: (t['phase'], t['id']))

    groups = []  # List of {tasks: [], ownedFiles: set(), dependencies: set()}
    file_ownership = {}  # file_path -> group_index
    serial_tasks = []

    for task in parallel_tasks:
        # Check file ownership
        task_files = set(task['files'])

        if not task_files:
            # No files specified — assign to least-loaded group
            if not groups:
                groups.append({'tasks': [], 'ownedFiles': set(), 'dependencies': set()})
            min_group = min(range(len(groups)), key=lambda i: len(groups[i]['tasks']))
            groups[min_group]['tasks'].append(task)
            continue

        # Find which groups own these files
        owning_groups = set()
        for f in task_files:
            if f in file_ownership:
                owning_groups.add(file_ownership[f])

        if len(owning_groups) == 0:
            # All files unowned — assign to least-loaded group (or create new)
            if len(groups) < max_teammates:
                target = len(groups)
                groups.append({'tasks': [], 'ownedFiles': set(), 'dependencies': set()})
            else:
                target = min(range(len(groups)), key=lambda i: len(groups[i]['tasks']))

            groups[target]['tasks'].append(task)
            groups[target]['ownedFiles'].update(task_files)
            for f in task_files:
                file_ownership[f] = target

        elif len(owning_groups) == 1:
            # All files owned by same group
            target = list(owning_groups)[0]
            groups[target]['tasks'].append(task)
            groups[target]['ownedFiles'].update(task_files)
            for f in task_files:
                file_ownership[f] = target

        else:
            # Files split across groups — make it serial
            serial_tasks.append(task)

    # Balance check
    if len(groups) >= 2:
        max_attempts = 10
        for _ in range(max_attempts):
            task_counts = [len(g['tasks']) for g in groups]
            if not task_counts:
                break
            max_tasks = max(task_counts)
            min_tasks = min(task_counts)
            if max_tasks <= 2 * max(min_tasks, 1):
                break

            largest = task_counts.index(max_tasks)
            smallest = task_counts.index(min_tasks)

            moved = False
            for t_idx in range(len(groups[largest]['tasks']) - 1, -1, -1):
                task = groups[largest]['tasks'][t_idx]
                task_files = set(task['files'])
                # Check if files conflict with smallest group
                if task_files & groups[smallest]['ownedFiles']:
                    continue
                # Move it
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

    # Build group dependencies
    for i, group in enumerate(groups):
        for task in group['tasks']:
            for dep_id in task['dependencies']:
                # Find which group owns this dependency
                for j, other in enumerate(groups):
                    if j == i:
                        continue
                    if any(t['id'] == dep_id for t in other['tasks']):
                        group['dependencies'].add(j)

    # Build verify tasks with phase metadata
    verify_output = []
    for vt in verify_tasks:
        verify_output.append({'id': vt['id'], 'phase': vt['phase'], 'rawBlock': vt['rawBlock'],
                              'verify': vt['verify'], 'description': vt['description']})

    # Build serial tasks output
    serial_output = []
    for st in serial_tasks:
        serial_output.append({'id': st['id'], 'phase': st['phase'], 'rawBlock': st['rawBlock'],
                              'verify': st['verify'], 'description': st['description']})

    # Name groups
    result_groups = []
    for i, g in enumerate(groups):
        if not g['tasks']:
            continue
        task_phases = sorted(set(t['phase'] for t in g['tasks']))
        result_groups.append({
            'index': i,
            'name': name_group(list(g['ownedFiles']), i),
            'tasks': [t['id'] for t in g['tasks']],
            'taskDetails': g['tasks'],
            'ownedFiles': sorted(g['ownedFiles']),
            'dependencies': sorted(g['dependencies']),
            'phases': task_phases,
            'hasMultiplePhases': len(task_phases) > 1,
        })

    # Compute speedup estimate
    total_parallel = sum(len(g['tasks']) for g in result_groups)
    max_group_tasks = max((len(g['tasks']) for g in result_groups), default=1)
    serial_count = len(serial_output) + len(verify_output)
    if max_group_tasks + serial_count > 0:
        speedup = round(total_parallel / max(max_group_tasks, 1), 1)
    else:
        speedup = 1.0

    phase_count = len(set(t['phase'] for t in incomplete))

    return {
        'totalTasks': len(tasks),
        'incompleteTasks': len(incomplete),
        'groups': result_groups,
        'serialTasks': serial_output,
        'verifyTasks': verify_output,
        'phaseCount': phase_count,
        'estimatedSpeedup': speedup,
    }


def format_plan(result: dict) -> str:
    """Format partition result as a human-readable plan."""
    lines = []
    lines.append(f"Strategy: file-ownership")
    lines.append(f"Teams: {len(result['groups'])} teammates + 1 lead")
    lines.append(f"Tasks: {result['incompleteTasks']} incomplete / {result['totalTasks']} total")
    lines.append('')

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


def main():
    parser = argparse.ArgumentParser(description='Parse tasks.md and partition for parallel execution')
    parser.add_argument('--tasks-md', required=True, help='Path to tasks.md')
    parser.add_argument('--max-teammates', type=int, default=4, help='Max teammate groups (default: 4)')
    parser.add_argument('--strategy', default='file-ownership', help='Partition strategy')
    parser.add_argument('--format', action='store_true', help='Output formatted plan instead of JSON')
    args = parser.parse_args()

    # Read tasks.md
    tasks_path = Path(args.tasks_md)
    if not tasks_path.exists():
        print(f"Error: tasks.md not found at {tasks_path}", file=sys.stderr)
        sys.exit(1)

    content = tasks_path.read_text()

    # Parse
    tasks = parse_tasks(content)
    if not tasks:
        print("Error: No tasks found in tasks.md", file=sys.stderr)
        sys.exit(1)

    # Build dependencies
    tasks = build_dependency_graph(tasks)

    # Partition
    result = partition_tasks(tasks, args.max_teammates)

    if result is None:
        print("All tasks complete. Nothing to dispatch.", file=sys.stderr)
        sys.exit(2)

    if result['incompleteTasks'] == 1:
        print("Only 1 task remaining — no parallelism benefit.", file=sys.stderr)
        sys.exit(3)

    if len(result['groups']) == 0:
        print("Error: Could not create any parallel groups.", file=sys.stderr)
        sys.exit(4)

    # Output
    if args.format:
        print(format_plan(result))
    else:
        # Clean up taskDetails for JSON output (remove non-serializable sets)
        for g in result['groups']:
            for t in g['taskDetails']:
                t['dependencies'] = list(t['dependencies']) if isinstance(t['dependencies'], set) else t['dependencies']
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
