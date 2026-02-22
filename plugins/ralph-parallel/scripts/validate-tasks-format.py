#!/usr/bin/env python3
"""
Validate tasks.md format for ralph-parallel compatibility.

Usage:
    python3 validate-tasks-format.py --tasks-md <path> [--json]
    python3 validate-tasks-format.py --tasks-md <path> --check-verify-commands
    python3 validate-tasks-format.py --tasks-md <path> --require-quality-commands

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

        # Detect wrong formats
        if re.match(r'^#{2,3}\s+Task\s+\d+', line):
            errors.append({
                'line': i,
                'type': 'header_format',
                'message': 'Task uses header format instead of checkbox',
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
        m = re.match(r'^- \[.\]\s*(\d+\.\d+)\s*(.*)', lines[i])
        if m:
            task_id = m.group(1)
            description = m.group(2).strip()
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
                'description': description,
                'start_line': start,
                'body': '\n'.join(body_lines),
            })
        else:
            i += 1
    return blocks


def _extract_verify_cmd(body: str) -> str | None:
    """Extract the Verify field value from a task block body."""
    m = re.search(r'\*\*Verify\*\*:\s*`([^`]+)`', body)
    if not m:
        m = re.search(r'\*\*Verify\*\*:\s*```[^\n]*\n(.*?)```', body, re.DOTALL)
    return m.group(1).strip() if m else None


def _normalize_cmd(cmd: str) -> str:
    """Strip runner prefixes (npx, bunx, etc.) for comparison."""
    return re.sub(r'^(?:npx|pnpx|bunx|yarn(?:\s+run)?)\s+', '', cmd.strip())


def _cmds_overlap(cmd_a: str, cmd_b: str) -> bool:
    """Check if two commands are essentially the same (after normalization)."""
    a = _normalize_cmd(cmd_a)
    b = _normalize_cmd(cmd_b)
    # Exact match or one is a prefix of the other
    return a == b or a.startswith(b) or b.startswith(a)


def validate_verify_commands(task_blocks: list[dict], quality_commands: dict) -> list[dict]:
    """Validate verify commands against the project's declared quality commands.

    Uses the project's own Quality Commands section as source of truth.
    A verify command that matches the build/typecheck command but NOT the test
    command is flagged — it proves compilation but not correctness.

    This is ecosystem-agnostic: works for any language/toolchain because it
    compares against the project's own declared commands, not hardcoded patterns.
    """
    errors = []
    exempt_re = re.compile(r'\b(config|docs|documentation|readme|changelog)\b', re.IGNORECASE)

    build_cmd = quality_commands.get('build', '')
    typecheck_cmd = quality_commands.get('typecheck', '')
    test_cmd = quality_commands.get('test', '')

    # Skip check entirely if no test command declared (nothing to compare against)
    if not test_cmd or test_cmd == 'N/A':
        return errors

    # Also need at least one of build/typecheck to detect "compile-only"
    compile_cmds = [c for c in [build_cmd, typecheck_cmd] if c and c != 'N/A']
    if not compile_cmds:
        return errors

    for block in task_blocks:
        desc = block.get('description', '')

        # Exempt checkpoint tasks and config/docs tasks
        if '[VERIFY]' in desc or exempt_re.search(desc):
            continue

        verify_cmd = _extract_verify_cmd(block['body'])
        if not verify_cmd:
            continue

        # Split on && to get individual commands
        parts = [p.strip() for p in verify_cmd.split('&&')]

        # Check: does the verify overlap with a compile command?
        matches_compile = any(
            _cmds_overlap(part, cc) for part in parts for cc in compile_cmds
        )

        # Check: does the verify overlap with the test command?
        matches_test = any(
            _cmds_overlap(part, test_cmd) for part in parts
        )

        # Flag: looks like a compile command but not a test command
        if matches_compile and not matches_test:
            errors.append({
                'task_id': block['id'],
                'line': block['start_line'],
                'type': 'compile_only_verify',
                'verify_cmd': verify_cmd,
                'message': (
                    f"Task {block['id']} Verify matches build/typecheck "
                    f"but not test command"
                ),
                'text': f"Task {block['id']}: **Verify**: `{verify_cmd}`",
                'fix': f"Include test command: `{test_cmd}`",
            })

    return errors


def validate_quality_commands_section(content: str) -> tuple[dict, list, list]:
    """Validate the ## Quality Commands section in tasks.md.

    Returns:
        (parsed_commands, errors, warnings)
        - parsed_commands: dict with build/typecheck/lint/test values (or empty)
        - errors: list of error dicts
        - warnings: list of warning dicts
    """
    errors = []
    warnings = []
    parsed_commands = {}

    section_match = re.search(r'^## Quality Commands\b', content, re.MULTILINE)
    if not section_match:
        # Missing section is a warning, not error — older specs won't have it
        warnings.append({
            'line': 0,
            'type': 'missing_quality_commands',
            'message': 'Missing ## Quality Commands section (recommended for dispatch)',
        })
        return parsed_commands, errors, warnings

    # Extract section text (from header to next ## or EOF)
    section_start = section_match.start()
    next_section = re.search(r'^## ', content[section_start + 1:], re.MULTILINE)
    if next_section:
        section_text = content[section_start:section_start + 1 + next_section.start()]
    else:
        section_text = content[section_start:]

    # Parse the 4 fields
    for field in ['Build', 'Typecheck', 'Lint', 'Test']:
        field_match = re.search(rf'\*\*{field}\*\*:\s*`([^`]+)`', section_text)
        if field_match:
            parsed_commands[field.lower()] = field_match.group(1).strip()
        else:
            na_match = re.search(rf'\*\*{field}\*\*:\s*N/A', section_text)
            if na_match:
                parsed_commands[field.lower()] = 'N/A'

    # Warn if Test is missing or N/A
    test_val = parsed_commands.get('test')
    if not test_val or test_val == 'N/A':
        warnings.append({
            'line': 0,
            'type': 'no_test_command',
            'message': 'Quality Commands: no test command declared (baseline snapshot will be skipped)',
        })

    return parsed_commands, errors, warnings


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
            if e.get('text'):
                lines.append(f"    > {e['text']}")
            if e.get('fix'):
                lines.append(f"    FIX: {e['fix']}")

    if result['warnings']:
        lines.append('')
        lines.append('Warnings:')
        for w in result['warnings']:
            prefix = f"Line {w['line']}: " if w.get('line', 0) > 0 else ''
            lines.append(f"  {prefix}{w['message']}")

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Validate tasks.md format')
    parser.add_argument('--tasks-md', required=True, help='Path to tasks.md')
    parser.add_argument('--json', action='store_true', help='Output JSON instead of text')
    parser.add_argument('--check-verify-commands', action='store_true',
                        help='Flag verify commands that match build but not test')
    parser.add_argument('--require-quality-commands', action='store_true',
                        help='Warn if ## Quality Commands section is missing')
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

    # Parse quality commands (needed for verify check too)
    quality_commands = {}
    if args.require_quality_commands or args.check_verify_commands:
        qc_commands, qc_errors, qc_warnings = validate_quality_commands_section(content)
        quality_commands = qc_commands
        if args.require_quality_commands:
            result['errors'].extend(qc_errors)
            result['warnings'].extend(qc_warnings)
            result['qualityCommands'] = qc_commands
            if qc_errors:
                result['valid'] = False

    # Check verify commands against declared quality commands
    if args.check_verify_commands:
        lines_list = content.split('\n')
        task_blocks = _extract_task_blocks(lines_list)
        verify_errors = validate_verify_commands(task_blocks, quality_commands)
        result['errors'].extend(verify_errors)
        if verify_errors:
            result['valid'] = False

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
