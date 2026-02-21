#!/bin/bash
# Ralph Parallel - Session Setup Hook
# Runs on SessionStart to configure environment for parallel execution
#
# Actions:
# 1. Detect if we're in a git worktree (teammate context)
# 2. Manage gc.auto based on dispatch state lifecycle
# 3. Output context about active parallel dispatch

set -euo pipefail

# Find project root (handles both main repo and worktrees)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Check if this is a worktree (not the main working tree)
GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || true
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || true

IS_WORKTREE=false
if [ -n "$GIT_COMMON_DIR" ] && [ -n "$GIT_DIR" ] && [ "$GIT_COMMON_DIR" != "$GIT_DIR" ]; then
  IS_WORKTREE=true
fi

# Look for active dispatch state in any spec
DISPATCH_ACTIVE=false
ACTIVE_SPEC=""
for state_file in "$GIT_ROOT"/specs/*/.dispatch-state.json; do
  if [ -f "$state_file" ]; then
    STATUS=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null) || continue
    if [ "$STATUS" = "dispatched" ] || [ "$STATUS" = "merging" ]; then
      DISPATCH_ACTIVE=true
      ACTIVE_SPEC=$(basename "$(dirname "$state_file")")
      break
    fi
  fi
done

# Manage gc.auto based on dispatch lifecycle
if [ "$DISPATCH_ACTIVE" = true ]; then
  # Active dispatch — disable gc to prevent object deletion during parallel work
  CURRENT_GC=$(git config --get gc.auto 2>/dev/null || echo "default")
  if [ "$CURRENT_GC" != "0" ]; then
    git config gc.auto 0
    echo "ralph-parallel: Set gc.auto=0 for active parallel dispatch ($ACTIVE_SPEC)"
  fi
else
  # No active dispatch — restore gc.auto if we previously disabled it
  CURRENT_GC=$(git config --get gc.auto 2>/dev/null || echo "default")
  if [ "$CURRENT_GC" = "0" ]; then
    git config --unset gc.auto 2>/dev/null || true
    echo "ralph-parallel: Restored gc.auto (no active dispatches)"
  fi
fi

# Output context for the session
if [ "$IS_WORKTREE" = true ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
  echo "ralph-parallel: Running in worktree on branch '$BRANCH'"
fi

if [ "$DISPATCH_ACTIVE" = true ]; then
  echo "ralph-parallel: Active parallel dispatch for spec '$ACTIVE_SPEC'"
  echo "ralph-parallel: Run /ralph-parallel:status to see progress"
fi

exit 0
