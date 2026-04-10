#!/usr/bin/env bash
# Claude Swarm — CI deploy notification
#
# After integration pushes to main (or opens a PR), poll GitHub Actions for
# the resulting workflow run and send Telegram on pass / fail / timeout.
#
# Usage:
#   deploy-notify.sh <project-dir> <commit-hash> [batch-id]
#
# Designed to run in the background. Polls every 30s for up to ~15 min.
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"

PROJECT_DIR="${1:?Usage: deploy-notify.sh <project-dir> <commit-hash> [batch-id]}"
COMMIT="${2:?Missing commit hash}"
BATCH_ID="${3:-}"

if ! command -v gh &>/dev/null; then
  echo "[deploy-notify] gh CLI not installed, exiting"
  exit 0
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "[deploy-notify] project dir missing: $PROJECT_DIR"
  exit 0
fi

cd "$PROJECT_DIR" || exit 0

PROJECT_NAME=$(basename "$PROJECT_DIR")
SHORT_SHA="${COMMIT:0:7}"

echo "[deploy-notify] Watching gh runs for $PROJECT_NAME @ $SHORT_SHA"

# Poll for up to 15 min (30 attempts × 30s)
for ATTEMPT in $(seq 1 30); do
  sleep 30

  # Get the most recent run touching this commit
  STATUS_JSON=$(gh run list --commit "$COMMIT" --limit 1 --json status,conclusion,url 2>/dev/null \
    | jq -r '.[0] // empty' 2>/dev/null || echo "")

  if [ -z "$STATUS_JSON" ]; then
    # No run yet — keep polling
    continue
  fi

  RUN_STATUS=$(echo "$STATUS_JSON" | jq -r '.status // ""' 2>/dev/null)
  CONCLUSION=$(echo "$STATUS_JSON" | jq -r '.conclusion // ""' 2>/dev/null)
  RUN_URL=$(echo "$STATUS_JSON" | jq -r '.url // ""' 2>/dev/null)

  if [ "$RUN_STATUS" = "completed" ]; then
    if [ "$CONCLUSION" = "success" ]; then
      MSG="✅ *CI passed* \`$PROJECT_NAME\`@\`$SHORT_SHA\`"
      [ -n "$BATCH_ID" ] && MSG="$MSG (batch \`$BATCH_ID\`)"
      [ -n "$RUN_URL" ] && MSG="$MSG\n$RUN_URL"
      bash "$SCRIPTS_DIR/notify.sh" "$MSG" 2>/dev/null || true
      echo "[deploy-notify] ✅ CI passed"
      exit 0
    else
      MSG="❌ *CI failed* \`$PROJECT_NAME\`@\`$SHORT_SHA\` (conclusion: $CONCLUSION)"
      [ -n "$BATCH_ID" ] && MSG="$MSG (batch \`$BATCH_ID\`)"
      [ -n "$RUN_URL" ] && MSG="$MSG\n$RUN_URL"
      bash "$SCRIPTS_DIR/notify.sh" "$MSG" 2>/dev/null || true
      echo "[deploy-notify] ❌ CI failed: $CONCLUSION"
      exit 1
    fi
  fi
done

# 15 min elapsed without a completed run
MSG="⏰ *CI timeout* \`$PROJECT_NAME\`@\`$SHORT_SHA\` — no completed workflow within 15 min"
[ -n "$BATCH_ID" ] && MSG="$MSG (batch \`$BATCH_ID\`)"
bash "$SCRIPTS_DIR/notify.sh" "$MSG" 2>/dev/null || true
echo "[deploy-notify] ⏰ Timeout"
exit 2
