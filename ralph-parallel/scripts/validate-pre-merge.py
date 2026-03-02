#!/usr/bin/env python3
"""
Validate pre-merge conditions for ralph-parallel dispatch.

Standalone gate that MUST pass before status="merged" can be written.
Checks: (1) all tasks checked in tasks.md, (2) all groups in completedGroups,
(3-5) quality commands (build, test, lint) pass.

Usage:
    python3 validate-pre-merge.py \
      --dispatch-state <path> \
      --tasks-md <path> \
      [--skip-quality-commands]

Exit codes:
    0 = all checks pass
    1 = one or more checks failed, or input error
"""

import argparse
import json
import os
import re
import subprocess
import sys


def _resolve_project_root(dispatch_state_path):
    """Resolve project root by walking up 2 dirs from dispatch-state path.

    dispatch-state.json lives at specs/<name>/.dispatch-state.json
    Project root is 2 levels up from the directory containing it.
    Same convention as capture-baseline.sh.
    """
    spec_dir = os.path.dirname(os.path.abspath(dispatch_state_path))
    project_root = os.path.normpath(os.path.join(spec_dir, '..', '..'))
    return project_root


def _run_command(cmd, cwd, timeout=300):
    """Run a shell command and return exit code."""
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=timeout
        )
        return result.returncode
    except subprocess.TimeoutExpired:
        return -1


def main():
    parser = argparse.ArgumentParser(
        description='Validate pre-merge conditions for ralph-parallel dispatch')
    parser.add_argument('--dispatch-state', required=True,
                        help='Path to dispatch-state.json')
    parser.add_argument('--tasks-md', required=True,
                        help='Path to tasks.md')
    parser.add_argument('--skip-quality-commands', action='store_true',
                        help='Skip quality command checks (build/test/lint)')
    args = parser.parse_args()

    # Handle missing dispatch-state.json
    if not os.path.isfile(args.dispatch_state):
        print(json.dumps({"error": f"dispatch-state.json not found: {args.dispatch_state}"}))
        sys.exit(1)

    # Handle missing tasks.md
    if not os.path.isfile(args.tasks_md):
        print(json.dumps({"error": f"tasks.md not found: {args.tasks_md}"}))
        sys.exit(1)

    # Read dispatch-state.json
    try:
        with open(args.dispatch_state, 'r') as f:
            state = json.load(f)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Malformed JSON in dispatch-state: {str(e)}"}))
        sys.exit(1)

    # Read tasks.md
    with open(args.tasks_md, 'r') as f:
        tasks_content = f.read()

    checks = {}
    all_passed = True

    # Check 1: All tasks checked
    unchecked = re.findall(r'^- \[ \]\s*(\d+\.\d+)', tasks_content, re.MULTILINE)
    checked = re.findall(r'^- \[x\]\s*(\d+\.\d+)', tasks_content, re.MULTILINE)
    checks['allTasksChecked'] = {
        'passed': len(unchecked) == 0,
        'unchecked': unchecked,
        'total': len(unchecked) + len(checked),
        'checked': len(checked),
    }
    if unchecked:
        all_passed = False

    # Check 2: All groups in completedGroups
    group_names = [g['name'] for g in state.get('groups', [])]
    completed = state.get('completedGroups', [])
    missing = [g for g in group_names if g not in completed]
    checks['allGroupsCompleted'] = {
        'passed': len(missing) == 0,
        'missing': missing,
        'total': len(group_names),
        'completed': len(completed),
    }
    if missing:
        all_passed = False

    # Checks 3-5: Quality commands (unless --skip-quality-commands)
    if not args.skip_quality_commands:
        quality = state.get('qualityCommands', {})
        project_root = _resolve_project_root(args.dispatch_state)
        for slot in ['build', 'test', 'lint']:
            cmd = quality.get(slot)
            if cmd and cmd not in ('', 'null', None):
                exit_code = _run_command(cmd, project_root)
                passed = exit_code == 0
                checks[f'quality{slot.capitalize()}'] = {
                    'passed': passed,
                    'command': cmd,
                    'exitCode': exit_code,
                    'skipped': False,
                }
                if not passed:
                    all_passed = False
            else:
                checks[f'quality{slot.capitalize()}'] = {
                    'passed': True,
                    'skipped': True,
                }

    result = {'passed': all_passed, 'checks': checks}
    print(json.dumps(result, indent=2))
    sys.exit(0 if all_passed else 1)


if __name__ == '__main__':
    main()
