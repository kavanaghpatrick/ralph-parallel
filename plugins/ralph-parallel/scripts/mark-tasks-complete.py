#!/usr/bin/env python3
"""
Mark completed tasks in tasks.md based on dispatch-state.json.

Reads dispatch-state.json's completedGroups and groups arrays, maps group
names to task IDs, then updates tasks.md checkboxes from [ ] to [x].

Usage:
    python3 mark-tasks-complete.py --dispatch-state <path> --tasks-md <path> [--dry-run]

Exit codes:
    0 = success (including no-op cases like missing completedGroups/groups)
    1 = tasks.md file not found
"""

import argparse
import fcntl
import json
import os
import re
import sys


def main():
    try:
        parser = argparse.ArgumentParser(
            description='Mark completed tasks in tasks.md from dispatch-state.json')
        parser.add_argument('--dispatch-state', required=True,
                            help='Path to dispatch-state.json')
        parser.add_argument('--tasks-md', required=True,
                            help='Path to tasks.md')
        parser.add_argument('--dry-run', action='store_true',
                            help='Print what would be changed without writing')
        parser.add_argument('--strict', action='store_true',
                            help='Only mark tasks that are already [x] (cross-check mode)')
        args = parser.parse_args()

        # Read dispatch-state.json
        try:
            with open(args.dispatch_state, 'r', encoding='utf-8') as f:
                state = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            print(json.dumps({"error": str(e), "marked": 0,
                              "alreadyComplete": 0, "notFound": 0}))
            sys.exit(0)

        # Edge case: missing completedGroups key -- default to empty list
        completed_groups = state.get('completedGroups', [])

        # Edge case: missing groups key -- exit 0 with empty result
        groups = state.get('groups', [])
        if not groups:
            print(json.dumps({"marked": 0, "alreadyComplete": 0, "notFound": 0}))
            sys.exit(0)

        if not completed_groups:
            print(json.dumps({"marked": 0, "alreadyComplete": 0, "notFound": 0}))
            sys.exit(0)

        # Build map: group name -> list of task IDs (accumulate, don't overwrite)
        group_tasks = {}
        for group in groups:
            name = group['name']
            tasks = group.get('tasks', [])
            if name in group_tasks:
                group_tasks[name].extend(tasks)
            else:
                group_tasks[name] = list(tasks)

        # Collect all task IDs from completed groups (deduplicate)
        task_ids = []
        seen_ids = set()
        for group_name in completed_groups:
            if group_name in group_tasks:
                for tid in group_tasks[group_name]:
                    if tid not in seen_ids:
                        task_ids.append(tid)
                        seen_ids.add(tid)

        if not task_ids:
            print(json.dumps({"marked": 0, "alreadyComplete": 0, "notFound": 0}))
            sys.exit(0)

        # Edge case: tasks.md doesn't exist -- exit 1 with error message
        if not os.path.isfile(args.tasks_md):
            print(f"Error: tasks.md not found: {args.tasks_md}", file=sys.stderr)
            print(json.dumps({"error": f"tasks.md not found: {args.tasks_md}",
                              "marked": 0, "alreadyComplete": 0, "notFound": 0}))
            sys.exit(1)

        # File-locked read-modify-write cycle to prevent concurrent corruption
        lock_path = args.tasks_md + '.lock'
        lock_fd = None
        try:
            lock_fd = open(lock_path, 'w', encoding='utf-8')
            fcntl.flock(lock_fd, fcntl.LOCK_EX)

            # Read tasks.md
            with open(args.tasks_md, 'r', encoding='utf-8') as f:
                content = f.read()

            marked = 0
            already_complete = 0
            not_found = 0
            skipped = []  # strict mode tracking

            for task_id in task_ids:
                # Escape dots in task ID for regex
                escaped_id = re.escape(task_id)

                # Idempotency: already-marked [x] tasks increment alreadyComplete counter
                already_pattern = re.compile(
                    rf'^- \[x\] {escaped_id}\b', re.MULTILINE)
                if already_pattern.search(content):
                    already_complete += 1
                    continue

                # In strict mode: task is [ ] but in completedGroup = suspicious
                if args.strict:
                    incomplete_pattern = re.compile(
                        rf'^- \[ \] {escaped_id}\b', re.MULTILINE)
                    if incomplete_pattern.search(content):
                        skipped.append(task_id)
                        print(f"WARNING: Task {task_id} is in completedGroup but still "
                              f"unchecked [ ] in tasks.md — skipping (strict mode)",
                              file=sys.stderr)
                        continue
                    # Task not found at all
                    not_found += 1
                    continue

                # Default mode: mark incomplete -> complete (existing behavior)
                incomplete_pattern = re.compile(
                    rf'^(- )\[ \]( {escaped_id}\b)', re.MULTILINE)
                new_content, count = incomplete_pattern.subn(r'\1[x]\2', content)

                if count > 0:
                    content = new_content
                    marked += count
                else:
                    # Edge case: task ID in completedGroups but regex doesn't match
                    not_found += 1

            # Write updated content back (unless --dry-run)
            if marked > 0 and not args.dry_run:
                with open(args.tasks_md, 'w', encoding='utf-8') as f:
                    f.write(content)
        finally:
            if lock_fd:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
                lock_fd.close()

        result = {
            "marked": marked,
            "alreadyComplete": already_complete,
            "notFound": not_found,
        }
        if args.strict:
            result["strict"] = True
            result["skipped"] = skipped
        if args.dry_run:
            result["dryRun"] = True
        print(json.dumps(result))

        # In strict mode, exit non-zero if any tasks were skipped
        if args.strict and skipped:
            sys.exit(2)
        sys.exit(0)
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR: Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
