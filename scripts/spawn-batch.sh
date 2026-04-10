#!/usr/bin/env bash
# Claude Swarm — Spawn a batch of agents + start integration watcher
#
# Usage: spawn-batch.sh <project-dir> <batch-id> <description> <tasks-json>
#   tasks-json: path to JSON file with task definitions
#   Format: [{"id": "task-1", "description": "/tmp/prompt.md", "role": "builder", "model": "sonnet"}]

set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"

[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

PROJECT_DIR="${1:?Usage: spawn-batch.sh <project-dir> <batch-id> <description> <tasks-json>}"
BATCH_ID="${2:?Missing batch-id}"
BATCH_DESC="${3:?Missing description}"
TASKS_JSON="${4:?Missing tasks JSON file}"

if [ ! -f "$TASKS_JSON" ]; then
  echo "❌ Tasks file not found: $TASKS_JSON"
  exit 1
fi

TASK_COUNT=$(jq length "$TASKS_JSON")
PROJECT_NAME="$(basename "$PROJECT_DIR")"
echo "🐝 Batch $BATCH_ID: spawning $TASK_COUNT subteams"

bash "$SCRIPTS_DIR/notify.sh" --milestone plan \
  "batch=$BATCH_ID" "count=$TASK_COUNT" "project=$PROJECT_NAME" 2>/dev/null || true

# ─── Approval gate ──────────────────────────────────────────────────────────
#
# If SWARM_REQUIRE_APPROVAL=true, write a pending dir and exit. The bot's
# /swarm approve <batch-id> will re-invoke this script with the env var unset
# so the auto-endorse path runs.

REQUIRE_APPROVAL="${SWARM_REQUIRE_APPROVAL:-false}"
PENDING_DIR="$SWARM_DIR/state/pending/$BATCH_ID"

if [ "$REQUIRE_APPROVAL" = "true" ]; then
  mkdir -p "$PENDING_DIR"
  cp "$TASKS_JSON" "$PENDING_DIR/tasks.json"
  cat > "$PENDING_DIR/metadata.json" <<EOF
{
  "batchId": "$BATCH_ID",
  "projectDir": "$PROJECT_DIR",
  "description": "$BATCH_DESC",
  "tasksFile": "$TASKS_JSON",
  "createdAt": "$(date -Iseconds)",
  "taskCount": $TASK_COUNT
}
EOF
  bash "$SCRIPTS_DIR/notify.sh" --milestone endorse_required \
    "batch=$BATCH_ID" "project=$PROJECT_NAME" "count=$TASK_COUNT" 2>/dev/null || true
  echo "🛂 Approval required — pending in $PENDING_DIR"
  exit 0
fi

# ─── Auto-endorse all tasks ──────────────────────────────────────────────────

TMUX_SESSIONS=()
for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK_ID=$(jq -r ".[$i].id" "$TASKS_JSON")
  bash "$SCRIPTS_DIR/endorse-task.sh" "$TASK_ID"
done

bash "$SCRIPTS_DIR/notify.sh" --milestone spawn \
  "batch=$BATCH_ID" "count=$TASK_COUNT" "project=$PROJECT_NAME" 2>/dev/null || true

# NOTE: pending dir cleanup is deferred to the very end of this script.
# Doing it here would delete the tasks.json we're still iterating over when
# the bot's /swarm approve re-invokes us with TASKS_JSON pointing inside the
# pending dir.

# Wait for cooldown
sleep "${SWARM_ENDORSEMENT_COOLDOWN:-30}"

# ─── Spawn each agent (with concurrency cap + overflow queue) ───────────────

MAX_CONCURRENT="${SWARM_MAX_CONCURRENT:-8}"
QUEUE_FILE="$SWARM_DIR/state/queue.json"
mkdir -p "$SWARM_DIR/state"
[ -f "$QUEUE_FILE" ] || echo '[]' > "$QUEUE_FILE"

for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK_ID=$(jq -r ".[$i].id" "$TASKS_JSON")
  TASK_DESC=$(jq -r ".[$i].description" "$TASKS_JSON")
  TASK_ROLE=$(jq -r ".[$i].role // \"builder\"" "$TASKS_JSON")
  TASK_MODEL=$(jq -r ".[$i].model // \"\"" "$TASKS_JSON")
  TASK_EFFORT=$(jq -r ".[$i].effort // \"\"" "$TASKS_JSON")

  RUNNING=$(bash "$SCRIPTS_DIR/state-helper.sh" count-by-status running 2>/dev/null || echo "0")
  if [ "$RUNNING" -ge "$MAX_CONCURRENT" ]; then
    # Capacity full → queue
    echo "🕒 At capacity ($RUNNING/$MAX_CONCURRENT), queueing $TASK_ID"
    jq --arg id "$TASK_ID" --arg pd "$PROJECT_DIR" --arg desc "$TASK_DESC" \
       --arg role "$TASK_ROLE" --arg model "$TASK_MODEL" --arg effort "$TASK_EFFORT" \
       --arg batch "$BATCH_ID" --arg now "$(date -Iseconds)" \
       '. + [{task_id: $id, project_dir: $pd, description: $desc,
              role: $role, model: $model, effort: $effort,
              batch_id: $batch, queued_at: $now}]' \
       "$QUEUE_FILE" > "${QUEUE_FILE}.tmp" && mv "${QUEUE_FILE}.tmp" "$QUEUE_FILE"
    bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
      "scope=$TASK_ID" "reason=queued (capacity $RUNNING/$MAX_CONCURRENT)" 2>/dev/null || true
  else
    bash "$SCRIPTS_DIR/spawn-agent.sh" "$PROJECT_DIR" "$TASK_ID" "$TASK_DESC" "$TASK_ROLE" "$TASK_MODEL" "$TASK_EFFORT"
  fi
  TMUX_SESSIONS+=("claude-$TASK_ID")
