# Tasks: Parallel QA Overhaul

## Phase 1: Make It Work (POC)

Focus: Get quality command discovery, teammate prompt enhancement, and enhanced per-task gate working end-to-end. Skip edge cases, accept rough error messages.

- [ ] 1.1 [P] Add `discover_quality_commands()` to parse-and-partition.py
  - **Do**:
    1. Add `import tomllib` (Python 3.11+) at top of file; fallback `import tomli as tomllib` with try/except
    2. Add function `discover_quality_commands(project_root: str) -> dict` after the `extract_field()` function
    3. Detection logic per ecosystem (check files in order, first match wins for each slot):
       - `package.json`: read scripts object. Map: typecheck=scripts.typecheck or scripts["check-types"], build=scripts.build, test=scripts.test, lint=scripts.lint, dev=scripts.dev or scripts.start. For bare single-word values (no spaces, no &&), prefix with `npx `. For complex values (contains space or &&), use as-is.
       - `pyproject.toml`: if `[tool.pytest]` or `[tool.pytest.ini_options]` exists, test="pytest". If "ruff" in `[project.optional-dependencies]` or `[tool.ruff]` exists, lint="ruff check .". build=null. typecheck: if "mypy" in deps, typecheck="mypy ."; if "pyright", typecheck="pyright".
       - `Makefile`: scan for targets named `test`, `build`, `lint`, `check`, `typecheck`. Map target name to `make $target`.
       - `Cargo.toml`: if exists, build="cargo build", test="cargo test", lint="cargo clippy" (if clippy section exists or unconditionally).
    4. Return dict: `{"typecheck": str|None, "build": str|None, "test": str|None, "lint": str|None, "dev": str|None}`
    5. Wrap each file read in try/except (FileNotFoundError, json.JSONDecodeError, KeyError) -- return null for that slot on error
    6. In `main()`, after reading tasks.md, infer project root from `--tasks-md` path (walk up 2 dirs from `specs/$name/tasks.md`). Call `discover_quality_commands(project_root)`.
    7. Add `qualityCommands` key to the result dict in `_format_result()` -- pass it through from main.
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Running the script against gpu-metrics-operator/specs produces JSON with `qualityCommands.typecheck == "npx tsc --noEmit"` and `qualityCommands.build == "npx vite build"`
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md | python3 -c "import sys,json; d=json.load(sys.stdin); qc=d['qualityCommands']; assert qc['typecheck']=='npx tsc --noEmit', f'got {qc[\"typecheck\"]}'; assert qc['build']=='npx vite build', f'got {qc[\"build\"]}'; print('PASS: qualityCommands discovered correctly')"`
  - **Commit**: `feat(parallel): add quality command discovery to parse-and-partition.py`
  - _Requirements: FR-1, AC-1.1, AC-1.2, AC-1.3, AC-1.4, AC-1.5_
  - _Design: Component 1 (Quality Command Discovery)_

- [ ] 1.2 [P] Add `classify_verify_commands()` and warning output
  - **Do**:
    1. Add constants at module level:
       ```
       WEAK_PATTERNS = ['grep', 'ls ', 'cat ', 'echo ', 'true', 'test -f', 'wc ']
       STATIC_PATTERNS = ['tsc', 'typecheck', 'lint', 'eslint', 'prettier', 'mypy', 'pyright', 'clippy', 'ruff']
       RUNTIME_PATTERNS = ['build', 'vite', 'webpack', 'test', 'vitest', 'jest', 'pytest', 'cargo test', 'curl', 'serve', 'node ', 'python3 ']
       ```
    2. Add function `classify_verify_commands(tasks: list[dict]) -> dict` after discover_quality_commands
    3. For each task, check task['verify'] against pattern lists (runtime first, then static, then weak). Empty verify = "none".
    4. Return: `{"runtime": N, "static": N, "weak": N, "none": N, "details": [{"taskId": "1.1", "tier": "weak", "command": "grep ..."}]}`
    5. Add `verifyQuality` key to partition output (from _format_result)
    6. In `format_plan()`, after existing output, if weak/(total) > 0.5, append:
       `WARNING: N/M tasks have weak verify commands (grep/ls/cat).\nConsider adding build/test verify commands to tasks.md before dispatch.`
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Running `--format` against gpu-metrics-operator tasks shows the WARNING line (since >50% are grep-based)
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md --format 2>&1 | grep -q 'WARNING:' && echo 'PASS: weak verify warning present' || echo 'FAIL: no warning found'`
  - **Commit**: `feat(parallel): classify verify commands and warn on weak verification`
  - _Requirements: FR-12, FR-13, AC-6.1, AC-6.2, AC-6.3, AC-6.4, AC-6.5_
  - _Design: Component 2 (Verify Command Classification)_

