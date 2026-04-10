#!/usr/bin/env bash
# Claude Swarm — Aggregated metrics
#
# Usage:
#   metrics.sh                    # default rollup
#   metrics.sh --last-7d          # filter by recency (days)
#   metrics.sh --by-project       # group by project
#   metrics.sh --by-status        # group by status
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HIST="$SWARM_DIR/state/batch-history.jsonl"

if [ ! -f "$HIST" ] || [ ! -s "$HIST" ]; then
  echo "(no batch history yet — run a batch first)"
  exit 0
fi

MODE="${1:-summary}"
TOTAL=$(wc -l < "$HIST")

# Helper: filter by --last-Nd (relative to now)
_filter_by_days() {
  local days="$1"
  local cutoff
  cutoff=$(date -Iseconds -d "$days days ago" 2>/dev/null || echo "")
  if [ -z "$cutoff" ]; then
    cat "$HIST"
  else
    jq -c --arg cut "$cutoff" 'select(.finished >= $cut)' "$HIST"
  fi
}

case "$MODE" in
  summary|"")
    # `grep -c` already prints 0 on no-match; suppress its exit-1 with `|| true`.
    SHIPPED=$(grep -c '"status":"shipped"' "$HIST" 2>/dev/null || true)
    FAILED=$(grep -c '"status":"failed"' "$HIST" 2>/dev/null || true)
    PARTIAL=$(grep -c '"status":"partial"' "$HIST" 2>/dev/null || true)
    : "${SHIPPED:=0}" "${FAILED:=0}" "${PARTIAL:=0}"
    AVG_DUR=$(jq -s 'map(.duration_sec) | add / length | floor' "$HIST" 2>/dev/null || echo "?")
    AVG_TASKS=$(jq -s 'map(.task_count) | add / length | floor' "$HIST" 2>/dev/null || echo "?")
    SUCCESS_RATE=0
    if [ "$TOTAL" -gt 0 ]; then
      SUCCESS_RATE=$(( SHIPPED * 100 / TOTAL ))
    fi
    echo "═══════════════════════════════════════"
    echo "  Claude Swarm — Metrics Summary"
    echo "═══════════════════════════════════════"
    echo "Total batches:      $TOTAL"
    echo "  shipped:          $SHIPPED ($SUCCESS_RATE%)"
    echo "  partial:          $PARTIAL"
    echo "  failed:           $FAILED"
    echo
    echo "Avg duration:       ${AVG_DUR}s"
    echo "Avg tasks/batch:    $AVG_TASKS"
    ;;
  --last-*d)
    DAYS="${MODE#--last-}"
    DAYS="${DAYS%d}"
    FILTERED=$(_filter_by_days "$DAYS")
    COUNT=$(echo "$FILTERED" | grep -c . || echo 0)
    SHIPPED=$(echo "$FILTERED" | grep -c '"status":"shipped"' || echo 0)
    echo "Last ${DAYS}d: $COUNT batches, $SHIPPED shipped"
    if [ "$COUNT" -gt 0 ]; then
      AVG=$(echo "$FILTERED" | jq -s 'map(.duration_sec) | add / length | floor' 2>/dev/null || echo "?")
      echo "Avg duration:    ${AVG}s"
    fi
    ;;
  --by-project)
    echo "Batches by project:"
    jq -r '.project' "$HIST" | sort | uniq -c | sort -rn | head -20
    ;;
  --by-status)
    echo "Batches by status:"
    jq -r '.status' "$HIST" | sort | uniq -c | sort -rn
    ;;
  *)
    echo "Usage: metrics.sh [summary|--last-Nd|--by-project|--by-status]" >&2
    exit 1
    ;;
esac
