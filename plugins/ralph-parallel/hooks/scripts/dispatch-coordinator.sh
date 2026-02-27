#!/bin/bash
# Ralph Parallel - Dispatch Coordinator Stop Hook
#
# Prevents Claude from stopping while actively coordinating a parallel dispatch.
# Re-injects coordination context after context compaction.
#
# Uses JSON decision control: {"decision":"block","reason":"..."} on stdout + exit 0
# Block counter with MAX_BLOCKS safety valve prevents infinite loops.
# Heartbeat timestamp enables cross-session safety.
#
# Input (JSON on stdin):
#   stop_hook_active, last_assistant_message, session_id, cwd

set -euo pipefail

# --- Helper functions ---

# Output JSON block decision and exit (uses jq for safe escaping)
# Error path: if jq fails, exits 0 with no output (allow stop rather than crash)
block_stop() {
  local reason="$1"
  jq -nc --arg r "$reason" '{"decision":"block","reason":$r}' || true
  exit 0
}

# Output nothing (allow) and exit
# Error path: none — exit 0 always succeeds
allow_stop() {
  exit 0
}

# Cleanup block counter and allow stop
# Error path: rm -f is already non-fatal; if delete fails, stale counter
# is harmless (reset on next dispatch via status/dispatchedAt mismatch)
cleanup_and_allow() {
  local counter_file="${1:-}"
  if [ -n "$counter_file" ] && [ -f "$counter_file" ]; then
    rm -f "$counter_file" || true
  fi
  exit 0
}

# Read and validate block counter; returns "count" or "0" if reset needed
# Error path: any read/parse failure returns "0" (treat as first block).
# This means /tmp permission denied or corrupt file = block still works,
# just without counter tracking (will never hit safety valve).
read_block_counter() {
  local counter_file="$1"
  local current_status="$2"
  local dispatched_at="$3"

  if [ ! -f "$counter_file" ]; then
    echo "0"
    return
  fi

  local stored
  stored=$(cat "$counter_file" 2>/dev/null) || { echo "0"; return; }
  local stored_count stored_status stored_ts
  stored_count=$(echo "$stored" | cut -d: -f1)
  stored_status=$(echo "$stored" | cut -d: -f2)
  stored_ts=$(echo "$stored" | cut -d: -f3)

  # Reset if dispatch identity changed (abort/re-dispatch)
  if [ "$stored_status" != "$current_status" ] || [ "$stored_ts" != "$dispatched_at" ]; then
    echo "0"
    return
  fi

  echo "${stored_count:-0}"
}

# Write block counter (non-fatal on failure)
# Error path: if /tmp write fails (permission denied, disk full), || true
# ensures blocking still works — just without counter tracking, so the
# safety valve (MAX_BLOCKS) won't trigger and the hook blocks indefinitely
# until dispatch reaches terminal status.
write_block_counter() {
  local counter_file="$1"
  local count="$2"
  local current_status="$3"
  local dispatched_at="$4"
  echo "${count}:${current_status}:${dispatched_at}" > "$counter_file" 2>/dev/null || true
}

# Write heartbeat to dispatch state (atomic, non-fatal on failure)
# Error path: if date/jq/mv fails, || true ensures blocking still works.
# Missing heartbeat means session-setup will treat dispatch as "stale" and
# allow reclaim — a safe default (reclaiming a live dispatch is recoverable;
# failing to reclaim a dead dispatch would trap the user).
write_heartbeat() {
  local state_file="$1"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=""
  if [ -z "$ts" ]; then
    return 0  # Skip heartbeat write if date fails; blocking still works
  fi
  jq --arg ts "$ts" '.lastHeartbeat = $ts' "$state_file" > "${state_file}.tmp.$$" 2>/dev/null \
    && mv "${state_file}.tmp.$$" "$state_file" 2>/dev/null || true
}

# --- Parse stdin ---
# Error path: if jq fails to parse stdin, all fields default to empty/false.
# Empty CWD falls through to $(pwd) in PROJECT_ROOT. Empty SESSION_ID means
# no session isolation (legacy behavior). false STOP_HOOK_ACTIVE = first block.

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || STOP_HOOK_ACTIVE="false"

MAX_BLOCKS="${RALPH_MAX_STOP_BLOCKS:-3}"

# --- Teammate check: only enforce for team leads ---
AGENT_NAME="${CLAUDE_CODE_AGENT_NAME:-}"
if [ -n "$AGENT_NAME" ]; then
  exit 0
