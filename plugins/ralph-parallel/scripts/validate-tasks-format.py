#!/usr/bin/env python3
"""
Validate tasks.md format for ralph-parallel compatibility.

Usage:
    python3 validate-tasks-format.py --tasks-md <path> [--json] [--fix-hints]

Exit codes:
    0 = valid (all tasks parseable)
    1 = file not found / empty
    2 = format errors found (tasks exist but wrong format)
    3 = valid but warnings present (parseable but suboptimal)
"""

import argparse
import json
import re
import sys
from pathlib import Path


def validate(content: str) -> dict:
    """Validate tasks.md content. Returns structured diagnostics."""
    lines = content.split('\n')
    errors = []
    warnings = []
    parsed_count = 0
    phases_found = set()

    for i, line in enumerate(lines, 1):
        # Count valid tasks
        if re.match(r'^- \[.\]\s*\d+\.\d+', line):
            parsed_count += 1
            m = re.match(r'^- \[(.)\]\s*(\d+\.\d+)\s*(.*)', line)
            if m:
                task_id = m.group(2)
                phase = int(task_id.split('.')[0])
                phases_found.add(phase)
                rest = m.group(3)

                # Check for required fields in task body
                # (will check body after collecting all lines)

        # Detect wrong formats
        if re.match(r'^#{2,3}\s+Task\s+\d+', line):
            errors.append({
                'line': i,
                'type': 'header_format',
                'message': f'Task uses header format instead of checkbox',
                'text': line.rstrip(),
                'fix': f'- [ ] {_extract_id_from_header(line)} {_extract_desc_from_header(line)}',
            })

        if re.match(r'^- \[.\]\s+(?!\d+\.\d+)\S', line):
            errors.append({
                'line': i,
                'type': 'missing_task_id',
                'message': 'Checkbox task missing X.Y ID',
                'text': line.rstrip(),
                'fix': None,
            })

        if re.match(r'^\*\s*\[.\]\s*\d+\.\d+', line):
            errors.append({
                'line': i,
                'type': 'wrong_list_marker',
                'message': 'Uses * instead of - for list marker',
                'text': line.rstrip(),
                'fix': re.sub(r'^\*', '-', line).rstrip(),
            })

    # Check for tasks with missing fields
    task_blocks = _extract_task_blocks(lines)
    for block in task_blocks:
        task_id = block['id']
        body = block['body']

        if not re.search(r'\*\*Files\*\*:', body):
            warnings.append({
                'line': block['start_line'],
                'type': 'missing_files',
                'message': f'Task {task_id} missing **Files**: field',
            })

        if not re.search(r'\*\*Verify\*\*:', body):
            warnings.append({
                'line': block['start_line'],
                'type': 'missing_verify',
                'message': f'Task {task_id} missing **Verify**: field',
            })

        if not re.search(r'\*\*Do\*\*:', body):
            warnings.append({
                'line': block['start_line'],
                'type': 'missing_do',
                'message': f'Task {task_id} missing **Do**: field',
            })

    # Check for predefined group annotations
    has_groups = bool(re.search(r'^###\s+Group\s+\d+:', content, re.MULTILINE))
    has_files_owned = '**Files owned**' in content

    if has_groups and not has_files_owned:
        warnings.append({
            'line': 0,
            'type': 'group_missing_files',
            'message': 'Pre-defined groups found but missing **Files owned** annotations',
        })

    return {
        'valid': len(errors) == 0 and parsed_count > 0,
        'taskCount': parsed_count,
        'phaseCount': len(phases_found),
        'phases': sorted(phases_found),
        'errors': errors,
        'warnings': warnings,
        'hasPreDefinedGroups': has_groups and has_files_owned,
    }


def _extract_id_from_header(line: str) -> str:
    """Try to extract a task ID from a header-format task."""
    m = re.search(r'Task\s+(\d+)', line)
    if m:
        return f"{m.group(1)}.1"
    return "X.Y"


def _extract_desc_from_header(line: str) -> str:
    """Extract description from a header-format task."""
    m = re.match(r'^#{2,3}\s+Task\s+\d+[:\s]*(.*)', line)
    if m:
        return m.group(1).strip().rstrip(':')
    return line.strip().lstrip('#').strip()


def _extract_task_blocks(lines: list[str]) -> list[dict]:
    """Extract task blocks with their bodies for field validation."""
    blocks = []
    i = 0
    while i < len(lines):
        m = re.match(r'^- \[.\]\s*(\d+\.\d+)', lines[i])
        if m:
            task_id = m.group(1)
            start = i + 1
            body_lines = []
            i += 1
            while i < len(lines):
                if re.match(r'^- \[.\]\s*\d+\.\d+', lines[i]):
                    break
                if re.match(r'^## ', lines[i]):
                    break
                body_lines.append(lines[i])
                i += 1
            blocks.append({
                'id': task_id,
                'start_line': start,
                'body': '\n'.join(body_lines),
            })
        else:
            i += 1
    return blocks


def format_report(result: dict) -> str:
    """Format validation result as human-readable report."""
    lines = []

    if result['valid']:
        lines.append(f"VALID: {result['taskCount']} tasks across {result['phaseCount']} phases")
        if result['hasPreDefinedGroups']:
            lines.append("  Pre-defined parallel groups: yes")
    else:
        lines.append(f"INVALID: {len(result['errors'])} format error(s)")
        if result['taskCount'] > 0:
            lines.append(f"  ({result['taskCount']} tasks parsed successfully)")

    if result['errors']:
        lines.append('')
        lines.append('Errors:')
        for e in result['errors']:
            lines.append(f"  Line {e['line']}: {e['message']}")
            lines.append(f"    > {e['text']}")
            if e.get('fix'):
                lines.append(f"    FIX: {e['fix']}")

    if result['warnings']:
        lines.append('')
        lines.append('Warnings:')
        for w in result['warnings']:
            prefix = f"Line {w['line']}: " if w['line'] > 0 else ''
            lines.append(f"  {prefix}{w['message']}")

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Validate tasks.md format')
    parser.add_argument('--tasks-md', required=True, help='Path to tasks.md')
    parser.add_argument('--json', action='store_true', help='Output JSON instead of text')
    args = parser.parse_args()

    path = Path(args.tasks_md)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        sys.exit(1)

    content = path.read_text()
    if not content.strip():
        print(f"Error: {path} is empty", file=sys.stderr)
        sys.exit(1)

    result = validate(content)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(format_report(result))

    if not result['valid'] and result['errors']:
        sys.exit(2)
    elif result['warnings']:
        sys.exit(3)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
