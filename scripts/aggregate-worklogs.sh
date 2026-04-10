#!/usr/bin/env bash
# Claude Swarm — Worklog aggregator
#
# spawn-agent.sh tells each agent to write a worklog at /tmp/worklog-<tmux-session>.md.
# This script collects them after a batch finishes, concatenates with task headers,
# saves to logs/batch-<batch-id>-worklog.md, and posts a Telegram summary.
#
# Usage: aggregate-worklogs.sh <batch-id> <tmux-session> [tmux-session ...]
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"

BATCH_ID="${1:?Missing batch-id}"
shift
SESSIONS=("$@")

[ ${#SESSIONS[@]} -eq 0 ] && exit 0

OUT="$SWARM_DIR/logs/batch-${BATCH_ID}-worklog.md"
mkdir -p "$SWARM_DIR/logs"

{
  printf '# Batch `%s` — Aggregated Worklog\n' "$BATCH_ID"
  printf '*Generated: %s*\n\n' "$(date -Iseconds)"
  printf -- '---\n\n'
} > "$OUT"

FOUND=0
for SESSION in "${SESSIONS[@]}"; do
  TASK_ID="${SESSION#claude-}"
  WORKLOG="/tmp/worklog-${SESSION}.md"

  if [ -f "$WORKLOG" ]; then
    FOUND=$((FOUND + 1))
    {
      printf '## Task `%s`\n\n' "$TASK_ID"
      cat "$WORKLOG"
      printf '\n\n---\n\n'
    } >> "$OUT"
  else
    {
      printf '## Task `%s`\n\n' "$TASK_ID"
      printf '_No worklog found at %s_\n\n' "$WORKLOG"
      printf -- '---\n\n'
    } >> "$OUT"
  fi
done

echo "[worklog] Aggregated $FOUND/${#SESSIONS[@]} worklogs → $OUT"

# Post a short summary via Telegram (raw mode, not a milestone — agg is post-batch)
SUMMARY="📓 *Worklog aggregated* \`$BATCH_ID\`
$FOUND/${#SESSIONS[@]} agent worklogs collected
File: \`$OUT\`"
bash "$SCRIPTS_DIR/notify.sh" "$SUMMARY" 2>/dev/null || true
