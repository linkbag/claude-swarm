#!/usr/bin/env bash
# Claude Swarm — Decision logger (per-project + cross-project)
#
# Append a decision entry to BOTH:
#   - <swarm>/docs/decisions/YYYY-MM-DD.md (cross-project rollup)
#   - <project>/docs/decisions/YYYY-MM-DD.md (project-local, if project-dir given)
#
# Usage:
#   log-decision.sh <scope> <title> <body> [project-dir]
#
# Example:
#   log-decision.sh "batch:feat-x" "Use opus for conflict resolution" \
#     "Branch X had a 200-line conflict with Y." "/mnt/d/Startup projects/Stock selector"
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SCOPE="${1:?Missing scope}"
TITLE="${2:?Missing title}"
BODY="${3:-}"
PROJECT_DIR="${4:-}"

DATE=$(date +%Y-%m-%d)
TS=$(date -Iseconds)

_write_entry() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ]; then
    printf '# Decisions — %s\n\n' "$DATE" > "$file"
  fi
  {
    printf '## %s — %s\n' "$TS" "$TITLE"
    printf '**Scope:** `%s`\n\n' "$SCOPE"
    if [ -n "$BODY" ]; then
      printf '%s\n\n' "$BODY"
    fi
    printf -- '---\n\n'
  } >> "$file"
  echo "[decision] logged to $file"
}

# 1. Swarm-side rollup
_write_entry "$SWARM_DIR/docs/decisions/$DATE.md"

# 2. Project-local
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  _write_entry "$PROJECT_DIR/docs/decisions/$DATE.md"
fi
