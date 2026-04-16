#!/usr/bin/env bash
# Claude Swarm — Clean up worktrees, branches, and tmux sessions after a batch
# Usage: cleanup.sh <project-dir> [--all]

set -euo pipefail

PROJECT_DIR="${1:?Usage: cleanup.sh <project-dir> [--all]}"
ALL="${2:-}"

cd "$PROJECT_DIR"

echo "=== Cleaning up swarm artifacts ==="

# Kill all swarm tmux sessions
echo "Killing swarm tmux sessions..."
tmux ls 2>/dev/null | grep "^claude-" | cut -d: -f1 | while read -r s; do
  tmux kill-session -t "$s" 2>/dev/null && echo "  Killed: $s"
done

# Remove worktrees
echo "Removing worktrees..."
WORKTREE_DIR="${PROJECT_DIR}-worktrees"
if [ -d "$WORKTREE_DIR" ]; then
  rm -rf "$WORKTREE_DIR"
  echo "  Removed: $WORKTREE_DIR"
fi

# Also clean .claude/worktrees if any
if [ -d "$PROJECT_DIR/.claude/worktrees" ]; then
  rm -rf "$PROJECT_DIR/.claude/worktrees"
  echo "  Removed: .claude/worktrees/"
fi

git worktree prune 2>/dev/null

# Delete feat/* branches (local + remote)
if [ "$ALL" = "--all" ]; then
  echo "Deleting feat/* branches..."
  git branch | grep "feat/" | xargs -r git branch -D 2>/dev/null || true
  git branch -r | grep "origin/feat/" | sed 's|origin/||' | while read -r b; do
    git push origin --delete "$b" 2>/dev/null && echo "  Deleted remote: $b"
  done
fi

# Prune terminal-state tasks older than SWARM_RETENTION_DAYS (default 7)
SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RETENTION="${SWARM_RETENTION_DAYS:-7}"
echo "Pruning task history older than ${RETENTION} days..."
bash "$SWARM_DIR/scripts/state-helper.sh" prune-old "$RETENTION" 2>/dev/null || true

echo "✅ Cleanup complete"
