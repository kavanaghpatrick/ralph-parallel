#!/bin/bash
# Ralph Parallel - Session Setup Hook
# Runs on SessionStart to configure environment for parallel execution
#
# Actions:
# 1. Detect if we're in a git worktree (teammate context)
# 2. Manage gc.auto based on dispatch state lifecycle
# 3. Output context about active parallel dispatch

set -euo pipefail

# Auto-sync plugin source to cache so new sessions always get latest code
# CLAUDE_PLUGIN_ROOT = plugin root (e.g. ~/.claude/plugins/cache/.../0.2.0/)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  DEV_SRC="$(git rev-parse --show-toplevel 2>/dev/null)/ralph-parallel"
  CACHE_DIR="$(cd "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || CACHE_DIR=""
  DEV_DIR="$(cd "$DEV_SRC" 2>/dev/null && pwd -P)" || DEV_DIR=""
  # Only sync if dev source exists and differs from cache (avoids self-sync)
  if [ -d "${DEV_SRC:-}" ] && [ -n "$CACHE_DIR" ] && [ "$CACHE_DIR" != "$DEV_DIR" ]; then
    rsync -a --delete "$DEV_SRC/" "$CACHE_DIR/" 2>/dev/null || true
  fi
fi

# Read hook input (must be first -- stdin is consumed once)
# Error path: if jq fails, SESSION_ID="" = no session isolation (legacy behavior)
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

