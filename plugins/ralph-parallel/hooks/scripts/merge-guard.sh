#!/bin/bash
# Ralph Parallel - Merge Status Guard (PreToolUse)
# Intercepts Edit/Write to .dispatch-state.json files.
# When content would set status="merged", runs validate-pre-merge.py.
# Exit codes: 0 = allow, 2 = block + stderr feedback
#
# Timeout protection: hooks.json registers this hook with a 30s timeout.
# If validate-pre-merge.py hangs, the hook runner kills this process.
# The script itself does not implement internal timeouts to avoid
# conflicting with the hook runner's signal-based termination.

set -euo pipefail

INPUT=$(cat)

# Only enforce for Write and Edit tools
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# Fast path: not a dispatch-state file (check before agent/content parsing)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || FILE_PATH=""
if [ -z "$FILE_PATH" ]; then
  exit 0
fi
BASENAME=$(basename "$FILE_PATH")
if [ "$BASENAME" != ".dispatch-state.json" ]; then
  exit 0
fi

# Only enforce for coordinator (no AGENT_NAME = coordinator)
AGENT_NAME="${CLAUDE_CODE_AGENT_NAME:-}"
if [ -n "$AGENT_NAME" ]; then
  exit 0
fi

# Check if the write content contains "merged"
# Empty new_string/content fields are harmless -- nothing to check
CONTAINS_MERGED=false
if [ "$TOOL_NAME" = "Edit" ]; then
  NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null) || NEW_STRING=""
  if [ -z "$NEW_STRING" ]; then
    exit 0
  fi
  if echo "$NEW_STRING" | grep -qF '"merged"'; then
    CONTAINS_MERGED=true
  fi
elif [ "$TOOL_NAME" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null) || CONTENT=""
  if [ -z "$CONTENT" ]; then
    exit 0
  fi
  if echo "$CONTENT" | grep -qF '"merged"'; then
    CONTAINS_MERGED=true
  fi
fi

if [ "$CONTAINS_MERGED" != "true" ]; then
  exit 0
fi

# Resolve spec dir from the file path
SPEC_DIR=$(dirname "$FILE_PATH")
TASKS_MD="$SPEC_DIR/tasks.md"

if [ ! -f "$TASKS_MD" ]; then
  exit 0
fi

# Run validate-pre-merge.py
# Resolve SCRIPT_DIR with fallback for BASH_SOURCE edge cases (sourced scripts, symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd 2>/dev/null)" || true
SCRIPT_DIR="${SCRIPT_DIR:-.}"
VALIDATE_SCRIPT="$SCRIPT_DIR/scripts/validate-pre-merge.py"

if [ ! -f "$VALIDATE_SCRIPT" ]; then
  echo "ralph-parallel: WARNING: validate-pre-merge.py not found, allowing merge" >&2
  exit 0
fi

echo "ralph-parallel: Intercepted status='merged' write — running pre-merge validation" >&2
VALIDATE_OUTPUT=$(python3 "$VALIDATE_SCRIPT" \
  --dispatch-state "$FILE_PATH" \
  --tasks-md "$TASKS_MD" \
  --skip-quality-commands 2>&1) && VALIDATE_EXIT=0 || VALIDATE_EXIT=$?

if [ $VALIDATE_EXIT -ne 0 ]; then
  echo "PRE-MERGE VALIDATION FAILED — blocking status='merged' write" >&2
  echo "$VALIDATE_OUTPUT" | tail -20 >&2
  echo "Run: python3 validate-pre-merge.py --dispatch-state $FILE_PATH --tasks-md $TASKS_MD" >&2
  echo "Fix all failures before setting status to merged." >&2
  exit 2
fi

exit 0