- [ ] 1.3 [VERIFY] Quality checkpoint: python3 parse-and-partition.py runs without errors
  - **Do**: Run parse-and-partition.py with both JSON and --format output modes against gpu-metrics-operator tasks.md. Verify JSON is valid and contains both new keys.
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'qualityCommands' in d; assert 'verifyQuality' in d; print('PASS: both keys present')" && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md --format >/dev/null 2>&1 && echo 'PASS: format mode works'`
  - **Done when**: Both output modes work, JSON contains qualityCommands and verifyQuality
  - **Commit**: `chore(parallel): pass quality checkpoint` (only if fixes needed)

- [ ] 1.4 [P] Add `--quality-commands` arg and Quality Checks section to build-teammate-prompt.py
  - **Do**:
    1. Add `--quality-commands` argument to argparse: `parser.add_argument('--quality-commands', default='{}', help='JSON of quality commands')`
    2. In `main()`, parse it: `quality_commands = json.loads(args.quality_commands)`
    3. Pass `quality_commands` to `build_prompt()` as new parameter
    4. Add function `build_quality_section(quality_commands: dict) -> list[str]`
    5. Section content rules:
       - If typecheck exists: `"- After EACH task, run typecheck: \`{cmd}\`\n  If it fails, fix errors BEFORE marking the task complete."`
       - If test exists: `"- Write at least one test per implementation task. Run tests: \`{cmd}\`"`
       - If build exists (and no test): `"- Verify your code builds: \`{cmd}\`"`
       - Always: `"- If typecheck/build fails after your changes, fix BEFORE marking task complete"`
       - If no commands at all: `"- Run any available project checks (build, lint, typecheck) after each task."`
    6. In `build_prompt()`, insert the section between "File Ownership" and "Rules" sections:
       ```
       lines.append('')
       lines.append('## Quality Checks')
       lines.extend(build_quality_section(quality_commands))
       lines.append('')
       ```
  - **Files**: `ralph-parallel/scripts/build-teammate-prompt.py`
  - **Done when**: Running the script with --quality-commands produces prompt containing "Quality Checks" section with typecheck instruction
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md > /tmp/qa-test-partition.json && python3 ralph-parallel/scripts/build-teammate-prompt.py --partition-file /tmp/qa-test-partition.json --group-index 0 --spec-name gpu-metrics-operator --project-root /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator --task-ids "#1,#2,#3" --quality-commands '{"typecheck":"npx tsc --noEmit","build":"npx vite build"}' | grep -q 'Quality Checks' && echo 'PASS: Quality Checks section present' || echo 'FAIL: section missing'`
  - **Commit**: `feat(parallel): add quality commands to teammate prompt builder`
  - _Requirements: FR-3, FR-4, AC-2.1, AC-2.2, AC-2.3, AC-2.4, AC-2.5, AC-2.6_
  - _Design: Component 5 (Teammate Prompt Enhancement)_

- [ ] 1.5 [P] Capture verify output on failure in task-completed-gate.sh
  - **Do**:
    1. Replace the verify execution block (lines 118-127) with output-capturing version:
       ```bash
       VERIFY_OUTPUT=$(eval "$VERIFY_CMD" 2>&1)
       VERIFY_EXIT=$?
       if [ $VERIFY_EXIT -eq 0 ]; then
         exit 0
       else
         echo "QUALITY GATE FAILED for task $COMPLETED_SPEC_TASK ($TASK_SUBJECT)" >&2
         echo "Verify command failed (exit $VERIFY_EXIT): $VERIFY_CMD" >&2
         echo "--- Output (last 50 lines) ---" >&2
         echo "$VERIFY_OUTPUT" | tail -50 >&2
         echo "Fix the issues and mark the task complete again." >&2
         exit 2
       fi
       ```
    2. Remove the old `eval "$VERIFY_CMD" >/dev/null 2>&1` line
    3. Keep the pre-verify echo line: `echo "ralph-parallel: Verifying task $COMPLETED_SPEC_TASK: $VERIFY_CMD" >&2`
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: A failing verify command shows actual error output in stderr instead of the generic message
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && echo '{"task_id":"1","task_subject":"1.99 Test fail","team_name":"gpu-metrics-operator-parallel","cwd":"/Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator"}' | bash ralph-parallel/hooks/scripts/task-completed-gate.sh 2>&1; echo "exit=$?"`
  - **Commit**: `fix(parallel): capture and display verify command output on failure`
  - _Requirements: FR-8, AC-4.1, AC-4.2, AC-4.3, AC-4.4_
  - _Design: Component 6, Stage 1_