fi

# --- Determine project root ---
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT="${CWD:-$(pwd)}"

# --- Resolve dispatch state (TEAM_NAME or scan mode) ---
TEAM_NAME="${CLAUDE_CODE_TEAM_NAME:-}"

if [ -n "$TEAM_NAME" ]; then
  # Derive spec name from team name
  SPEC_NAME="${TEAM_NAME%-parallel}"
  SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
  DISPATCH_STATE="$SPEC_DIR/.dispatch-state.json"
else
  # No team context (session restart?) -- scan ALL active dispatches
  # Error path: jq read failures in scan loop use `|| continue` (skip file)
  # or `|| VAR=""` (treat as empty). Skipping = no block = allow stop (safe).
  DISPATCH_STATE=""
  SPEC_NAME=""
  FOUND_MY_DISPATCH=false

  for state_file in "$PROJECT_ROOT"/specs/*/.dispatch-state.json; do
    [ -f "$state_file" ] || continue
    FILE_STATUS=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null) || continue
    [ "$FILE_STATUS" = "dispatched" ] || continue

    COORD_SID=$(jq -r '.coordinatorSessionId // empty' "$state_file" 2>/dev/null) || COORD_SID=""
    SCAN_SPEC=$(basename "$(dirname "$state_file")")

    # In scan mode, only match dispatches we can positively identify as
    # belonging to this session via coordinatorSessionId.
    if [ -n "$COORD_SID" ] && [ -n "$SESSION_ID" ] && [ "$COORD_SID" = "$SESSION_ID" ]; then
      FOUND_MY_DISPATCH=true
      DISPATCH_STATE="$state_file"
      SPEC_NAME="$SCAN_SPEC"
      SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
      break
    fi

    # Ambiguous ownership (legacy or empty session_id) — only claim if
    # team config exists (proves this is a live dispatch, not stale)
    if [ -z "$COORD_SID" ] || [ -z "$SESSION_ID" ]; then
      SCAN_TEAM_CONFIG="$HOME/.claude/teams/${SCAN_SPEC}-parallel/config.json"
      if [ -f "$SCAN_TEAM_CONFIG" ]; then
        SCAN_MEMBERS=$(jq '.members | length' "$SCAN_TEAM_CONFIG" 2>/dev/null) || SCAN_MEMBERS=0
        if [ "$SCAN_MEMBERS" -gt 0 ]; then
          FOUND_MY_DISPATCH=true
          DISPATCH_STATE="$state_file"
          SPEC_NAME="$SCAN_SPEC"
          SPEC_DIR="$PROJECT_ROOT/specs/$SPEC_NAME"
          break
        fi
      fi
      # No team config or empty members — stale dispatch, skip it
    fi
    # coordinatorSessionId mismatch — continue scanning
  done

  if [ "$FOUND_MY_DISPATCH" = false ]; then
    # No active dispatch belongs to this session
    exit 0
  fi
fi

if [ ! -f "$DISPATCH_STATE" ]; then
  exit 0
fi

# Error path: if jq can't read status, exit 0 (allow stop — can't determine
# dispatch state, so blocking would be unsafe). If dispatchedAt fails,
# default to "unknown" which causes block counter mismatch = reset to 0.
STATUS=$(jq -r '.status // "unknown"' "$DISPATCH_STATE" 2>/dev/null) || exit 0
DISPATCHED_AT=$(jq -r '.dispatchedAt // "unknown"' "$DISPATCH_STATE" 2>/dev/null) || DISPATCHED_AT="unknown"

# --- Block counter file path ---
COUNTER_FILE="/tmp/ralph-stop-${SPEC_NAME}-${SESSION_ID}"

# --- Terminal status check: any status other than "dispatched" ---
if [ "$STATUS" != "dispatched" ]; then
  cleanup_and_allow "$COUNTER_FILE"
fi

# --- Session isolation (team-name branch) ---
if [ -n "$TEAM_NAME" ] && [ -f "$DISPATCH_STATE" ]; then
  COORD_SID=$(jq -r '.coordinatorSessionId // empty' "$DISPATCH_STATE" 2>/dev/null) || COORD_SID=""
  if [ -n "$COORD_SID" ] && [ -n "$SESSION_ID" ]; then
    if [ "$COORD_SID" != "$SESSION_ID" ]; then
      exit 0
    fi
  fi
  # Missing COORD_SID or empty SESSION_ID: legacy behavior (proceed to block)
fi

# --- Completion check ---
# Error path: if groups can't be read, exit 0 (allow stop — can't determine
# progress). If completedGroups fails, default 0 = "nothing done" = block.
TOTAL_GROUPS=$(jq '.groups | length' "$DISPATCH_STATE" 2>/dev/null) || exit 0
COMPLETED_GROUPS=$(jq '.completedGroups | length' "$DISPATCH_STATE" 2>/dev/null) || COMPLETED_GROUPS=0

if [ "$COMPLETED_GROUPS" -ge "$TOTAL_GROUPS" ] 2>/dev/null; then
  # All groups complete — check if any tasks remain incomplete
  TASKS_MD="$SPEC_DIR/tasks.md"
  if [ -f "$TASKS_MD" ]; then
    INCOMPLETE=$(grep -c '^\- \[ \]' "$TASKS_MD" 2>/dev/null) || INCOMPLETE=0
    if [ "$INCOMPLETE" -eq 0 ]; then
      # Everything done — silent allow, no stderr reminder
      cleanup_and_allow "$COUNTER_FILE"
    fi
  else
    cleanup_and_allow "$COUNTER_FILE"
  fi
fi

# --- Block counter check (applies to both first and re-block) ---
# Error path: read_block_counter returns "0" on any failure (see function).
# -ge comparison with 2>/dev/null handles non-numeric: defaults to "not >=",
# meaning we proceed to block (safe — worst case is one extra block cycle).
BLOCK_COUNT=$(read_block_counter "$COUNTER_FILE" "$STATUS" "$DISPATCHED_AT")

if [ "$BLOCK_COUNT" -ge "$MAX_BLOCKS" ] 2>/dev/null; then
  # Safety valve: allow stop after MAX_BLOCKS (do NOT delete counter —
  # prevents loop: reach MAX -> allow -> restart -> counter gone -> block again)
  exit 0
fi

# --- Team lost check ---
# Error path: if team config can't be read or jq fails, MEMBER_COUNT=0
# which means TEAM_LOST=true. This is safe: "teammates lost" reason tells
# the coordinator to re-dispatch, which is the correct recovery action.
TEAM_CONFIG="$HOME/.claude/teams/${SPEC_NAME}-parallel/config.json"
TEAM_LOST=false
if [ ! -f "$TEAM_CONFIG" ]; then
  TEAM_LOST=true
else
  MEMBER_COUNT=$(jq '.members | length' "$TEAM_CONFIG" 2>/dev/null) || MEMBER_COUNT=0
  if [ "$MEMBER_COUNT" -eq 0 ]; then
    TEAM_LOST=true
  fi
fi

if [ "$TEAM_LOST" = true ] && [ -z "$TEAM_NAME" ]; then
  # Scan mode, stale dispatch — allow stop
  exit 0
fi

# --- Write heartbeat (active dispatch, about to block) ---
# Non-fatal: failed heartbeat = session-setup treats as stale (safe default)
write_heartbeat "$DISPATCH_STATE" || true

# --- Increment block counter ---
# Non-fatal: failed counter write = safety valve won't trigger (blocks forever
# until terminal status, which is safe — just less user-friendly)
NEW_COUNT=$((BLOCK_COUNT + 1))
write_block_counter "$COUNTER_FILE" "$NEW_COUNT" "$STATUS" "$DISPATCHED_AT" || true

# --- Build and emit JSON block ---
if [ "$TEAM_LOST" = true ]; then
  REASON="[Dispatch: ${SPEC_NAME}] TEAMMATES LOST (${COMPLETED_GROUPS}/${TOTAL_GROUPS} groups done). Team died. Re-run /ralph-parallel:dispatch to re-spawn. Do NOT execute tasks yourself."
elif [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  REASON="[Dispatch: ${SPEC_NAME}] Still active (${COMPLETED_GROUPS}/${TOTAL_GROUPS} groups done, block ${NEW_COUNT}/${MAX_BLOCKS}). Check TaskList, coordinate teammates. Work remains."
else
  REASON="[Dispatch: ${SPEC_NAME}] ${COMPLETED_GROUPS}/${TOTAL_GROUPS} groups done. Next: check TaskList for progress, coordinate idle teammates. Do NOT stop until all tasks complete and team cleaned up."
fi

block_stop "$REASON"
