#!/usr/bin/env python3
"""
Mark completed tasks in tasks.md based on dispatch-state.json.

Reads dispatch-state.json's completedGroups and groups arrays, maps group
names to task IDs, then updates tasks.md checkboxes from [ ] to [x].

Usage:
    python3 mark-tasks-complete.py --dispatch-state <path> --tasks-md <path>

Exit codes:
    0 = always (informational, never blocks)
"""

import argparse
import json
import re
import sys


def main():
    parser = argparse.ArgumentParser(
        description='Mark completed tasks in tasks.md from dispatch-state.json')
    parser.add_argument('--dispatch-state', required=True,
                        help='Path to dispatch-state.json')
    parser.add_argument('--tasks-md', required=True,
                        help='Path to tasks.md')
    args = parser.parse_args()

    # Read dispatch-state.json
    try:
        with open(args.dispatch_state, 'r') as f:
            state = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(json.dumps({"error": str(e), "marked": 0,
                          "alreadyComplete": 0, "notFound": 0}))
        sys.exit(0)

    completed_groups = state.get('completedGroups', [])
    groups = state.get('groups', [])

    if not completed_groups or not groups:
        print(json.dumps({"marked": 0, "alreadyComplete": 0, "notFound": 0}))
        sys.exit(0)

    # Build map: group name -> list of task IDs
    group_tasks = {}
    for group in groups:
        group_tasks[group['name']] = group.get('tasks', [])

    # Collect all task IDs from completed groups
    task_ids = []
    for group_name in completed_groups:
        if group_name in group_tasks:
            task_ids.extend(group_tasks[group_name])

    if not task_ids:
        print(json.dumps({"marked": 0, "alreadyComplete": 0, "notFound": 0}))
        sys.exit(0)

    # Read tasks.md
    try:
        with open(args.tasks_md, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        print(json.dumps({"error": f"tasks.md not found: {args.tasks_md}",
                          "marked": 0, "alreadyComplete": 0, "notFound": 0}))
        sys.exit(0)

    marked = 0
    already_complete = 0
    not_found = 0

    for task_id in task_ids:
        # Escape dots in task ID for regex
        escaped_id = re.escape(task_id)

        # Check if already marked complete
        already_pattern = re.compile(
            rf'^- \[x\] {escaped_id}\b', re.MULTILINE)
        if already_pattern.search(content):
            already_complete += 1
            continue

        # Try to mark incomplete -> complete
        incomplete_pattern = re.compile(
            rf'^(- )\[ \]( {escaped_id}\b)', re.MULTILINE)
        new_content, count = incomplete_pattern.subn(r'\1[x]\2', content)

        if count > 0:
            content = new_content
            marked += count
        else:
            not_found += 1

    # Write updated content back
    if marked > 0:
        with open(args.tasks_md, 'w') as f:
            f.write(content)

    result = {
        "marked": marked,
        "alreadyComplete": already_complete,
        "notFound": not_found,
    }
    print(json.dumps(result))
    sys.exit(0)


if __name__ == '__main__':
    main()