- [ ] 1.6 [P] Add supplemental typecheck and file existence stages to gate
  - **Do**:
    1. After the verify command block (now with output capture), add Stage 2 - Supplemental typecheck:
       ```bash
       # --- Stage 2: Supplemental typecheck ---
       DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"
       TYPECHECK_CMD=$(jq -r '.qualityCommands.typecheck // empty' "$DISPATCH_STATE" 2>/dev/null)

       if [ -n "$TYPECHECK_CMD" ]; then
         echo "ralph-parallel: Running supplemental typecheck: $TYPECHECK_CMD" >&2
         TC_OUTPUT=$(eval "$TYPECHECK_CMD" 2>&1)
         TC_EXIT=$?
         if [ $TC_EXIT -ne 0 ]; then
           echo "SUPPLEMENTAL CHECK FAILED: typecheck" >&2
           echo "Command: $TYPECHECK_CMD (exit $TC_EXIT)" >&2
           echo "--- Output (last 30 lines) ---" >&2
           echo "$TC_OUTPUT" | tail -30 >&2
           echo "Fix type errors before marking task complete." >&2
           exit 2
         fi
       fi
       ```
    2. Add Stage 3 - File existence check:
       ```bash
       # --- Stage 3: File existence check ---
       TASK_FILES=""
       IN_TASK=false
       while IFS= read -r fline; do
         if echo "$fline" | grep -qE "^\s*- \[.\] ${COMPLETED_SPEC_TASK}\b"; then
           IN_TASK=true; continue
         fi
         if [ "$IN_TASK" = true ] && echo "$fline" | grep -qE "^\s*- \[.\] [0-9]"; then break; fi
         if [ "$IN_TASK" = true ] && echo "$fline" | grep -qE "\*\*Files\*\*:"; then
           TASK_FILES=$(echo "$fline" | sed 's/.*\*\*Files\*\*:\s*//' | sed 's/`//g')
           break
         fi
       done < "$SPEC_DIR/tasks.md"

       if [ -n "$TASK_FILES" ]; then
         MISSING=""
         IFS=',' read -ra FILE_LIST <<< "$TASK_FILES"
         for f in "${FILE_LIST[@]}"; do
           f=$(echo "$f" | xargs)  # trim whitespace
           [ -z "$f" ] && continue
           if [ ! -e "$PROJECT_ROOT/$f" ]; then
             MISSING="$MISSING $f"
           fi
         done
         if [ -n "$MISSING" ]; then
           echo "SUPPLEMENTAL CHECK FAILED: file existence" >&2
           echo "Missing files:$MISSING" >&2
           echo "Create the missing files before marking task complete." >&2
           exit 2
         fi
       fi
       ```
    3. Remove the early `exit 0` after verify success (it now needs to fall through to supplemental checks)
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Gate runs verify -> typecheck -> file check in sequence; missing qualityCommands in dispatch state skips typecheck gracefully
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && echo '{"task_id":"1","task_subject":"1.1 Scaffold project","team_name":"gpu-metrics-operator-parallel","cwd":"/Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator"}' | bash ralph-parallel/hooks/scripts/task-completed-gate.sh 2>&1; EXIT=$?; echo "exit=$EXIT"; [ $EXIT -eq 0 ] && echo 'PASS: gate allows completed task through' || echo "FAIL: gate blocked with exit $EXIT"`
  - **Commit**: `feat(parallel): add supplemental typecheck and file existence gate stages`
  - _Requirements: FR-5, FR-6, AC-3.1, AC-3.2, AC-3.3, AC-3.5, AC-3.6_
  - _Design: Component 6, Stages 2-3_

- [ ] 1.7 [P] Add periodic build check stage to gate
  - **Do**:
    1. After file existence check, add Stage 4 - Periodic build:
       ```bash
       # --- Stage 4: Periodic build check ---
       BUILD_CMD=$(jq -r '.qualityCommands.build // empty' "$DISPATCH_STATE" 2>/dev/null)
       BUILD_INTERVAL=${BUILD_INTERVAL:-3}

       if [ -n "$BUILD_CMD" ]; then
         # Count completed tasks (marked [x]) in tasks.md
         COMPLETED_COUNT=$(grep -cE '^\s*- \[x\]' "$SPEC_DIR/tasks.md" 2>/dev/null || echo 0)

         if [ $((COMPLETED_COUNT % BUILD_INTERVAL)) -eq 0 ] || [ "$COMPLETED_COUNT" -le 1 ]; then
           echo "ralph-parallel: Running periodic build check ($COMPLETED_COUNT tasks done): $BUILD_CMD" >&2
           BUILD_OUTPUT=$(eval "$BUILD_CMD" 2>&1)
           BUILD_EXIT=$?
           if [ $BUILD_EXIT -ne 0 ]; then
             echo "SUPPLEMENTAL CHECK FAILED: build (periodic, every ${BUILD_INTERVAL} tasks)" >&2
             echo "Command: $BUILD_CMD (exit $BUILD_EXIT)" >&2
             echo "--- Output (last 50 lines) ---" >&2
             echo "$BUILD_OUTPUT" | tail -50 >&2
             echo "Fix build errors before marking task complete." >&2
             exit 2
           fi
         fi
       fi

       # All stages passed
       exit 0
       ```
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Build check runs every 3rd completed task; skips gracefully when no build command
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && echo '{"task_id":"1","task_subject":"1.1 Scaffold project","team_name":"gpu-metrics-operator-parallel","cwd":"/Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator"}' | bash ralph-parallel/hooks/scripts/task-completed-gate.sh 2>&1; EXIT=$?; echo "exit=$EXIT"; [ $EXIT -eq 0 ] && echo 'PASS: gate passes all stages' || echo "FAIL: exit $EXIT"`
  - **Commit**: `feat(parallel): add periodic build check to per-task gate`
  - _Requirements: FR-7, AC-3.4_
  - _Design: Component 6, Stage 4_

- [ ] 1.8 [P] Increase TaskCompleted hook timeout to 300s
  - **Do**:
    1. In `hooks/hooks.json`, change `"timeout": 120` to `"timeout": 300` in the TaskCompleted section
  - **Files**: `ralph-parallel/hooks/hooks.json`
  - **Done when**: hooks.json has timeout 300 for TaskCompleted
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -c "import json; h=json.load(open('ralph-parallel/hooks/hooks.json')); tc=h['hooks']['TaskCompleted'][0]['hooks'][0]; assert tc['timeout']==300, f'got {tc[\"timeout\"]}'; print('PASS: timeout is 300')"`
  - **Commit**: `feat(parallel): increase task-completed gate timeout to 300s for build checks`
  - _Requirements: FR-14, AC-3.7_
  - _Design: Component 9 (Hook Timeout)_

