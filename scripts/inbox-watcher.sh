#!/usr/bin/env bash
# Claude Swarm — Inbox watcher
#
# state/inbox.json holds tasks that should run later (scheduled or dependent).
# This watcher polls and promotes tasks to spawn when their conditions are met.
#
# inbox.json schema:
#   [{"task_id": "...", "project_dir": "...", "description": "...",
#     "role": "...", "model": "...", "effort": "...", "batch_id": "...",
#     "not_before": "ISO8601", "depends_on": ["task-id-1"], "queued_at": "..."}]
#
# Singleton via PID file. Designed for cron OR long-running.
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
INBOX="$SWARM_DIR/state/inbox.json"
PID_FILE="$SWARM_DIR/state/inbox-watcher.pid"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

POLL_INTERVAL=30
mkdir -p "$SWARM_DIR/state"
[ -f "$INBOX" ] || echo '[]' > "$INBOX"

# Singleton
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "[inbox-watcher] Already running (PID $PID)"
    exit 0
  fi
fi
echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

echo "[inbox-watcher] Starting (PID $$)"

while true; do
  SIZE=$(jq length "$INBOX" 2>/dev/null || echo "0")
  if [ "$SIZE" -eq 0 ]; then
    echo "[inbox-watcher] Inbox empty, exiting"
    exit 0
  fi

  NOW=$(date +%s)
  PROMOTED=()

  for i in $(seq 0 $((SIZE - 1))); do
    ITEM=$(jq ".[$i]" "$INBOX")
    TASK_ID=$(echo "$ITEM" | jq -r .task_id)
    NOT_BEFORE=$(echo "$ITEM" | jq -r '.not_before // ""')
    DEPENDS=$(echo "$ITEM" | jq -r '.depends_on // [] | .[]')

    READY=true

    # Time check
    if [ -n "$NOT_BEFORE" ]; then
      NB_SEC=$(date -d "$NOT_BEFORE" +%s 2>/dev/null || echo 0)
      if [ "$NB_SEC" -gt "$NOW" ]; then
        READY=false
      fi
    fi

    # Dependency check — all deps must be absent from active tasks
    if [ "$READY" = "true" ] && [ -n "$DEPENDS" ]; then
      for DEP in $DEPENDS; do
        DEP_STATUS=$(bash "$SCRIPTS_DIR/state-helper.sh" get-status "$DEP" 2>/dev/null || echo "")
        if [ -n "$DEP_STATUS" ] && [ "$DEP_STATUS" != "done" ]; then
          READY=false
          break
        fi
      done
    fi

    if [ "$READY" = "true" ]; then
      PROMOTED+=("$TASK_ID")
      PROJECT_DIR=$(echo "$ITEM" | jq -r .project_dir)
      DESCRIPTION=$(echo "$ITEM" | jq -r .description)
      ROLE=$(echo "$ITEM" | jq -r '.role // "builder"')
      MODEL=$(echo "$ITEM" | jq -r '.model // ""')
      EFFORT=$(echo "$ITEM" | jq -r '.effort // ""')

      echo "[inbox-watcher] Promoting $TASK_ID"
      bash "$SCRIPTS_DIR/notify.sh" --milestone agent_start \
        "task=$TASK_ID" "project=$(basename "$PROJECT_DIR")" \
        "role=$ROLE" "model=${MODEL:-sonnet}" 2>/dev/null || true
      bash "$SCRIPTS_DIR/spawn-agent.sh" \
        "$PROJECT_DIR" "$TASK_ID" "$DESCRIPTION" "$ROLE" "$MODEL" "$EFFORT" \
        || echo "[inbox-watcher] spawn failed for $TASK_ID"
    fi
  done

  # Remove promoted from inbox
  if [ ${#PROMOTED[@]} -gt 0 ]; then
    REMOVE_FILTER=""
    for ID in "${PROMOTED[@]}"; do
      REMOVE_FILTER+="--arg rm_$(echo "$ID" | tr -dc 'a-zA-Z0-9_') \"$ID\" "
    done
    NEW_INBOX=$(jq --argjson promoted "$(printf '%s\n' "${PROMOTED[@]}" | jq -R . | jq -s .)" \
      'map(select(.task_id as $id | $promoted | index($id) | not))' "$INBOX")
    echo "$NEW_INBOX" > "$INBOX"
  fi

  sleep "$POLL_INTERVAL"
done
