#!/usr/bin/env bash
# Claude Swarm — Batch history reader
#
# Usage:
#   history-helper.sh last [N]                    # last N batches (default 10)
#   history-helper.sh by-project <project> [N]    # last N batches for project
#   history-helper.sh by-status <status> [N]      # last N batches with status
#   history-helper.sh stats                       # rollup stats
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HIST="$SWARM_DIR/state/batch-history.jsonl"
[ -f "$HIST" ] || { echo "(no history yet)"; exit 0; }

CMD="${1:-last}"
ARG1="${2:-}"
ARG2="${3:-10}"

case "$CMD" in
  last)
    N="${ARG1:-10}"
    tail -n "$N" "$HIST" | jq -r \
      '"\(.status) \(.batch_id)\t\(.project)\t\(.task_count) tasks\t\(.duration_sec)s\t\(.finished)"'
    ;;
  by-project)
    [ -z "$ARG1" ] && { echo "Usage: history-helper.sh by-project <project> [N]"; exit 1; }
    grep "\"project\":\"$ARG1\"" "$HIST" | tail -n "$ARG2" | jq -r \
      '"\(.status) \(.batch_id)\t\(.task_count) tasks\t\(.duration_sec)s\t\(.finished)"'
    ;;
  by-status)
    [ -z "$ARG1" ] && { echo "Usage: history-helper.sh by-status <status> [N]"; exit 1; }
    grep "\"status\":\"$ARG1\"" "$HIST" | tail -n "$ARG2" | jq -r \
      '"\(.batch_id)\t\(.project)\t\(.task_count) tasks\t\(.duration_sec)s"'
    ;;
  stats)
    TOTAL=$(wc -l < "$HIST")
    SHIPPED=$(grep -c '"status":"shipped"' "$HIST" 2>/dev/null || true)
    FAILED=$(grep -c '"status":"failed"' "$HIST" 2>/dev/null || true)
    PARTIAL=$(grep -c '"status":"partial"' "$HIST" 2>/dev/null || true)
    : "${SHIPPED:=0}" "${FAILED:=0}" "${PARTIAL:=0}"
    AVG_DUR=$(jq -s 'map(.duration_sec) | add / length | floor' "$HIST" 2>/dev/null || echo "?")
    echo "Total batches:     $TOTAL"
    echo "  shipped:         $SHIPPED"
    echo "  failed:          $FAILED"
    echo "  partial:         $PARTIAL"
    echo "Avg duration:      ${AVG_DUR}s"
    ;;
  *)
    echo "Usage: history-helper.sh {last [N]|by-project <p> [N]|by-status <s> [N]|stats}" >&2
    exit 1
    ;;
esac