- [ ] 1.9 [VERIFY] Quality checkpoint: all scripts run, gate works end-to-end
  - **Do**: Run parse-and-partition.py, build-teammate-prompt.py, and task-completed-gate.sh in sequence to verify the full pipeline works
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'qualityCommands' in d and 'verifyQuality' in d; print('PASS: partition JSON ok')" && python3 ralph-parallel/scripts/build-teammate-prompt.py --partition-file /tmp/qa-test-partition.json --group-index 0 --spec-name test --project-root /tmp --task-ids "#1" --quality-commands '{"typecheck":"echo ok"}' | grep -q 'Quality Checks' && echo 'PASS: prompt ok' && echo 'All scripts pass'`
  - **Done when**: All three scripts execute without errors, output is well-formed
  - **Commit**: `chore(parallel): pass quality checkpoint` (only if fixes needed)

- [ ] 1.10 [P] Wire quality commands into dispatch.md Step 4 and Step 6
  - **Do**:
    1. In dispatch.md Step 4 (Write Dispatch State), add `qualityCommands` to the JSON structure written:
       ```text
       2. Write dispatch state from the partition JSON:
          {
            "dispatchedAt": "<ISO timestamp>",
            "strategy": "$strategy",
            "maxTeammates": $maxTeammates,
            "groups": <from partition JSON>,
            "serialTasks": <from partition JSON>,
            "verifyTasks": <from partition JSON>,
            "qualityCommands": <from partition JSON>,
            "status": "dispatched",
            "completedGroups": []
          }
       ```
    2. In dispatch.md Step 6 (Spawn Teammates), update the build-teammate-prompt.py invocation to include `--quality-commands`:
       ```bash
       python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build-teammate-prompt.py \
         --partition-file /tmp/$specName-partition.json \
         --group-index $i \
         --spec-name $specName \
         --project-root $projectRoot \
         --task-ids "#$id1,#$id2,..." \
         --quality-commands "$QUALITY_COMMANDS_JSON"
       ```
    3. Add a note between Step 2 and Step 6 explaining that `QUALITY_COMMANDS_JSON` comes from the partition JSON's `qualityCommands` field (extracted as JSON string via jq).
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: dispatch.md references qualityCommands in state and passes --quality-commands to prompt builder
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && grep -q 'qualityCommands' ralph-parallel/commands/dispatch.md && grep -q '\-\-quality-commands' ralph-parallel/commands/dispatch.md && echo 'PASS: dispatch.md updated' || echo 'FAIL'`
  - **Commit**: `feat(parallel): wire quality commands through dispatch pipeline`
  - _Requirements: FR-2, AC-1.3_
  - _Design: Component 7 (Dispatch Lead Coordination), Steps 4 and 6_

- [ ] 1.11 [P] Add merge checkpoint runtime verification to dispatch.md Step 7
  - **Do**:
    1. Replace the current Step 7 item 4 (PHASE GATE) with enhanced version:
       ```text
       4. PHASE GATE: When ALL Phase N tasks done:
          a. Run Phase N verify checkpoint task
          b. Read qualityCommands from .dispatch-state.json
          c. Run full build: execute qualityCommands.build (if available)
          d. Run test suite: execute qualityCommands.test (if available)
          e. Runtime smoke test (best-effort): if qualityCommands.dev exists:
             - Start dev server in background
             - Wait 5s for startup
             - curl -sf http://localhost:5173 >/dev/null (or parse port from command)
             - Kill dev server background process
             - If curl fails: WARN but do NOT block (dev server check is best-effort)
          f. If build/test FAIL: message affected teammates with error output
             Do NOT mark phase complete. Teammates must fix.
          g. If all pass: mark verify task completed, proceed to next phase
       ```
  - **Files**: `ralph-parallel/commands/dispatch.md`
  - **Done when**: Step 7 PHASE GATE includes build, test, and dev server smoke test steps
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && grep -q 'qualityCommands.build' ralph-parallel/commands/dispatch.md && grep -q 'qualityCommands.test' ralph-parallel/commands/dispatch.md && grep -q 'smoke test' ralph-parallel/commands/dispatch.md && echo 'PASS: merge checkpoint updated' || echo 'FAIL'`
  - **Commit**: `feat(parallel): add runtime verification to dispatch phase gate`
  - _Requirements: FR-9, FR-10, FR-11, AC-5.1, AC-5.2, AC-5.3, AC-5.4_
  - _Design: Component 7, Step 7 PHASE GATE_

