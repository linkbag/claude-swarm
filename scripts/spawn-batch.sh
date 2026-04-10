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

# ─── Auto-endorse all tasks ──────────────────────────────────────────────────

TMUX_SESSIONS=()
for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK_ID=$(jq -r ".[$i].id" "$TASKS_JSON")
  bash "$SCRIPTS_DIR/endorse-task.sh" "$TASK_ID"
done

bash "$SCRIPTS_DIR/notify.sh" --milestone spawn \
  "batch=$BATCH_ID" "count=$TASK_COUNT" "project=$PROJECT_NAME" 2>/dev/null || true

# Wait for cooldown
sleep "${SWARM_ENDORSEMENT_COOLDOWN:-30}"

# ─── Spawn each agent ────────────────────────────────────────────────────────

for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK_ID=$(jq -r ".[$i].id" "$TASKS_JSON")
  TASK_DESC=$(jq -r ".[$i].description" "$TASKS_JSON")
  TASK_ROLE=$(jq -r ".[$i].role // \"builder\"" "$TASKS_JSON")
  TASK_MODEL=$(jq -r ".[$i].model // \"\"" "$TASKS_JSON")
  TASK_EFFORT=$(jq -r ".[$i].effort // \"\"" "$TASKS_JSON")

  bash "$SCRIPTS_DIR/spawn-agent.sh" "$PROJECT_DIR" "$TASK_ID" "$TASK_DESC" "$TASK_ROLE" "$TASK_MODEL" "$TASK_EFFORT"
  TMUX_SESSIONS+=("claude-$TASK_ID")
done

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
