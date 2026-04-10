#!/usr/bin/env bash
# Claude Swarm — Queue watcher
#
# Long-running poller that drains state/queue.json when SWARM_MAX_CONCURRENT
# capacity opens up. Started lazily by spawn-batch.sh.
#
# Idempotent — uses a pid file. Only one instance runs.
#
# queue.json schema:
#   [{"task_id": "...", "project_dir": "...", "description": "...",
#     "role": "...", "model": "...", "effort": "...", "batch_id": "...",
#     "queued_at": "..."}]
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
STATE_DIR="$SWARM_DIR/state"
QUEUE_FILE="$STATE_DIR/queue.json"
PID_FILE="$STATE_DIR/queue-watcher.pid"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

MAX_CONCURRENT="${SWARM_MAX_CONCURRENT:-8}"
POLL_INTERVAL=15

mkdir -p "$STATE_DIR"
[ -f "$QUEUE_FILE" ] || echo '[]' > "$QUEUE_FILE"

# ─── Singleton guard ────────────────────────────────────────────────────────

if [ -f "$PID_FILE" ]; then
  EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "[queue-watcher] Already running (PID $EXISTING_PID)"
    exit 0
  fi
fi
echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

echo "[queue-watcher] Starting (PID $$, max_concurrent=$MAX_CONCURRENT)"

# ─── Main loop ──────────────────────────────────────────────────────────────

while true; do
  QUEUE_SIZE=$(jq length "$QUEUE_FILE" 2>/dev/null || echo "0")

  if [ "$QUEUE_SIZE" -eq 0 ]; then
    # Nothing left → exit cleanly
    echo "[queue-watcher] Queue empty, exiting"
    exit 0
  fi

  RUNNING=$(bash "$SCRIPTS_DIR/state-helper.sh" count-by-status running 2>/dev/null || echo "0")
  CAPACITY=$((MAX_CONCURRENT - RUNNING))

  if [ "$CAPACITY" -le 0 ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Drain up to CAPACITY tasks from the queue
  for _ in $(seq 1 "$CAPACITY"); do
    QUEUE_SIZE=$(jq length "$QUEUE_FILE" 2>/dev/null || echo "0")
    [ "$QUEUE_SIZE" -eq 0 ] && break

    # Pop head
    HEAD=$(jq '.[0]' "$QUEUE_FILE")
    jq '.[1:]' "$QUEUE_FILE" > "${QUEUE_FILE}.tmp" && mv "${QUEUE_FILE}.tmp" "$QUEUE_FILE"

    TASK_ID=$(echo "$HEAD" | jq -r '.task_id')
    PROJECT_DIR=$(echo "$HEAD" | jq -r '.project_dir')
    DESCRIPTION=$(echo "$HEAD" | jq -r '.description')
    ROLE=$(echo "$HEAD" | jq -r '.role // "builder"')
    MODEL=$(echo "$HEAD" | jq -r '.model // ""')
    EFFORT=$(echo "$HEAD" | jq -r '.effort // ""')

    echo "[queue-watcher] Spawning queued task: $TASK_ID"
    bash "$SCRIPTS_DIR/notify.sh" --milestone agent_start \
      "task=$TASK_ID" "project=$(basename "$PROJECT_DIR")" \
      "role=$ROLE" "model=${MODEL:-sonnet}" 2>/dev/null || true

    bash "$SCRIPTS_DIR/spawn-agent.sh" \
      "$PROJECT_DIR" "$TASK_ID" "$DESCRIPTION" "$ROLE" "$MODEL" "$EFFORT" \
      || echo "[queue-watcher] Failed to spawn $TASK_ID"
  done

  sleep "$POLL_INTERVAL"
done