- [ ] 1.12 [P] Update merge.md Step 3 to use build/test instead of grep verifies
  - **Do**:
    1. Replace Step 3's current "CHECK: All verify commands pass" section with:
       ```text
       3. CHECK: Build verification
          a. Read qualityCommands from .dispatch-state.json
          b. Run qualityCommands.build (if available)
          c. Run qualityCommands.test (if available)
          d. Run qualityCommands.lint (if available)
          e. Collect pass/fail per command
          f. If ANY fail: report specific failures with output, do NOT mark as merged
       ```
    2. Keep the file ownership verification (Step 3 item 1) and working tree check (item 2) as-is
  - **Files**: `ralph-parallel/commands/merge.md`
  - **Done when**: merge.md Step 3 runs build/test/lint instead of re-running grep verify commands
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && grep -q 'qualityCommands.build' ralph-parallel/commands/merge.md && grep -q 'qualityCommands.test' ralph-parallel/commands/merge.md && echo 'PASS: merge.md updated' || echo 'FAIL'`
  - **Commit**: `feat(parallel): replace grep verification with build/test in merge checkpoint`
  - _Requirements: FR-9, AC-5.5_
  - _Design: Component 8 (Merge Verification Update)_

- [ ] 1.13 [P] Sync plugin to cache
  - **Do**:
    1. Run: `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.1.0/`
    2. Verify the cache has the updated files
  - **Files**: (no source edits -- deployment step)
  - **Done when**: Cache directory contains all modified files
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.1.0/ >/dev/null && diff ralph-parallel/hooks/hooks.json ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.1.0/hooks/hooks.json && echo 'PASS: cache in sync' || echo 'FAIL: cache out of sync'`
  - **Commit**: (no commit -- cache sync only)

- [ ] 1.14 POC Checkpoint: Full pipeline end-to-end test
  - **Do**:
    1. Create a minimal test tasks.md in /tmp with 4 tasks (2 weak verify, 1 static, 1 runtime)
    2. Run parse-and-partition.py against it and verify JSON output has qualityCommands and verifyQuality
    3. Run build-teammate-prompt.py with quality commands and verify "Quality Checks" section
    4. Simulate gate invocation with and without .dispatch-state.json qualityCommands to verify backward compat
    5. Verify format_plan warning appears for tasks with >50% weak verify
    6. Verify all exit codes are correct (0 for pass, 2 for block)
  - **Files**: (no source edits -- validation step)
  - **Done when**: All 6 checks pass -- pipeline works end-to-end
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -c "
import subprocess, json, sys, tempfile, os

# Test 1: partition JSON has new keys
r = subprocess.run(['python3', 'ralph-parallel/scripts/parse-and-partition.py', '--tasks-md', 'specs/gpu-metrics-operator/tasks.md'], capture_output=True, text=True)
assert r.returncode == 0, f'partition failed: {r.stderr}'
d = json.loads(r.stdout)
assert 'qualityCommands' in d, 'missing qualityCommands'
assert 'verifyQuality' in d, 'missing verifyQuality'
assert d['qualityCommands']['typecheck'] is not None, 'typecheck should be discovered'
print('Test 1 PASS: partition JSON correct')

# Test 2: format mode shows warning
r2 = subprocess.run(['python3', 'ralph-parallel/scripts/parse-and-partition.py', '--tasks-md', 'specs/gpu-metrics-operator/tasks.md', '--format'], capture_output=True, text=True)
assert 'WARNING' in r2.stdout or 'WARNING' in r2.stderr, 'no warning for weak verifies'
print('Test 2 PASS: weak verify warning present')

# Test 3: prompt builder quality section
r3 = subprocess.run(['python3', 'ralph-parallel/scripts/build-teammate-prompt.py', '--partition-file', '/tmp/qa-test-partition.json', '--group-index', '0', '--spec-name', 'test', '--project-root', '/tmp', '--task-ids', '#1,#2', '--quality-commands', json.dumps(d['qualityCommands'])], capture_output=True, text=True)
assert 'Quality Checks' in r3.stdout, 'no Quality Checks section'
print('Test 3 PASS: prompt includes Quality Checks')

