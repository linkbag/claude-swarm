#!/usr/bin/env bash
# Claude Swarm — ESR appender
#
# Append a structured batch summary to docs/ESR.md.
#
# Usage: append-esr.sh <batch-id> <project> <status> <task-count> <duration-sec> [extra-notes]
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ESR="$SWARM_DIR/docs/ESR.md"
mkdir -p "$(dirname "$ESR")"
[ -f "$ESR" ] || printf '# Claude Swarm — ESR\n\n---\n' > "$ESR"

BATCH_ID="${1:?Missing batch-id}"
PROJECT="${2:?Missing project}"
STATUS="${3:?Missing status}"     # shipped | failed | partial
TASK_COUNT="${4:-?}"
DURATION="${5:-?}"
NOTES="${6:-}"

TS=$(date -Iseconds)

case "$STATUS" in
  shipped) ICON="🚢" ;;
  failed)  ICON="❌" ;;
  partial) ICON="⚠️" ;;
  *)       ICON="•"  ;;
esac

{
  printf '\n### %s Batch `%s` — %s\n' "$ICON" "$BATCH_ID" "$TS"
  echo "- **Project:** $PROJECT"
  echo "- **Status:** $STATUS"
  echo "- **Tasks:** $TASK_COUNT"
  echo "- **Duration:** ${DURATION}s"
  if [ -n "$NOTES" ]; then
    echo "- **Notes:** $NOTES"
  fi
  echo
} >> "$ESR"

echo "[esr] appended batch $BATCH_ID"
