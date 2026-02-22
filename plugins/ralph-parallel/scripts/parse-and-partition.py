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
import os
import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib  # type: ignore[no-redefine]
    except ModuleNotFoundError:
        tomllib = None  # type: ignore[assignment]


# ──────────────────────────────────────────────────────────────────
# Quality Command Discovery
# ──────────────────────────────────────────────────────────────────

WEAK_PATTERNS = ['grep', 'ls ', 'cat ', 'echo ', 'true', 'test -f', 'wc ']
STATIC_PATTERNS = ['tsc', 'typecheck', 'lint', 'eslint', 'prettier', 'mypy', 'pyright', 'clippy', 'ruff']
RUNTIME_PATTERNS = ['build', 'vite', 'webpack', 'test', 'vitest', 'jest', 'pytest', 'cargo test', 'curl', 'serve', 'node ', 'python3 ']


def _discover_node(root: Path) -> dict:
    """Discover quality commands from package.json."""
    result = {}
    try:
        pkg = json.loads((root / "package.json").read_text())
        scripts = pkg.get("scripts", {})
        mapping = {
            "typecheck": ["typecheck", "check-types"],
            "build": ["build"],
            "test": ["test"],
            "lint": ["lint"],
            "dev": ["dev", "start"],
        }
        for slot, keys in mapping.items():
            for key in keys:
                if key in scripts:
                    val = scripts[key]
                    if '&&' not in val and '|' not in val and not val.startswith('npx ') and not val.startswith('npm '):
                        val = f"npx {val}"
                    result[slot] = val
                    break
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        pass
    return result


def _discover_python(root: Path) -> dict:
    """Discover quality commands from pyproject.toml."""
    result = {}
    if tomllib is None:
        return result
    try:
        with open(root / "pyproject.toml", "rb") as f:
            pyproject = tomllib.load(f)
        tool = pyproject.get("tool", {})
        if "pytest" in tool or "pytest.ini_options" in tool.get("pytest", {}):
            result["test"] = "pytest"
        deps_str = json.dumps(pyproject.get("project", {}).get("optional-dependencies", {}))
        if "mypy" in deps_str:
            result["typecheck"] = "mypy ."
        elif "pyright" in deps_str:
            result["typecheck"] = "pyright"
        if "ruff" in deps_str or "ruff" in tool:
            result["lint"] = "ruff check ."
    except (FileNotFoundError, Exception):
        pass
    return result


def _discover_makefile(root: Path) -> dict:
    """Discover quality commands from Makefile targets."""
    result = {}
    try:
        makefile = (root / "Makefile").read_text()
        target_map = {"test": "test", "build": "build", "lint": "lint", "check": "typecheck", "typecheck": "typecheck"}
        for line in makefile.split('\n'):
            m = re.match(r'^(\w+)\s*:', line)
            if m:
                target = m.group(1)
                if target in target_map:
                    result.setdefault(target_map[target], f"make {target}")
    except FileNotFoundError:
        pass
    return result


def _discover_rust(root: Path) -> dict:
    """Discover quality commands from Cargo.toml."""
    result = {}
    try:
        (root / "Cargo.toml").read_text()
        result["build"] = "cargo build"
        result["test"] = "cargo test"
        result["lint"] = "cargo clippy"
    except FileNotFoundError:
        pass
    return result


def discover_quality_commands(project_root: str) -> dict:
    """Discover available quality commands from project config files.

    Checks ecosystems in order: Node.js, Python, Makefile, Rust.
    First non-null value wins per slot.
    """
    result = {"typecheck": None, "build": None, "test": None, "lint": None, "dev": None}
    root = Path(project_root)

    for discover_fn in [_discover_node, _discover_python, _discover_makefile, _discover_rust]:
        partial = discover_fn(root)
        for slot, val in partial.items():
            if result.get(slot) is None and val is not None:
                result[slot] = val

    return result


def classify_verify_commands(tasks: list[dict]) -> dict:
    """Classify verify commands by quality tier: runtime > static > weak > none."""
    counts = {"runtime": 0, "static": 0, "weak": 0, "none": 0}
    details = []

    for task in tasks:
        verify = task.get('verify', '').strip()
        if not verify:
            counts["none"] += 1
            details.append({"taskId": task['id'], "tier": "none", "command": ""})
            continue

        cmd_lower = verify.lower()
        tier = "weak"  # default

        # Check runtime first (highest tier)
        for pat in RUNTIME_PATTERNS:
            if pat in cmd_lower:
                tier = "runtime"
                break

        # Then static
        if tier == "weak":
            for pat in STATIC_PATTERNS:
                if pat in cmd_lower:
                    tier = "static"
                    break

        # Then weak
        if tier != "runtime" and tier != "static":
            for pat in WEAK_PATTERNS:
                if pat in cmd_lower:
                    tier = "weak"
                    break

        counts[tier] += 1
        details.append({"taskId": task['id'], "tier": tier, "command": verify})

    return {**counts, "details": details}


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