# Test 4: hooks.json timeout
h = json.load(open('ralph-parallel/hooks/hooks.json'))
assert h['hooks']['TaskCompleted'][0]['hooks'][0]['timeout'] == 300
print('Test 4 PASS: hook timeout is 300')

print('ALL POC TESTS PASS')
"`
  - **Commit**: `feat(parallel): complete QA overhaul POC`

## Phase 2: Refactoring

After POC validated, clean up code structure and error handling.

- [ ] 2.1 Extract quality command discovery into robust handler functions
  - **Do**:
    1. In parse-and-partition.py, refactor `discover_quality_commands()` to call per-ecosystem helper functions: `_discover_node(root)`, `_discover_python(root)`, `_discover_makefile(root)`, `_discover_rust(root)`
    2. Each helper returns a partial dict (only slots it can fill). Main function merges, first non-null wins per slot.
    3. Add proper error handling with stderr warnings for each malformed config file
    4. Ensure the `npx` prefix logic only applies when the package.json script value is a single token (no spaces, pipes, or &&)
  - **Files**: `ralph-parallel/scripts/parse-and-partition.py`
  - **Done when**: Discovery is modular, each ecosystem handler is independently testable
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md | python3 -c "import sys,json; d=json.load(sys.stdin); qc=d['qualityCommands']; assert qc['typecheck']=='npx tsc --noEmit'; assert qc['build']=='npx vite build'; print('PASS: refactored discovery works')"`
  - **Commit**: `refactor(parallel): extract per-ecosystem quality command discovery`
  - _Design: Component 1_

- [ ] 2.2 Clean up gate script structure and add function documentation
  - **Do**:
    1. In task-completed-gate.sh, extract each stage into a shell function: `run_verify()`, `run_typecheck()`, `check_file_existence()`, `run_periodic_build()`
    2. Main flow calls each function in sequence
    3. Add header comments documenting the 4-stage pipeline
    4. Standardize error output format: `"QUALITY GATE FAILED: {stage}\nCommand: {cmd} (exit {code})\n--- Output (last N lines) ---\n{output}"`
    5. Add backward compatibility note: "If .dispatch-state.json has no qualityCommands, stages 2-4 are skipped"
  - **Files**: `ralph-parallel/hooks/scripts/task-completed-gate.sh`
  - **Done when**: Gate is structured as 4 named functions with consistent error format
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && echo 'PASS: shell syntax valid' && grep -c 'function\|run_verify\|run_typecheck\|check_file_existence\|run_periodic_build' ralph-parallel/hooks/scripts/task-completed-gate.sh | python3 -c "import sys; n=int(sys.stdin.read()); assert n >= 4, f'only {n} function refs'; print('PASS: functions extracted')"`
  - **Commit**: `refactor(parallel): extract gate stages into named functions`
  - _Design: Component 6_

- [ ] 2.3 [VERIFY] Quality checkpoint: all scripts still work after refactor
  - **Do**: Re-run the POC checkpoint tests to verify refactoring didn't break anything
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'qualityCommands' in d; assert 'verifyQuality' in d; print('PASS')" && bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh && echo 'PASS: gate syntax ok'`
  - **Done when**: All scripts run correctly after refactoring
  - **Commit**: `chore(parallel): pass quality checkpoint` (only if fixes needed)

## Phase 3: Testing

- [ ] 3.1 Unit tests for quality command discovery
  - **Do**:
    1. Create `ralph-parallel/scripts/test_parse_and_partition.py`
    2. Tests:
       - `test_discover_node_project`: Create temp dir with package.json containing typecheck/build/test scripts. Assert correct discovery.
       - `test_discover_node_bare_commands`: package.json with `"test": "vitest"` gets `npx vitest`. With `"test": "vitest run && playwright"` stays as-is.
       - `test_discover_python_project`: Create temp dir with pyproject.toml containing pytest config. Assert test="pytest".
       - `test_discover_rust_project`: Create temp dir with Cargo.toml. Assert build="cargo build", test="cargo test".
       - `test_discover_makefile`: Create temp dir with Makefile containing `test:` and `build:` targets. Assert correct make commands.
       - `test_discover_no_config`: Empty temp dir. Assert all nulls.
       - `test_discover_malformed_json`: Broken package.json. Assert no crash, returns nulls.
       - `test_classify_weak`: Tasks with grep verify -> weak tier.
       - `test_classify_static`: Tasks with tsc verify -> static tier.
       - `test_classify_runtime`: Tasks with build verify -> runtime tier.
       - `test_classify_mixed`: Mix of tiers, correct counts.
       - `test_warning_threshold`: >50% weak triggers warning in format_plan output.
    3. Use pytest with `tmp_path` fixture for temp directories
  - **Files**: `ralph-parallel/scripts/test_parse_and_partition.py`
  - **Done when**: All 12 tests pass
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/test_parse_and_partition.py -v 2>&1 | tail -20`
  - **Commit**: `test(parallel): add unit tests for quality command discovery and classification`
  - _Requirements: AC-1.1 through AC-1.5, AC-6.1 through AC-6.5_
  - _Design: Test Strategy_

- [ ] 3.2 Unit tests for teammate prompt quality section
  - **Do**:
    1. Create `ralph-parallel/scripts/test_build_teammate_prompt.py`
    2. Tests:
       - `test_quality_section_with_typecheck`: Pass typecheck command, verify "After EACH task, run typecheck" in output
       - `test_quality_section_with_test_runner`: Pass test command, verify "Write at least one test" in output
       - `test_quality_section_with_build_only`: Pass only build command (no test), verify "Verify your code builds" in output
       - `test_quality_section_no_commands`: Pass empty dict, verify generic guidance text
       - `test_quality_commands_cli_arg`: Run script with --quality-commands JSON arg, verify parsed correctly
       - `test_quality_section_ordering`: Verify Quality Checks section appears between File Ownership and Rules
    3. Import functions directly from build_teammate_prompt module
  - **Files**: `ralph-parallel/scripts/test_build_teammate_prompt.py`
  - **Done when**: All 6 tests pass
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/test_build_teammate_prompt.py -v 2>&1 | tail -15`
  - **Commit**: `test(parallel): add unit tests for teammate prompt quality section`
  - _Requirements: AC-2.1 through AC-2.6_
  - _Design: Test Strategy_

