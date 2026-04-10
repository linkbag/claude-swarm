#!/usr/bin/env bash
# Claude Swarm — ESR appender (per-project + cross-project rollup)
#
# OpenClaw-style: writes to BOTH the project's own docs/ESR.md (institutional
# memory inside the project repo) AND the swarm's docs/ESR.md (cross-project
# rollup the orchestrator can grep). Also syncs to $OBSIDIAN_BASE/<project>/ESR.md
# if OBSIDIAN_BASE is configured in swarm.conf.
#
# Usage:
#   append-esr.sh <batch-id> <project-name> <status> <task-count> <duration-sec> [notes] [project-dir]
#
# Backward compat: if project-dir is omitted, only the swarm-side ESR is written.
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

BATCH_ID="${1:?Missing batch-id}"
PROJECT="${2:?Missing project}"
STATUS="${3:?Missing status}"     # shipped | failed | partial
TASK_COUNT="${4:-?}"
DURATION="${5:-?}"
NOTES="${6:-}"
PROJECT_DIR="${7:-}"

TS=$(date -Iseconds)
DATE=$(date +%Y-%m-%d)

case "$STATUS" in
  shipped) ICON="🚢" ;;
  failed)  ICON="❌" ;;
  partial) ICON="⚠️" ;;
  *)       ICON="•"  ;;
esac

# Build the entry once, write it to multiple locations.
_make_entry() {
  printf '\n### %s Batch `%s` — %s\n' "$ICON" "$BATCH_ID" "$TS"
  echo "- **Project:** $PROJECT"
  echo "- **Status:** $STATUS"
  echo "- **Tasks:** $TASK_COUNT"
  echo "- **Duration:** ${DURATION}s"
  if [ -n "$NOTES" ]; then
    echo "- **Notes:** $NOTES"
  fi
  echo
}

_ensure_template() {
  local file="$1" project_name="$2"
  if [ ! -f "$file" ]; then
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<TEMPLATE
# $project_name — Executive Summary Report (ESR)
*Last updated: $TS*

## What We've Built
<!-- High-level summary of what exists -->

## Latest Updates
<!-- Most recent batch's work, auto-appended below -->

## What's Next
<!-- Prioritized next steps -->

## Actionable Levers
<!-- Key decisions, resources, blockers -->

## Learnings
<!-- Technical and product lessons learned -->

---
*Living document. Updated by claude-swarm after each batch.*
TEMPLATE
  fi
}

# 1. Cross-project rollup (swarm-side, always written)
SWARM_ESR="$SWARM_DIR/docs/ESR.md"
_ensure_template "$SWARM_ESR" "Claude Swarm"
_make_entry >> "$SWARM_ESR"
echo "[esr] appended batch $BATCH_ID → $SWARM_ESR"

# 2. Per-project ESR (only if project-dir provided)
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  PROJECT_ESR="$PROJECT_DIR/docs/ESR.md"
  _ensure_template "$PROJECT_ESR" "$PROJECT"
  # Update "Last updated" timestamp inline
  sed -i "s/\*Last updated:.*\*/*Last updated: $TS*/" "$PROJECT_ESR" 2>/dev/null || true
  _make_entry >> "$PROJECT_ESR"
  echo "[esr] appended batch $BATCH_ID → $PROJECT_ESR"

  # 3. Optional Obsidian sync
  if [ -n "${OBSIDIAN_BASE:-}" ] && [ -d "$OBSIDIAN_BASE" ]; then
    OBSIDIAN_ESR="$OBSIDIAN_BASE/$PROJECT/ESR.md"
    mkdir -p "$(dirname "$OBSIDIAN_ESR")"
    cp "$PROJECT_ESR" "$OBSIDIAN_ESR"
    echo "[esr] synced to $OBSIDIAN_ESR"
  fi
fi
