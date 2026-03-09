#!/usr/bin/env python3
"""
Write .dispatch-state.json atomically from partition JSON.

Usage:
    python3 write-dispatch-state.py \\
        --partition-file /tmp/myspec-partition.json \\
        --strategy file-ownership \\
        --max-teammates 4 \\
        --spec-dir specs/myspec

Output: JSON status to stdout. Writes .dispatch-state.json to spec-dir.
"""

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone


def _atomic_write(path: str, data: dict) -> None:
    """Write JSON data atomically using tempfile + os.replace."""
    dir_name = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile(mode='w', dir=dir_name,
                                     suffix='.tmp', delete=False) as f:
        json.dump(data, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
        tmp_path = f.name
    try:
        os.replace(tmp_path, path)
    except Exception:
        os.unlink(tmp_path)
        raise


def check_existing_state(spec_dir: str) -> dict | None:
    """Check for existing dispatch state and handle transitions.

    Returns the existing state dict if superseding, None otherwise.
    Exits with code 2 if state is 'merging'.
    """
    state_file = os.path.join(spec_dir, '.dispatch-state.json')
    if not os.path.exists(state_file):
        return None  # Fresh write, no conflicts

    with open(state_file) as f:
        existing = json.load(f)

    status = existing.get('status', '')

    if status == 'merging':
        print("ERROR: Existing dispatch is in 'merging' state. "
              "Run /ralph-parallel:merge --abort first.", file=sys.stderr)
        sys.exit(2)

    if status == 'dispatched':
        print(f"WARNING: Superseding existing 'dispatched' state "
              f"(dispatched at {existing.get('dispatchedAt', 'unknown')})",
              file=sys.stderr)
        # Mark old state as superseded (write superseded version first)
        existing['status'] = 'superseded'
        existing['supersededAt'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _atomic_write(state_file, existing)
        return existing

    return None


def build_dispatch_state(partition: dict, args: argparse.Namespace) -> dict:
    """Build the dispatch state dict with all 11 fields."""
    # Strip taskDetails from groups, keep only index, name, tasks, ownedFiles, dependencies
    groups = []
    for g in partition.get('groups', []):
        groups.append({
            'index': g['index'],
            'name': g['name'],
            'tasks': g['tasks'],
            'ownedFiles': g['ownedFiles'],
            'dependencies': g.get('dependencies', []),
        })

    # Read session ID from env
    session_id = os.environ.get('CLAUDE_SESSION_ID')
    if session_id is None:
        print("WARNING: CLAUDE_SESSION_ID not set. "
              "coordinatorSessionId will be null.", file=sys.stderr)

    # Build ISO timestamp ending in Z
    dispatched_at = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

    return {
        'dispatchedAt': dispatched_at,
        'coordinatorSessionId': session_id,
        'strategy': args.strategy,
        'maxTeammates': args.max_teammates,
        'groups': groups,
        'serialTasks': [t['id'] for t in partition.get('serialTasks', [])],
        'verifyTasks': [t['id'] for t in partition.get('verifyTasks', [])],
        'qualityCommands': partition.get('qualityCommands', {}),
        'baselineSnapshot': None,
        'status': 'dispatched',
        'completedGroups': [],
    }


def main():
    parser = argparse.ArgumentParser(
        description='Write .dispatch-state.json atomically from partition JSON.')
    parser.add_argument('--partition-file', required=True,
                        help='Path to partition JSON from parse-and-partition.py')
    parser.add_argument('--strategy', required=True,
                        choices=['file-ownership', 'worktree'],
                        help='Dispatch strategy')
    parser.add_argument('--max-teammates', required=True, type=int,
                        help='Maximum number of teammates')
    parser.add_argument('--spec-dir', required=True,
                        help='Path to spec directory')
    args = parser.parse_args()

    if args.max_teammates < 1 or args.max_teammates > 20:
        print(f"ERROR: --max-teammates must be between 1 and 20, got {args.max_teammates}",
              file=sys.stderr)
        sys.exit(1)

    try:
        # Validate inputs
        if not os.path.isfile(args.partition_file):
            print(f"ERROR: Partition file not found: {args.partition_file}",
                  file=sys.stderr)
            sys.exit(1)

        if not os.path.isdir(args.spec_dir):
            print(f"ERROR: Spec directory not found: {args.spec_dir}",
                  file=sys.stderr)
            sys.exit(1)

        # Read partition
        with open(args.partition_file) as f:
            partition = json.load(f)

        # Check existing state (may supersede or error)
        superseded_state = check_existing_state(args.spec_dir)

        # Build and write new state
        state = build_dispatch_state(partition, args)
        state_path = os.path.join(args.spec_dir, '.dispatch-state.json')
        _atomic_write(state_path, state)

        # Output status
        result = {
            'status': 'written',
            'path': state_path,
            'superseded': superseded_state is not None,
        }
        if superseded_state is not None:
            result['previousStatus'] = 'dispatched'

        json.dump(result, sys.stdout)
        print()  # trailing newline
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR: Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
