#!/usr/bin/env python3
"""
Audit git log for commit provenance via Signed-off-by trailers.

Reads dispatch-state.json to get known group names and dispatch timestamp,
then checks git log for commits with matching Signed-off-by trailers.

Usage:
    python3 verify-commit-provenance.py --dispatch-state <path> [--since <ISO-timestamp>]

Exit codes:
    0 = always (audit tool, not a gate)
"""

import argparse
import json
import subprocess
import sys


def get_group_names(state: dict) -> list[str]:
    """Extract group names from dispatch-state.json."""
    groups = state.get('groups', [])
    return [g['name'] for g in groups if 'name' in g]


def get_git_commits(since: str) -> list[dict]:
    """Run git log and parse commits with Signed-off-by trailers.

    Returns list of dicts with keys: hash, subject, signed_off_by (list of strings).
    """
    # Format: hash + subject on first line, then trailer values on subsequent lines
    # Use %x00 as record separator to handle multi-line output
    cmd = [
        'git', 'log',
        f'--format=%x00%H %s%n%(trailers:key=Signed-off-by,valueonly)',
        f'--since={since}',
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        print(json.dumps({
            "error": f"git log failed: {e.stderr.strip()}",
            "total": 0, "attributed": 0, "unattributed": 0,
            "unknown_agent": 0, "details": []
        }))
        sys.exit(0)
    except FileNotFoundError:
        print(json.dumps({
            "error": "git not found",
            "total": 0, "attributed": 0, "unattributed": 0,
            "unknown_agent": 0, "details": []
        }))
        sys.exit(0)

    output = result.stdout.strip()
    if not output:
        return []

    # Split on null byte record separator
    records = output.split('\x00')
    commits = []

    for record in records:
        record = record.strip()
        if not record:
            continue

        lines = record.split('\n')
        if not lines:
            continue

        # First line: "hash subject"
        first_line = lines[0].strip()
        if not first_line:
            continue

        parts = first_line.split(' ', 1)
        commit_hash = parts[0]
        subject = parts[1] if len(parts) > 1 else ''

        # Remaining lines: Signed-off-by values (may be empty)
        signed_off_by = []
        for line in lines[1:]:
            line = line.strip()
            if line:
                signed_off_by.append(line)

        commits.append({
            'hash': commit_hash,
            'subject': subject,
            'signed_off_by': signed_off_by,
        })

    return commits


def audit_provenance(commits: list[dict], known_groups: list[str]) -> dict:
    """Audit commits for provenance coverage.

    Returns dict with total, attributed, unattributed, unknown_agent counts
    and details list.
    """
    total = len(commits)
    attributed = 0
    unattributed = 0
    unknown_agent = 0
    details = []

    known_set = set(known_groups)

    for commit in commits:
        trailers = commit['signed_off_by']
        short_hash = commit['hash'][:8]

        if not trailers:
            unattributed += 1
            details.append({
                'hash': short_hash,
                'subject': commit['subject'],
                'status': 'unattributed',
                'trailer': None,
            })
        else:
            # Check if any trailer matches a known group
            matched = False
            for trailer in trailers:
                if trailer in known_set:
                    attributed += 1
                    matched = True
                    details.append({
                        'hash': short_hash,
                        'subject': commit['subject'],
                        'status': 'attributed',
                        'trailer': trailer,
                    })
                    break

            if not matched:
                unknown_agent += 1
                details.append({
                    'hash': short_hash,
                    'subject': commit['subject'],
                    'status': 'unknown_agent',
                    'trailer': trailers[0],
                })

    return {
        'total': total,
        'attributed': attributed,
        'unattributed': unattributed,
        'unknown_agent': unknown_agent,
        'details': details,
    }


def main():
    parser = argparse.ArgumentParser(
        description='Audit git log for commit provenance via Signed-off-by trailers')
    parser.add_argument('--dispatch-state', required=True,
                        help='Path to dispatch-state.json')
    parser.add_argument('--since', default=None,
                        help='ISO timestamp to search from (defaults to dispatchedAt from state)')
    args = parser.parse_args()

    # Read dispatch-state.json
    try:
        with open(args.dispatch_state, 'r') as f:
            state = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(json.dumps({
            "error": str(e),
            "total": 0, "attributed": 0, "unattributed": 0,
            "unknown_agent": 0, "details": []
        }))
        sys.exit(0)

    # Get group names
    known_groups = get_group_names(state)
    if not known_groups:
        print(json.dumps({
            "total": 0, "attributed": 0, "unattributed": 0,
            "unknown_agent": 0, "details": [],
            "note": "no groups found in dispatch-state.json"
        }))
        sys.exit(0)

    # Determine since timestamp
    since = args.since or state.get('dispatchedAt', '')
    if not since:
        print(json.dumps({
            "error": "no --since provided and no dispatchedAt in dispatch-state.json",
            "total": 0, "attributed": 0, "unattributed": 0,
            "unknown_agent": 0, "details": []
        }))
        sys.exit(0)

    # Get commits and audit
    commits = get_git_commits(since)
    result = audit_provenance(commits, known_groups)

    print(json.dumps(result, indent=2))
    sys.exit(0)


if __name__ == '__main__':
    main()