- [ ] 3.3 Integration tests for task-completed-gate.sh
  - **Do**:
    1. Create `ralph-parallel/hooks/scripts/test_gate.sh`
    2. Tests (each is a function that sets up a temp dir, runs gate via echo | bash, checks exit code):
       - `test_gate_verify_output_on_failure`: Create tasks.md with verify "false". Send stdin JSON. Assert exit 2 and stderr contains "QUALITY GATE FAILED".
       - `test_gate_verify_success_no_noise`: Create tasks.md with verify "true". Assert exit 0 and minimal stderr.
       - `test_gate_supplemental_typecheck`: Create .dispatch-state.json with qualityCommands.typecheck="echo typecheckok". Assert exit 0.
       - `test_gate_typecheck_failure`: Create .dispatch-state.json with qualityCommands.typecheck="false". Assert exit 2.
       - `test_gate_file_existence_pass`: Tasks.md Files field lists existing files. Assert exit 0.
       - `test_gate_file_existence_fail`: Tasks.md Files field lists nonexistent file. Assert exit 2 and stderr contains "Missing files".
       - `test_gate_backward_compat`: No .dispatch-state.json. Assert exit 0 (verify only).
    3. Use a test runner function that tracks pass/fail counts
  - **Files**: `ralph-parallel/hooks/scripts/test_gate.sh`
  - **Done when**: All 7 tests pass
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && bash ralph-parallel/hooks/scripts/test_gate.sh 2>&1 | tail -10`
  - **Commit**: `test(parallel): add integration tests for enhanced task-completed gate`
  - _Requirements: AC-3.1 through AC-3.6, AC-4.1 through AC-4.4_
  - _Design: Test Strategy_

- [ ] 3.4 [VERIFY] Quality checkpoint: all tests pass
  - **Do**: Run all test suites created in this phase
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -m pytest ralph-parallel/scripts/test_parse_and_partition.py ralph-parallel/scripts/test_build_teammate_prompt.py -v 2>&1 | tail -5 && bash ralph-parallel/hooks/scripts/test_gate.sh 2>&1 | tail -5`
  - **Done when**: All unit and integration tests pass
  - **Commit**: `chore(parallel): pass quality checkpoint` (only if fixes needed)

## Phase 4: Quality Gates

- [ ] 4.1 Local quality check: all scripts + tests pass
  - **Do**: Run ALL quality checks locally
  - **Verify**: All commands must pass:
    - Script syntax: `python3 -m py_compile ralph-parallel/scripts/parse-and-partition.py && python3 -m py_compile ralph-parallel/scripts/build-teammate-prompt.py`
    - Shell syntax: `bash -n ralph-parallel/hooks/scripts/task-completed-gate.sh`
    - JSON validity: `python3 -c "import json; json.load(open('ralph-parallel/hooks/hooks.json'))"`
    - Unit tests: `python3 -m pytest ralph-parallel/scripts/test_parse_and_partition.py ralph-parallel/scripts/test_build_teammate_prompt.py -v`
    - Integration tests: `bash ralph-parallel/hooks/scripts/test_gate.sh`
    - E2E: `python3 ralph-parallel/scripts/parse-and-partition.py --tasks-md specs/gpu-metrics-operator/tasks.md | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'qualityCommands' in d and 'verifyQuality' in d; print('OK')"`
  - **Done when**: All commands pass with no errors
  - **Commit**: `fix(parallel): address quality issues` (if fixes needed)