def partition_tasks(tasks: list[dict], max_teammates: int, content: str = '',
                    quality_commands: dict = None, verify_quality: dict = None,
                    strategy: str = 'file-ownership') -> dict:
    """Partition tasks into groups.

    If tasks.md contains pre-defined group annotations (### Group N: Name),
    those are used directly. Falls back to automatic file-ownership
    partitioning when no annotations exist.

    strategy='worktree' skips file-ownership conflict detection since each
    teammate gets an isolated worktree branch.
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
    elif strategy == 'worktree':
        groups, serial_tasks = _build_groups_worktree(
            parallel_tasks, max_teammates)
    else:
        groups, serial_tasks = _build_groups_automatic(
            parallel_tasks, max_teammates)

    # Build inter-group dependencies
    _add_group_dependencies(groups)

    return _format_result(groups, serial_tasks, verify_tasks, tasks, incomplete,
                          quality_commands=quality_commands, verify_quality=verify_quality)


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


def _build_groups_worktree(parallel_tasks, max_teammates):
    """Build groups via load-balanced partitioning for worktree strategy.

    Each teammate gets an isolated worktree, so file ownership conflicts
    don't apply. Tasks are distributed round-robin by phase to balance load.
    No tasks are serialized due to file conflicts.
    """
    parallel_tasks.sort(key=lambda t: (t['phase'], t['id']))

    groups = [{'tasks': [], 'ownedFiles': set(), 'dependencies': set()}
              for _ in range(min(max_teammates, len(parallel_tasks)))]

    for i, task in enumerate(parallel_tasks):
        target = i % len(groups)
        groups[target]['tasks'].append(task)
        groups[target]['ownedFiles'].update(task['files'])

    # Remove empty groups
    groups = [g for g in groups if g['tasks']]
    return groups, []  # No serial tasks — worktree eliminates file conflicts


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


def _format_result(groups, serial_tasks, verify_tasks, all_tasks, incomplete,
                   quality_commands=None, verify_quality=None):
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

    result = {
        'totalTasks': len(all_tasks),
        'incompleteTasks': len(incomplete),
        'groups': result_groups,
        'serialTasks': serial_output,
        'verifyTasks': verify_output,
        'phaseCount': len(set(t['phase'] for t in incomplete)),
        'estimatedSpeedup': speedup,
    }
    if quality_commands is not None:
        result['qualityCommands'] = quality_commands
    if verify_quality is not None:
        result['verifyQuality'] = verify_quality
    return result


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

def format_plan(result: dict, strategy: str = 'file-ownership') -> str:
    """Format partition result as a human-readable plan."""
    lines = [
        f"Strategy: {strategy}",
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

    # Weak verify warning
    vq = result.get('verifyQuality')
    if vq:
        total = vq.get('runtime', 0) + vq.get('static', 0) + vq.get('weak', 0) + vq.get('none', 0)
        weak_count = vq.get('weak', 0) + vq.get('none', 0)
        if total > 0 and weak_count / total > 0.5:
            lines.append('')
            lines.append(f"WARNING: {weak_count}/{total} tasks have weak verify commands (grep/ls/cat).")
            lines.append("Consider adding build/test verify commands to tasks.md before dispatch.")

    # Quality commands summary
    qc = result.get('qualityCommands')
    if qc:
        discovered = [k for k, v in qc.items() if v is not None]
        if discovered:
            lines.append('')
            lines.append(f"Quality commands discovered: {', '.join(discovered)}")

    return '\n'.join(lines)


# ──────────────────────────────────────────────────────────────────
# Format Diagnostics
# ──────────────────────────────────────────────────────────────────

def diagnose_format(content: str, path: Path) -> None:
    """When no tasks are found, diagnose WHY and print actionable fixes."""
    lines = content.strip().split('\n')
    if not lines or not content.strip():
        print(f"Error: {path} is empty.", file=sys.stderr)
        return

    issues = []

    # Detect common wrong formats
    header_tasks = []
    bare_checkboxes = []
    near_miss_ids = []

    for i, line in enumerate(lines, 1):
        # Common LLM format: ## Task N: or ### Task N:
        if re.match(r'^#{2,3}\s+Task\s+\d+', line):
            header_tasks.append(i)

        # Checkbox without X.Y ID: - [ ] Some description
        if re.match(r'^- \[.\]\s+(?!\d+\.\d+)', line):
            bare_checkboxes.append(i)

        # Has X.Y but wrong checkbox: * [x] 1.1 or - [✓] 1.1
        if re.match(r'^[*-]\s*\[.\]\s*\d+\.\d+', line) and not re.match(r'^- \[.\]\s*\d+\.\d+', line):
            near_miss_ids.append(i)

        # Numbered list: 1. Task description (no checkbox)
        if re.match(r'^\d+\.\s+(?!.*\*\*)', line) and i < 20:
            # Only flag in first 20 lines to avoid matching Do: steps
            pass

    print(f"Error: No parseable tasks found in {path}", file=sys.stderr)
    print("", file=sys.stderr)

    if header_tasks:
        print(f"FOUND: {len(header_tasks)} task(s) using '## Task N:' header format (lines: {', '.join(str(l) for l in header_tasks[:5])})", file=sys.stderr)
        print("  FIX: Use checkbox format instead:", file=sys.stderr)
        print("    WRONG:  ## Task 1: Implement feature", file=sys.stderr)
        print("    RIGHT:  - [ ] 1.1 Implement feature", file=sys.stderr)
        issues.append("header_format")

    if bare_checkboxes:
        print(f"FOUND: {len(bare_checkboxes)} checkbox(es) without X.Y task IDs (lines: {', '.join(str(l) for l in bare_checkboxes[:5])})", file=sys.stderr)
        print("  FIX: Add phase.sequence ID after checkbox:", file=sys.stderr)
        print("    WRONG:  - [ ] Implement feature", file=sys.stderr)
        print("    RIGHT:  - [ ] 1.1 Implement feature", file=sys.stderr)
        issues.append("missing_task_id")

    if near_miss_ids:
        print(f"FOUND: {len(near_miss_ids)} near-match(es) with wrong list marker (lines: {', '.join(str(l) for l in near_miss_ids[:5])})", file=sys.stderr)
        print("  FIX: Use '- [ ]' with exactly one space after dash:", file=sys.stderr)
        print("    WRONG:  * [x] 1.1 Task", file=sys.stderr)
        print("    RIGHT:  - [x] 1.1 Task", file=sys.stderr)
        issues.append("wrong_list_marker")

    if not issues:
        print("The file has content but no recognizable task format.", file=sys.stderr)
        print("", file=sys.stderr)
        print("Expected format:", file=sys.stderr)
        print("  - [ ] 1.1 [P] Task description", file=sys.stderr)
        print("    - **Do**:", file=sys.stderr)
        print("      1. Step one", file=sys.stderr)
        print("    - **Files**: `path/to/file`", file=sys.stderr)
        print("    - **Done when**: Criteria", file=sys.stderr)
        print("    - **Verify**: `test command`", file=sys.stderr)
        print("    - **Commit**: `feat(scope): description`", file=sys.stderr)

    print("", file=sys.stderr)
    print("Required task line format: - [ ] X.Y [optional markers] Description", file=sys.stderr)
    print("  X = phase number (1, 2, 3...), Y = task sequence (1, 2, 3...)", file=sys.stderr)
    print("  Markers: [P] = parallelizable, [VERIFY] = quality checkpoint", file=sys.stderr)


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
        diagnose_format(content, tasks_path)
        sys.exit(1)

    tasks = build_dependency_graph(tasks)

    # Infer project root from tasks.md path (walk up 2 dirs from specs/$name/tasks.md)
    tasks_path_resolved = tasks_path.resolve()
    project_root = str(tasks_path_resolved.parent.parent.parent)
    quality_commands = discover_quality_commands(project_root)
    verify_quality = classify_verify_commands(tasks)

    # Pass content so partition_tasks can check for pre-defined groups
    result = partition_tasks(tasks, args.max_teammates, content,
                             quality_commands=quality_commands, verify_quality=verify_quality,
                             strategy=args.strategy)

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
        print(format_plan(result, strategy=args.strategy))
    else:
        for g in result['groups']:
            for t in g['taskDetails']:
                t['dependencies'] = list(t['dependencies']) if isinstance(t['dependencies'], set) else t['dependencies']
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
