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

# Regexes matching compile-only commands (no actual test execution)
COMPILE_ONLY_PATTERNS = [
    re.compile(r'^cargo check'),
    re.compile(r'^tsc\b.*--noEmit'),
    re.compile(r'^go build$'),
    re.compile(r'^pnpm build$'),
    re.compile(r'^npm run build$'),
    re.compile(r'^gcc\b'),
    re.compile(r'^g\+\+\b'),
    re.compile(r'^make$'),
]

# Regexes indicating a real test command
TEST_PATTERNS = [
    re.compile(r'test'),
    re.compile(r'pytest'),
    re.compile(r'jest'),
    re.compile(r'vitest'),
    re.compile(r'spec'),
    re.compile(r'\.test\.'),
]

# Suggested replacements for compile-only commands
_VERIFY_FIX_MAP = {
    'cargo check': 'cargo test',
    'tsc': 'npx jest or pnpm test',
    'go build': 'go test ./...',
    'pnpm build': 'pnpm test',
    'npm run build': 'npm test',
    'gcc': 'make test or run compiled test binary',
    'g++': 'make test or run compiled test binary',
    'make': 'make test',
}


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


def _suggest_fix(cmd: str) -> str:
    """Suggest a test command replacement for a compile-only command."""
    cmd_stripped = cmd.strip()
    for prefix, replacement in _VERIFY_FIX_MAP.items():
        if cmd_stripped.startswith(prefix):
            return f"Replace `{cmd_stripped}` with `{replacement}`"
    return f"Replace `{cmd_stripped}` with a command that runs tests"


def _is_compile_only(cmd: str) -> bool:
    """Check if a command matches a compile-only pattern."""
    cmd_stripped = cmd.strip()
    return any(p.search(cmd_stripped) for p in COMPILE_ONLY_PATTERNS)


def _has_test_pattern(cmd: str) -> bool:
    """Check if a command matches a test pattern."""
    cmd_stripped = cmd.strip()
    return any(p.search(cmd_stripped) for p in TEST_PATTERNS)


def validate_verify_commands(task_blocks: list[dict]) -> list[dict]:
    """Validate that verify commands include real tests, not just compile checks.

    Returns list of error dicts for tasks whose Verify field only contains
    compile-only commands with no test commands.
    """
    errors = []
    exempt_patterns = re.compile(r'\b(config|docs|documentation)\b', re.IGNORECASE)

    for block in task_blocks:
        desc = block.get('description', '')

        # Exempt [VERIFY] checkpoint tasks
        if '[VERIFY]' in desc:
            continue

        # Exempt config/docs tasks
        if exempt_patterns.search(desc):
            continue

        body = block['body']
        # Extract Verify field value — matches **Verify**: `cmd` or **Verify**: ```cmd```
        verify_match = re.search(r'\*\*Verify\*\*:\s*`([^`]+)`', body)
        if not verify_match:
            # Try multiline code block
            verify_match = re.search(r'\*\*Verify\*\*:\s*```[^\n]*\n(.*?)```', body, re.DOTALL)
        if not verify_match:
            continue

        verify_cmd = verify_match.group(1).strip()

        # Split on && to get individual commands
        commands = [c.strip() for c in verify_cmd.split('&&')]

        # Check: if ALL commands are compile-only AND NONE match test patterns
        all_compile_only = all(_is_compile_only(c) for c in commands)
        any_test = any(_has_test_pattern(c) for c in commands)

        if all_compile_only and not any_test:
            errors.append({
                'task_id': block['id'],
                'line': block['start_line'],
                'type': 'compile_only_verify',
                'verify_cmd': verify_cmd,
                'message': f"Task {block['id']} Verify uses compile-only command: `{verify_cmd}`",
                'text': f"Task {block['id']}: **Verify**: `{verify_cmd}`",
                'fix': _suggest_fix(commands[0]),
            })

    return errors


def validate_quality_commands_section(content: str) -> tuple[dict, list, list]:
    """Validate the ## Quality Commands section in tasks.md.

    Returns:
        (parsed_commands, errors, warnings)
        - parsed_commands: dict with Build/Typecheck/Lint/Test values (or empty)
        - errors: list of error dicts
        - warnings: list of warning dicts
    """
    errors = []
    warnings = []
    parsed_commands = {}

    # Check if section exists
    section_match = re.search(r'^## Quality Commands\b', content, re.MULTILINE)
    if not section_match:
        errors.append({
            'line': 0,
            'type': 'missing_quality_commands',
            'message': 'Missing ## Quality Commands section in tasks.md',
            'text': '',
            'fix': 'Add a ## Quality Commands section with Build, Typecheck, Lint, Test fields',
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
    fields = ['Build', 'Typecheck', 'Lint', 'Test']
    for field in fields:
        field_match = re.search(
            rf'\*\*{field}\*\*:\s*`([^`]+)`', section_text
        )
        if field_match:
            parsed_commands[field.lower()] = field_match.group(1).strip()
        else:
            # Check for N/A value
            na_match = re.search(
                rf'\*\*{field}\*\*:\s*N/A', section_text
            )
            if na_match:
                parsed_commands[field.lower()] = 'N/A'
            else:
                # Field missing entirely
                if field == 'Test':
                    warnings.append({
                        'line': 0,
                        'type': 'missing_test_command',
                        'message': f'Quality Commands: **{field}** field missing or N/A',
                    })
                else:
                    warnings.append({
                        'line': 0,
                        'type': f'missing_{field.lower()}_command',
                        'message': f'Quality Commands: **{field}** field not found',
                    })

    # Warn if Test is N/A
    if parsed_commands.get('test') == 'N/A':
        warnings.append({
            'line': 0,
            'type': 'missing_test_command',
            'message': 'Quality Commands: **Test** field is N/A',
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
    parser.add_argument('--check-verify-commands', action='store_true',
                        help='Flag compile-only verify commands (no real tests)')
    parser.add_argument('--require-quality-commands', action='store_true',
                        help='Require ## Quality Commands section with Build/Typecheck/Lint/Test')
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

    # Optional: require Quality Commands section
    if args.require_quality_commands:
        qc_commands, qc_errors, qc_warnings = validate_quality_commands_section(content)
        result['errors'].extend(qc_errors)
        result['warnings'].extend(qc_warnings)
        result['qualityCommands'] = qc_commands
        if qc_errors:
            result['valid'] = False

    # Optional: check verify commands for compile-only anti-patterns
    if args.check_verify_commands:
        lines = content.split('\n')
        task_blocks = _extract_task_blocks(lines)
        verify_errors = validate_verify_commands(task_blocks)
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
