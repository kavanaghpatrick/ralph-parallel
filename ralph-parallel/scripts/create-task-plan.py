#!/usr/bin/env python3
"""
Create a deterministic task plan from partition JSON.

Usage:
    python3 create-task-plan.py --partition-file /tmp/myspec-partition.json

Reads partition JSON (from parse-and-partition.py), outputs a JSON array of
task plan entries in topological order (dependencies precede dependents).

Each entry has: subject, description, activeForm, blockedBy (zero-based indices).

Exit codes:
    0 = success
    1 = error (missing file, invalid JSON)
"""

import argparse
import json
import sys


def create_task_plan(partition: dict) -> list[dict]:
    """Build a task plan array from partition JSON.

    Returns a list of task plan entries in topological order. Each entry has:
      - subject: "{id}: {description}" or "{id}: [VERIFY] ..."
      - description: rawBlock content from partition
      - activeForm: "Implementing {id}" or "Running {id} verify"
      - blockedBy: list of zero-based indices into this array
    """
    plan = []
    # Map: spec_task_id -> index in plan array
    id_to_index = {}

    groups = partition['groups']
    verify_tasks = partition.get('verifyTasks', [])
    serial_tasks = partition.get('serialTasks', [])

    # Determine phases present
    all_phases = sorted(set(
        t['phase'] for g in groups for t in g['taskDetails']
    )) if groups else []

    for phase in all_phases:
        # 1. Emit all group tasks for this phase
        for group in groups:
            for task in group['taskDetails']:
                if task['phase'] != phase:
                    continue
                blocked_by = []
                # Phase N+1 tasks depend on Phase N verify
                if phase > all_phases[0]:
                    prev_phase = all_phases[all_phases.index(phase) - 1]
                    for vt in verify_tasks:
                        if vt['phase'] == prev_phase and vt['id'] in id_to_index:
                            blocked_by.append(id_to_index[vt['id']])
                idx = len(plan)
                id_to_index[task['id']] = idx
                plan.append({
                    'subject': f"{task['id']}: {task['description']}",
                    'description': task.get('rawBlock', ''),
                    'activeForm': f"Implementing {task['id']}",
                    'blockedBy': blocked_by,
                })

        # 2. Emit verify task for this phase (if exists)
        for vt in verify_tasks:
            if vt['phase'] != phase:
                continue
            blocked_by = []
            # VERIFY depends on ALL same-phase group tasks
            for group in groups:
                for task in group['taskDetails']:
                    if task['phase'] == phase and task['id'] in id_to_index:
                        blocked_by.append(id_to_index[task['id']])
            idx = len(plan)
            id_to_index[vt['id']] = idx
            plan.append({
                'subject': f"{vt['id']}: {vt['description']}",
                'description': vt.get('rawBlock', ''),
                'activeForm': f"Running {vt['id']} verify",
                'blockedBy': blocked_by,
            })

    # 3. Emit serial tasks (depend on last verify or all parallel tasks)
    last_verify_idx = None
    for vt in reversed(verify_tasks):
        if vt['id'] in id_to_index:
            last_verify_idx = id_to_index[vt['id']]
            break

    for st in serial_tasks:
        blocked_by = [last_verify_idx] if last_verify_idx is not None else []
        idx = len(plan)
        id_to_index[st['id']] = idx
        plan.append({
            'subject': f"{st['id']}: {st['description']}",
            'description': st.get('rawBlock', ''),
            'activeForm': f"Implementing {st['id']}",
            'blockedBy': blocked_by,
        })
        last_verify_idx = idx  # serial tasks chain

    return plan


def main():
    parser = argparse.ArgumentParser(
        description='Create deterministic task plan from partition JSON')
    parser.add_argument('--partition-file', required=True,
                        help='Path to partition JSON from parse-and-partition.py')
    args = parser.parse_args()

    try:
        with open(args.partition_file) as f:
            partition = json.load(f)
    except FileNotFoundError:
        print(f"Error: Partition file not found: {args.partition_file}",
              file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in partition file: {e}", file=sys.stderr)
        sys.exit(1)

    plan = create_task_plan(partition)
    json.dump(plan, sys.stdout, indent=2)
    print()  # trailing newline


if __name__ == '__main__':
    main()
