#!/usr/bin/env bash
# Claude Swarm — Pulse / stuck detection
#
# For each running task, hash the last N lines of its tmux pane and compare
# to the previous hash. If unchanged for STUCK_THRESHOLD consecutive runs,
# mark the task as `stuck` in the state machine and emit a notification.
#
# Usage: check-stuck.sh [stuck_threshold]
#   default threshold: 3 (3 consecutive unchanged runs = stuck)
#
# Designed to run from cron every 1–5 minutes, OR manually.
# Idempotent — safe to run repeatedly.
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
STATE_DIR="$SWARM_DIR/state"
TASKS_FILE="$STATE_DIR/active-tasks.json"
TRACKING_FILE="$STATE_DIR/stuck-tracking.json"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

STUCK_THRESHOLD="${1:-${SWARM_STUCK_THRESHOLD:-3}}"
PANE_TAIL_LINES=20

mkdir -p "$STATE_DIR"
[ -f "$TASKS_FILE" ] || { echo '[]' > "$TASKS_FILE"; }
[ -f "$TRACKING_FILE" ] || { echo '{}' > "$TRACKING_FILE"; }

if ! command -v jq &>/dev/null; then
  echo "[stuck] jq not found, skipping" >&2
  exit 0
fi

# Get list of currently-running tasks
mapfile -t RUNNING_TASKS < <(jq -r '.[] | select((.status // "running") == "running") | .id' "$TASKS_FILE")

if [ ${#RUNNING_TASKS[@]} -eq 0 ]; then
  # Reset tracking when nothing is running
  echo '{}' > "$TRACKING_FILE"
  exit 0
fi

NEW_TRACKING=$(cat "$TRACKING_FILE")

for TASK_ID in "${RUNNING_TASKS[@]}"; do
  TMUX_SESSION="claude-$TASK_ID"

  # Skip if no tmux session (agent already exited but state not yet updated)
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    NEW_TRACKING=$(echo "$NEW_TRACKING" | jq --arg id "$TASK_ID" 'del(.[$id])')
    continue
  fi

  PANE=$(tmux capture-pane -t "$TMUX_SESSION" -p -S "-${PANE_TAIL_LINES}" 2>/dev/null || echo "")
  HASH=$(printf '%s' "$PANE" | sha1sum | cut -d' ' -f1)

  PREV_HASH=$(echo "$NEW_TRACKING" | jq -r --arg id "$TASK_ID" '.[$id].hash // ""')
  PREV_COUNT=$(echo "$NEW_TRACKING" | jq -r --arg id "$TASK_ID" '.[$id].unchanged_count // 0')

  if [ "$HASH" = "$PREV_HASH" ]; then
    NEW_COUNT=$((PREV_COUNT + 1))
  else
    NEW_COUNT=0
  fi

  NEW_TRACKING=$(echo "$NEW_TRACKING" | jq \
    --arg id "$TASK_ID" --arg hash "$HASH" --argjson cnt "$NEW_COUNT" \
    '.[$id] = {hash: $hash, unchanged_count: $cnt, last_check: now | todate}')

  if [ "$NEW_COUNT" -ge "$STUCK_THRESHOLD" ]; then
    CUR_STATUS=$(bash "$SCRIPTS_DIR/state-helper.sh" get-status "$TASK_ID" 2>/dev/null || echo "")
    if [ "$CUR_STATUS" != "stuck" ]; then
      echo "[stuck] $TASK_ID is stuck (unchanged for $NEW_COUNT polls)"
      bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" stuck 2>/dev/null || true
      bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
        "scope=$TASK_ID" "reason=Stuck — no output for $NEW_COUNT consecutive checks" \
        2>/dev/null || true
    fi
  fi
done

echo "$NEW_TRACKING" > "$TRACKING_FILE"
