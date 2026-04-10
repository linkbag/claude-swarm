#!/usr/bin/env bash
# Claude Swarm — Log rotation
#
# - Gzips files in logs/ older than ROTATE_GZIP_DAYS (default 7)
# - Deletes files older than ROTATE_DELETE_DAYS (default 30)
# - Skips files already gzipped
# - Idempotent — safe to run via cron daily
#
# Usage:
#   rotate-logs.sh             # actually rotate
#   rotate-logs.sh --dry-run   # show what would happen
#
# Cron suggestion (03:30 daily):
#   30 3 * * * bash /home/dz/claude-swarm/scripts/rotate-logs.sh >/dev/null 2>&1
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOGS_DIR="$SWARM_DIR/logs"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

GZIP_DAYS="${ROTATE_GZIP_DAYS:-7}"
DELETE_DAYS="${ROTATE_DELETE_DAYS:-30}"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ ! -d "$LOGS_DIR" ]; then
  echo "[rotate] no logs/ dir, nothing to do"
  exit 0
fi

echo "[rotate] gzip>${GZIP_DAYS}d, delete>${DELETE_DAYS}d, dir=$LOGS_DIR"

# 1. Gzip old plain files
GZIPPED=0
while IFS= read -r -d '' file; do
  if [ "$DRY_RUN" = "true" ]; then
    echo "  would gzip: $file"
  else
    gzip -q "$file" 2>/dev/null && GZIPPED=$((GZIPPED + 1))
  fi
done < <(find "$LOGS_DIR" -type f \
           -mtime "+$GZIP_DAYS" \
           ! -name '*.gz' \
           ! -name '.gitkeep' \
           -print0 2>/dev/null)

# 2. Delete files older than the delete threshold (gzipped or not)
DELETED=0
while IFS= read -r -d '' file; do
  if [ "$DRY_RUN" = "true" ]; then
    echo "  would delete: $file"
  else
    rm -f "$file" 2>/dev/null && DELETED=$((DELETED + 1))
  fi
done < <(find "$LOGS_DIR" -type f \
           -mtime "+$DELETE_DAYS" \
           ! -name '.gitkeep' \
           -print0 2>/dev/null)

if [ "$DRY_RUN" = "true" ]; then
  echo "[rotate] dry-run complete"
else
  echo "[rotate] gzipped=$GZIPPED  deleted=$DELETED"
fi
