#!/usr/bin/env bash
# Claude Swarm — Daily standup
#
# Reads batch-history.jsonl (last 24h), active-tasks.json, queue.json, inbox.json
# and sends a structured summary via Telegram.
#
# Usage:
#   daily-standup.sh                # build + send
#   daily-standup.sh --dry-run      # build + print, don't send
#
# Cron suggestion (09:00 PT every weekday):
#   0 9 * * 1-5 bash /home/dz/claude-swarm/scripts/daily-standup.sh >/dev/null 2>&1
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
STATE_DIR="$SWARM_DIR/state"
HIST="$STATE_DIR/batch-history.jsonl"
ACTIVE="$STATE_DIR/active-tasks.json"
QUEUE="$STATE_DIR/queue.json"
INBOX="$STATE_DIR/inbox.json"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

TODAY=$(date +%Y-%m-%d)
NOW_S=$(date +%s)
CUTOFF_ISO=$(date -Iseconds -d "24 hours ago" 2>/dev/null || date -Iseconds)

# ── Last 24h batch stats ─────────────────────────────────────────────────────
COMPLETED_24H=0
SHIPPED_24H=0
FAILED_24H=0
PARTIAL_24H=0
COMPLETED_LIST=""

if [ -f "$HIST" ] && [ -s "$HIST" ] && command -v jq &>/dev/null; then
  RECENT=$(jq -c --arg cut "$CUTOFF_ISO" 'select(.finished >= $cut)' "$HIST" 2>/dev/null || echo "")
  if [ -n "$RECENT" ]; then
    COMPLETED_24H=$(echo "$RECENT" | grep -c . || true)
    SHIPPED_24H=$(echo "$RECENT" | grep -c '"status":"shipped"' || true)
    FAILED_24H=$(echo "$RECENT" | grep -c '"status":"failed"' || true)
    PARTIAL_24H=$(echo "$RECENT" | grep -c '"status":"partial"' || true)
    : "${COMPLETED_24H:=0}" "${SHIPPED_24H:=0}" "${FAILED_24H:=0}" "${PARTIAL_24H:=0}"
    COMPLETED_LIST=$(echo "$RECENT" | jq -r \
      '"  \(if .status=="shipped" then "🚢" elif .status=="failed" then "❌" else "⚠️" end) `\(.batch_id)` — \(.project) (\(.task_count) tasks, \(.duration_sec)s)"' \
      2>/dev/null | head -10)
  fi
fi

# ── Currently active ─────────────────────────────────────────────────────────
RUNNING_COUNT=0
REVIEWING_COUNT=0
STUCK_COUNT=0
if [ -f "$ACTIVE" ] && command -v jq &>/dev/null; then
  RUNNING_COUNT=$(jq '[.[] | select((.status // "running") == "running")] | length' "$ACTIVE" 2>/dev/null || echo 0)
  REVIEWING_COUNT=$(jq '[.[] | select(.status == "reviewing")] | length' "$ACTIVE" 2>/dev/null || echo 0)
  STUCK_COUNT=$(jq '[.[] | select(.status == "stuck")] | length' "$ACTIVE" 2>/dev/null || echo 0)
fi

# ── Queue / inbox ────────────────────────────────────────────────────────────
QUEUE_COUNT=0
INBOX_COUNT=0
if [ -f "$QUEUE" ] && command -v jq &>/dev/null; then
  QUEUE_COUNT=$(jq 'length' "$QUEUE" 2>/dev/null || echo 0)
fi
if [ -f "$INBOX" ] && command -v jq &>/dev/null; then
  INBOX_COUNT=$(jq 'length' "$INBOX" 2>/dev/null || echo 0)
fi

# ── Pending approvals ────────────────────────────────────────────────────────
PENDING_APPROVALS=0
if [ -d "$STATE_DIR/pending" ]; then
  PENDING_APPROVALS=$(find "$STATE_DIR/pending" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
fi

# ── Build the message ────────────────────────────────────────────────────────
if [ "$COMPLETED_24H" -eq 0 ] && [ "$RUNNING_COUNT" -eq 0 ] && [ "$QUEUE_COUNT" -eq 0 ] && \
   [ "$INBOX_COUNT" -eq 0 ] && [ "$PENDING_APPROVALS" -eq 0 ]; then
  MSG="🌅 *Daily Standup* — $TODAY

All quiet. No active work, queues, or pending approvals."
else
  MSG="🌅 *Daily Standup* — $TODAY

📦 *Last 24h*
✅ Shipped: $SHIPPED_24H
⚠️ Partial: $PARTIAL_24H
❌ Failed: $FAILED_24H"

  if [ -n "$COMPLETED_LIST" ]; then
    MSG="$MSG
$COMPLETED_LIST"
  fi

  MSG="$MSG

🔨 *Right now*
🟢 Running: $RUNNING_COUNT
🔍 Reviewing: $REVIEWING_COUNT
🛑 Stuck: $STUCK_COUNT
🕒 Queued: $QUEUE_COUNT
📥 Inbox: $INBOX_COUNT
🛂 Pending approval: $PENDING_APPROVALS"
fi

# ── Output ───────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  echo "$MSG"
  exit 0
fi

bash "$SCRIPTS_DIR/notify.sh" "$MSG"
echo "[standup] sent for $TODAY"
