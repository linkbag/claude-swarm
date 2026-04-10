#!/usr/bin/env bash
# Claude Swarm — Check status of all running agents
set -uo pipefail  # not -e: empty tmux ls / no matches must not abort the script

echo "=== Active Swarm Agents ==="

SESSIONS=$(tmux ls 2>/dev/null | grep "^claude-" || true)

if [ -z "$SESSIONS" ]; then
  echo "  (no active agents)"
  exit 0
fi

while read -r line; do
  [ -z "$line" ] && continue
  SESSION=$(echo "$line" | cut -d: -f1)
  TASK_ID="${SESSION#claude-}"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    LAST_LINE=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -v "^$" | tail -1 || echo "")
    if echo "$LAST_LINE" | grep -qi "done\|complete\|✅\|error\|❌"; then
      echo "  ✅ $TASK_ID — DONE"
    else
      echo "  🟢 $TASK_ID — RUNNING"
    fi
  else
    echo "  ⚪ $TASK_ID — SESSION ENDED"
  fi
done <<< "$SESSIONS"