# Best-effort: export session_id for dispatch.md to read
# Works on fresh start, broken on resume (#24775) -- auto-reclaim compensates
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$SESSION_ID" ]; then
  echo "export CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

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
# Error path: jq failures use `|| continue` to skip unreadable state files.
# If all files are unreadable, DISPATCH_ACTIVE stays false = no coordination.
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
  DISPATCH_FILE="$GIT_ROOT/specs/$ACTIVE_SPEC/.dispatch-state.json"
  # Error path: all jq reads default to safe values (0, "unknown", "none").
  # These are only used for informational echo output, so failures are cosmetic.
  TOTAL_GROUPS=$(jq '.groups | length' "$DISPATCH_FILE" 2>/dev/null) || TOTAL_GROUPS=0
  COMPLETED_GROUPS=$(jq '.completedGroups | length' "$DISPATCH_FILE" 2>/dev/null) || COMPLETED_GROUPS=0
  GROUP_NAMES=$(jq -r '[.groups[].name] | join(", ")' "$DISPATCH_FILE" 2>/dev/null) || GROUP_NAMES="unknown"
  COMPLETED_LIST=$(jq -r '(.completedGroups // []) | join(", ")' "$DISPATCH_FILE" 2>/dev/null) || COMPLETED_LIST="none"
  STRATEGY=$(jq -r '.strategy // "file-ownership"' "$DISPATCH_FILE" 2>/dev/null) || STRATEGY="file-ownership"

  # Check if a team still exists
  # Error path: if jq fails, MEMBER_COUNT=0 -> TEAM_EXISTS=false -> triggers
  # stale marking (safe: prevents blocking loop when team state is unreadable)
  TEAM_CONFIG="$HOME/.claude/teams/${ACTIVE_SPEC}-parallel/config.json"
  TEAM_EXISTS=false
  if [ -f "$TEAM_CONFIG" ]; then
    MEMBER_COUNT=$(jq '.members | length' "$TEAM_CONFIG" 2>/dev/null) || MEMBER_COUNT=0
    if [ "$MEMBER_COUNT" -gt 0 ]; then
      TEAM_EXISTS=true
    fi
  fi

  # Auto-reclaim: update coordinatorSessionId when session changes
  if [ -n "$SESSION_ID" ]; then
    COORD_SID=$(jq -r '.coordinatorSessionId // empty' "$DISPATCH_FILE" 2>/dev/null) || COORD_SID=""

    if [ -n "$COORD_SID" ] && [ "$COORD_SID" != "$SESSION_ID" ] && [ "$TEAM_EXISTS" = true ]; then
      # Session mismatch + team active -- check heartbeat before reclaiming
      HEARTBEAT=$(jq -r '.lastHeartbeat // empty' "$DISPATCH_FILE" 2>/dev/null) || HEARTBEAT=""
      RECLAIM_THRESHOLD="${RALPH_RECLAIM_THRESHOLD_MINUTES:-10}"

      SHOULD_RECLAIM=true
      if [ -n "$HEARTBEAT" ]; then
        # Compute heartbeat age in minutes (BSD date with GNU fallback)
        # Error path: if both date formats fail, HEARTBEAT_EPOCH=0 (epoch).
        # This makes AGE_MINUTES very large = "stale" = allow reclaim.
        # This is the safe default: reclaiming a live dispatch is recoverable
        # (coordinator re-stamps on next session), while failing to reclaim a
        # dead dispatch would permanently trap the user.
        HEARTBEAT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$HEARTBEAT" "+%s" 2>/dev/null) \
          || HEARTBEAT_EPOCH=$(date -d "$HEARTBEAT" "+%s" 2>/dev/null) \
          || HEARTBEAT_EPOCH=0
        NOW_EPOCH=$(date +%s 2>/dev/null) || NOW_EPOCH=0
        AGE_MINUTES=$(( (NOW_EPOCH - HEARTBEAT_EPOCH) / 60 ))

        if [ "$AGE_MINUTES" -lt "$RECLAIM_THRESHOLD" ] 2>/dev/null; then
          SHOULD_RECLAIM=false
          echo "ralph-parallel: Dispatch for '$ACTIVE_SPEC' owned by another active session (heartbeat ${AGE_MINUTES}m ago). Skipping auto-reclaim."
        fi
      fi
      # If no heartbeat (legacy) or heartbeat stale: reclaim

      if [ "$SHOULD_RECLAIM" = true ]; then
        # Error path: if jq/mv fails, reclaim silently fails. Session continues
        # without coordinator ownership — stop hook won't block for this session
        # (coordinatorSessionId mismatch), which is safe (user can re-dispatch).
        jq --arg sid "$SESSION_ID" '.coordinatorSessionId = $sid' "$DISPATCH_FILE" > "${DISPATCH_FILE}.tmp.$$" 2>/dev/null \
          && mv "${DISPATCH_FILE}.tmp.$$" "$DISPATCH_FILE" 2>/dev/null \
          && echo "ralph-parallel: Auto-reclaimed dispatch for '$ACTIVE_SPEC' (session changed)" \
          || echo "ralph-parallel: Warning: failed to auto-reclaim dispatch for '$ACTIVE_SPEC'"
      fi
    elif [ -z "$COORD_SID" ] && [ "$TEAM_EXISTS" = true ]; then
      # Legacy dispatch (no field) -- stamp current session
      # Error path: if write fails, dispatch stays without coordinatorSessionId.
      # Stop hook treats this as ambiguous ownership = still blocks (safe).
      jq --arg sid "$SESSION_ID" '.coordinatorSessionId = $sid' "$DISPATCH_FILE" > "${DISPATCH_FILE}.tmp.$$" 2>/dev/null \
        && mv "${DISPATCH_FILE}.tmp.$$" "$DISPATCH_FILE" 2>/dev/null \
        && echo "ralph-parallel: Stamped session ID on legacy dispatch for '$ACTIVE_SPEC'" \
        || echo "ralph-parallel: Warning: failed to stamp session ID on dispatch for '$ACTIVE_SPEC'"
    fi
  fi

  echo "ralph-parallel: Active parallel dispatch for spec '$ACTIVE_SPEC'"
  echo "ralph-parallel: Status: $COMPLETED_GROUPS/$TOTAL_GROUPS groups complete ($STRATEGY strategy)"
  echo "ralph-parallel: Groups: $GROUP_NAMES"
  echo "ralph-parallel: Completed: $COMPLETED_LIST"

  if [ "$TEAM_EXISTS" = false ] && [ "$COMPLETED_GROUPS" -lt "$TOTAL_GROUPS" ]; then
    # Team is dead and work is incomplete — mark dispatch as stale so
    # the Stop hook doesn't trap the user in a blocking loop.
    # Error path: if stale marking fails, stop hook will still see "dispatched"
    # status + no team = scan mode allows stop (TEAM_LOST + !TEAM_NAME = exit 0).
    STALE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || STALE_TS="1970-01-01T00:00:00Z"
    jq --arg reason "team_lost" --arg ts "$STALE_TS" \
      '.status = "stale" | .staleReason = $reason | .staleSince = $ts' \
      "$DISPATCH_FILE" > "${DISPATCH_FILE}.tmp.$$" 2>/dev/null \
      && mv "${DISPATCH_FILE}.tmp.$$" "$DISPATCH_FILE" 2>/dev/null \
      || true
    # Restore gc.auto since dispatch is no longer active
    CURRENT_GC=$(git config --get gc.auto 2>/dev/null || echo "default")
    if [ "$CURRENT_GC" = "0" ]; then
      git config --unset gc.auto 2>/dev/null || true
    fi
    echo ""
    echo "ralph-parallel: Dispatch for '$ACTIVE_SPEC' marked stale (team lost, $COMPLETED_GROUPS/$TOTAL_GROUPS groups done)."
    echo "ralph-parallel: Run /ralph-parallel:dispatch to resume, or /ralph-parallel:dispatch --abort to cancel."
  else
    echo "ralph-parallel: Run /ralph-parallel:status to see progress"
  fi
fi

exit 0