- [ ] 4.2 Final cache sync and verification
  - **Do**:
    1. Sync: `rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.1.0/`
    2. Verify cache matches source
  - **Files**: (deployment)
  - **Done when**: Cache is in sync
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && rsync -av --delete ralph-parallel/ ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.1.0/ >/dev/null && diff <(find ralph-parallel -type f -name '*.py' -o -name '*.sh' -o -name '*.json' -o -name '*.md' | sort | xargs md5 2>/dev/null) <(find ~/.claude/plugins/cache/ralph-parallel-local/ralph-parallel/0.1.0 -type f -name '*.py' -o -name '*.sh' -o -name '*.json' -o -name '*.md' | sort | xargs md5 2>/dev/null) && echo 'PASS: cache in sync' || echo 'WARN: cache diff detected (expected for path differences)'`
  - **Commit**: (no commit -- deployment step)

- [ ] 4.3 Create PR and verify CI
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Push branch: `git push -u origin <branch-name>`
    4. Create PR: `gh pr create --title "feat(parallel): overhaul QA pipeline with runtime verification" --body "..."`
    5. Verify CI: `gh pr checks --watch`
  - **Verify**: `gh pr checks` shows all green
  - **Done when**: All CI checks green, PR ready for review
  - **Commit**: (no commit -- PR creation)

## Phase 5: PR Lifecycle

- [ ] 5.1 Monitor CI and fix failures
  - **Do**:
    1. Check CI status: `gh pr checks`
    2. If failures: read failure details, fix locally, push fixes
    3. Re-verify: `gh pr checks --watch`
  - **Verify**: `gh pr checks` all passing
  - **Done when**: CI green

- [ ] 5.2 Address review comments
  - **Do**:
    1. Check for review comments: `gh pr view --comments`
    2. Address each comment
    3. Push fixes
  - **Verify**: No unresolved review comments
  - **Done when**: All review comments addressed

- [ ] 5.3 [VERIFY] Final verification: all ACs met
  - **Do**: Read requirements.md, verify each AC is satisfied by checking code and running tests:
    - AC-1.x: Run parse-and-partition.py, check qualityCommands in JSON output
    - AC-2.x: Run build-teammate-prompt.py with --quality-commands, check "Quality Checks" section
    - AC-3.x: Run gate with .dispatch-state.json containing qualityCommands, check supplemental stages run
    - AC-4.x: Run gate with failing verify, check stderr shows actual error output
    - AC-5.x: Check dispatch.md and merge.md contain build/test verification steps
    - AC-6.x: Run partition with weak-heavy tasks.md, check WARNING output
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph && python3 -c "
# AC-1: Quality command discovery
import subprocess, json
r = subprocess.run(['python3', 'ralph-parallel/scripts/parse-and-partition.py', '--tasks-md', 'specs/gpu-metrics-operator/tasks.md'], capture_output=True, text=True)
d = json.loads(r.stdout)
assert d['qualityCommands']['typecheck'] is not None, 'AC-1.1 FAIL'
assert d['qualityCommands']['build'] is not None, 'AC-1.2 FAIL'
print('AC-1: PASS')

# AC-6: Verify quality classification
assert 'verifyQuality' in d, 'AC-6.2 FAIL'
assert d['verifyQuality']['weak'] > 0, 'AC-6.1 FAIL'
print('AC-6: PASS')

# AC-2: Prompt quality section
r2 = subprocess.run(['python3', 'ralph-parallel/scripts/build-teammate-prompt.py', '--partition-file', '/tmp/qa-test-partition.json', '--group-index', '0', '--spec-name', 'test', '--project-root', '/tmp', '--task-ids', '#1', '--quality-commands', json.dumps(d['qualityCommands'])], capture_output=True, text=True)
assert 'Quality Checks' in r2.stdout, 'AC-2.1 FAIL'
assert 'typecheck' in r2.stdout.lower(), 'AC-2.2 FAIL'
print('AC-2: PASS')

# AC-3.7: Hook timeout
h = json.load(open('ralph-parallel/hooks/hooks.json'))
assert h['hooks']['TaskCompleted'][0]['hooks'][0]['timeout'] == 300, 'AC-3.7 FAIL'
print('AC-3.7: PASS')

print('ALL ACCEPTANCE CRITERIA VERIFIED')
"`
  - **Done when**: All acceptance criteria confirmed met
  - **Commit**: None

## Notes

- **POC shortcuts taken**: Package.json npx prefix logic is simplified (single token check). Makefile target detection is naive (line starts with target name). Build interval hardcoded to 3 (not configurable per-dispatch). Dev server smoke test port is hardcoded to 5173.
- **Production TODOs**: Make build interval configurable via .dispatch-state.json field. Add proper Makefile parser for targets with prerequisites. Support monorepo workspace-level discovery. Add dev server port detection from command output.
- **Backward compatibility**: All changes are additive. Missing qualityCommands in .dispatch-state.json causes stages 2-4 to be skipped gracefully. build-teammate-prompt.py defaults --quality-commands to '{}'. No regression for existing dispatches.
- **Test fixtures**: gpu-metrics-operator/specs/tasks.md is used as the primary test fixture since it has real tasks with >50% weak verify commands -- perfect for testing the classification and warning features.