done

# Start queue watcher if there's anything queued (idempotent — singleton)
QUEUE_SIZE=$(jq length "$QUEUE_FILE" 2>/dev/null || echo "0")
if [ "$QUEUE_SIZE" -gt 0 ] && [ -f "$SCRIPTS_DIR/queue-watcher.sh" ]; then
  setsid bash "$SCRIPTS_DIR/queue-watcher.sh" >> "$SWARM_DIR/logs/queue-watcher.log" 2>&1 &
  disown 2>/dev/null || true
  echo "🕒 Queue watcher started ($QUEUE_SIZE tasks queued)"
fi

# ─── Start integration watcher ───────────────────────────────────────────────

if [ -f "$SCRIPTS_DIR/integration-watcher.sh" ]; then
  SESSIONS_STR="${TMUX_SESSIONS[*]}"
  bash "$SCRIPTS_DIR/integration-watcher.sh" "$PROJECT_DIR" "$BATCH_ID" "$SESSIONS_STR" &
  WATCHER_PID=$!
  echo "🔗 Integration watcher started"
  echo "   PID: $WATCHER_PID"
  echo "   Sessions: $SESSIONS_STR"
fi

# ─── Save batch metadata ────────────────────────────────────────────────────

mkdir -p "$SWARM_DIR/logs"

# Build sessions JSON array safely (printf '%s\n' with empty array still emits one line)
if [ "${#TMUX_SESSIONS[@]}" -gt 0 ]; then
  SESSIONS_JSON=$(printf '%s\n' "${TMUX_SESSIONS[@]}" | jq -R . | jq -s .)
else
  SESSIONS_JSON='[]'
fi

cat > "$SWARM_DIR/logs/batch-${BATCH_ID}.json" << EOF
{
  "batchId": "$BATCH_ID",
  "projectDir": "$PROJECT_DIR",
  "description": "$BATCH_DESC",
  "createdAt": "$(date -Iseconds)",
  "sessions": $SESSIONS_JSON
}
EOF

echo "🧾 Batch metadata: $SWARM_DIR/logs/batch-${BATCH_ID}.json"

# Now safe to clean the pending dir — every consumer of TASKS_JSON has run.
# (For non-approval flow, PENDING_DIR doesn't exist so this is a no-op.)
rm -rf "$PENDING_DIR" 2>/dev/null || true
