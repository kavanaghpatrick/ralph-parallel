#!/bin/bash
# Ralph Parallel - File Ownership Enforcement Hook
#
# Registered as a PreToolUse hook for Write and Edit tools.
# Blocks file writes outside the teammate's owned files list.
#
# Exit codes:
#   0 = allow (file is in ownership list or no dispatch active)
#   2 = block + send stderr as feedback to teammate
#
# Input (JSON on stdin):
#   tool_name, tool_input (with file_path), session_id, cwd, etc.
#   Environment: CLAUDE_CODE_AGENT_NAME (teammate name = group name)

set -euo pipefail

INPUT=$(cat)

# Only enforce for Write and Edit tools
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || FILE_PATH=""
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only enforce for teammates (agents with a name set)
AGENT_NAME="${CLAUDE_CODE_AGENT_NAME:-}"
if [ -z "$AGENT_NAME" ]; then
  # Not a teammate (probably the lead or a solo session) — allow
  exit 0
fi

# Find project root (git rev-parse is canonical; CWD fallback for non-git envs)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
  PROJECT_ROOT="${CWD:-$(pwd)}"
}

# Find dispatch state — check team name first, then .current-spec
TEAM_NAME="${CLAUDE_CODE_TEAM_NAME:-}"
SPEC_DIR=""

if [ -n "$TEAM_NAME" ]; then
  SPEC_NAME="${TEAM_NAME%-parallel}"
  if [ -d "$PROJECT_ROOT/specs/$SPEC_NAME" ]; then
    SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
  fi
fi

if [ -z "$SPEC_DIR" ] && [ -f "$PROJECT_ROOT/specs/.current-spec" ]; then
  SPEC_NAME=$(tr -d '[:space:]' < "$PROJECT_ROOT/specs/.current-spec")
  if [ -n "$SPEC_NAME" ] && [ -d "$PROJECT_ROOT/specs/$SPEC_NAME" ]; then
    SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
  fi
fi

DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"
if [ -z "$SPEC_DIR" ] || [ ! -f "$DISPATCH_STATE" ]; then
  # No dispatch state — allow through
  exit 0
fi

# Find this teammate's owned files from dispatch state
# Agent name = group name in dispatch
OWNED_FILES=$(jq -r --arg name "$AGENT_NAME" \
  '.groups[] | select(.name == $name) | .ownedFiles[]' \
  "$DISPATCH_STATE" 2>/dev/null) || exit 0

if [ -z "$OWNED_FILES" ]; then
  # Group not found or no owned files — allow through
  exit 0
fi

# Normalize file path to be relative to project root for comparison
REL_PATH="${FILE_PATH#"$PROJECT_ROOT"/}"

# Check if file is in owned files list
ALLOWED=false
while IFS= read -r owned; do
  if [ "$REL_PATH" = "$owned" ] || [ "$FILE_PATH" = "$owned" ]; then
    ALLOWED=true
    break
  fi
done <<< "$OWNED_FILES"

if [ "$ALLOWED" = true ]; then
  exit 0
else
  echo "FILE OWNERSHIP VIOLATION: You ($AGENT_NAME) attempted to write '$REL_PATH'" >&2
  echo "Your owned files: $(echo "$OWNED_FILES" | tr '\n' ', ')" >&2
  echo "Message the lead if you need changes to this file." >&2
  exit 2
fi
