#!/usr/bin/env python3
"""
Build a teammate prompt from partition JSON for a specific group.

Usage:
    python3 build-teammate-prompt.py \\
        --partition-file partition.json \\
        --group-index 0 \\
        --spec-name user-auth \\
        --project-root /path/to/project \\
        --task-ids "#1,#2,#3"

Or pipe partition JSON via stdin:
    cat partition.json | python3 build-teammate-prompt.py --group-index 0 ...

Output: Complete teammate prompt text to stdout.
"""

import argparse
import json
import sys


def build_quality_section(quality_commands: dict, baseline_test_count: int = 0) -> list[str]:
    """Build the Quality Checks section lines from discovered quality commands."""
    lines = []
    tc = quality_commands.get('typecheck')
    test = quality_commands.get('test')
    build = quality_commands.get('build')

    lines.append('Before marking ANY task complete, run these checks in order:')
    lines.append('')
    step = 1
    if build:
        lines.append(f'{step}. Build: `{build}`')
        step += 1
    if tc:
        lines.append(f'{step}. Typecheck: `{tc}`')
        step += 1
    if test:
        lines.append(f'{step}. Full test suite: `{test}`')
        lines.append(f'   If ANY test fails (including pre-existing tests), fix it BEFORE marking done.')
        lines.append(f'   Zero regressions policy: your changes must not break existing tests.')
        step += 1
    if not tc and not test and not build:
        lines.append(f'{step}. Run any available project checks (build, lint, typecheck, test).')
        step += 1
    lines.append('')
    lines.append('If any check fails, fix the issue and re-run ALL checks before marking task complete.')

    if baseline_test_count > 0:
        lines.append('')
        lines.append(f'Baseline: {baseline_test_count} tests passing at dispatch time.')
        lines.append('Do NOT delete or skip existing tests — the quality gate detects test count regression.')

    return lines


def build_prompt(group: dict, spec_name: str, project_root: str, task_ids: list[str],
                 quality_commands: dict = None, baseline_test_count: int = 0) -> str:
    """Build the complete teammate prompt for a group."""
    lines = []

    name = group['name']
    tasks = group.get('taskDetails', [])
    owned_files = group.get('ownedFiles', [])
    has_multi_phases = group.get('hasMultiplePhases', False)
    phases = group.get('phases', [1])

    # Identity
    lines.append(f'You are the "{name}" teammate for the {spec_name} spec parallel execution.')
    lines.append('')

    # Task assignment
    lines.append('## Your Tasks')
    lines.append(f'You have {len(tasks)} individual TaskList tasks to complete. Claim each one via')
    lines.append('TaskUpdate (set owner to your name, status to in_progress) as you start it,')
    lines.append('and mark it completed when done.')
    lines.append('')
    lines.append(f'Your TaskList task IDs: {", ".join(task_ids)}')
    lines.append('')
    lines.append('Execute these spec tasks IN ORDER:')
    lines.append('')

    # Task blocks
    for i, task in enumerate(tasks):
        tid = task_ids[i] if i < len(task_ids) else f'#{i + 1}'
        lines.append(f'### Task {task["id"]}: {task["description"]} (TaskList {tid})')

        if task.get('files'):
            lines.append(f'- **Files**: {", ".join(f"`{f}`" for f in task["files"])}')

        if task.get('doSteps'):
            lines.append('- **Do**:')
            for step in task['doSteps']:
                lines.append(f'  {step}')

        if task.get('doneWhen'):
            lines.append(f'- **Done when**: {task["doneWhen"]}')

        if task.get('verify'):
            lines.append(f'- **Verify**: `{task["verify"]}`')

        if task.get('commit'):
            lines.append(f'- **Commit**: `{task["commit"]}` (remember to include Signed-off-by trailer)')

        # Phase 2 note
        if has_multi_phases and task.get('phase', 1) > min(phases):
            lines.append('')
            lines.append(f'> **NOTE**: Task {task["id"]} is Phase {task["phase"]}. After completing Phase {min(phases)} tasks, STOP and')
            lines.append(f'> message the lead: "Phase {min(phases)} {name} tasks complete, awaiting verify."')
            lines.append('> Wait for the lead to confirm before proceeding.')

        lines.append('')

    # File ownership
    lines.append('## File Ownership — STRICTLY ENFORCED')
    lines.append(f'You ONLY modify these files:')
    for f in owned_files:
        lines.append(f'- `{f}`')
    lines.append('')
    lines.append('You may read other files but NEVER write outside your ownership list.')
    lines.append('Before writing ANY file, verify it is in your ownership list above.')
    lines.append('If you need changes to a file you don\'t own, message the lead —')
    lines.append('do NOT make the change yourself. Ownership violations will be')
    lines.append('detected by the PreToolUse hook and blocked automatically.')
    lines.append('')

    # Quality Checks
    if quality_commands is None:
        quality_commands = {}
    lines.append('## Quality Checks')
    lines.extend(build_quality_section(quality_commands, baseline_test_count=baseline_test_count))
    lines.append('')

    # Rules
    lines.append('## Rules')
    lines.append(f'- For each task: implement → verify → commit → mark [x] in specs/{spec_name}/tasks.md')
    lines.append('- Claim each TaskList task as you start it, complete it when done')
    lines.append('- After ALL tasks done, message the lead:')
    lines.append(f'  "Group {name} complete. All {len(tasks)} tasks verified."')
    lines.append(f'- Working directory: {project_root}')
    lines.append('')

    # Commit Convention
    lines.append('## Commit Convention')
    lines.append('Every commit MUST include a git trailer for provenance tracking:')
    lines.append('')
    lines.append('```')
    lines.append(f'Signed-off-by: {name}')
    lines.append('```')
    lines.append('')
    lines.append('Example commit message:')
    lines.append('')
    lines.append('```')
    lines.append('feat(auth): add login endpoint')
    lines.append('')
    lines.append(f'Signed-off-by: {name}')
    lines.append('```')
    lines.append('')
    lines.append('Use `git commit -s` flag or manually append the trailer to every commit.')

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Build teammate prompt from partition JSON')
    parser.add_argument('--partition-file', help='Path to partition JSON (or read from stdin)')
    parser.add_argument('--group-index', type=int, required=True, help='Group index to build prompt for')
    parser.add_argument('--spec-name', required=True, help='Spec name')
    parser.add_argument('--project-root', required=True, help='Project root directory')
    parser.add_argument('--task-ids', required=True, help='Comma-separated TaskList IDs (e.g., "#1,#2,#3")')
    parser.add_argument('--quality-commands', default='{}', help='JSON of quality commands')
    parser.add_argument('--baseline-test-count', type=int, default=0, help='Baseline test count from dispatch snapshot')
    args = parser.parse_args()

    # Read partition JSON
    if args.partition_file:
        with open(args.partition_file) as f:
            partition = json.load(f)
    else:
        partition = json.load(sys.stdin)

    # Find the group
    group = None
    for g in partition['groups']:
        if g['index'] == args.group_index:
            group = g
            break

    if group is None:
        print(f"Error: Group index {args.group_index} not found", file=sys.stderr)
        sys.exit(1)

    task_ids = [t.strip() for t in args.task_ids.split(',')]
    quality_commands = json.loads(args.quality_commands)

    prompt = build_prompt(group, args.spec_name, args.project_root, task_ids,
                          quality_commands=quality_commands,
                          baseline_test_count=args.baseline_test_count)
    print(prompt)


if __name__ == '__main__':
    main()
