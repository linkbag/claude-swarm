#!/usr/bin/env bash
# Claude Swarm — Decision logger
#
# Append a decision entry to docs/decisions/YYYY-MM-DD.md.
#
# Usage:
#   log-decision.sh <scope> <title> <body>
#
# Example:
#   log-decision.sh "batch:feat-x" "Use opus for conflict resolution" \
#     "Branch X had a 200-line conflict with Y. Sonnet wasn't keeping context."
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DECISIONS_DIR="$SWARM_DIR/docs/decisions"
mkdir -p "$DECISIONS_DIR"

SCOPE="${1:?Missing scope}"
TITLE="${2:?Missing title}"
BODY="${3:-}"

DATE=$(date +%Y-%m-%d)
TS=$(date -Iseconds)
FILE="$DECISIONS_DIR/$DATE.md"

if [ ! -f "$FILE" ]; then
  printf '# Decisions — %s\n\n' "$DATE" > "$FILE"
fi

{
  printf '## %s — %s\n' "$TS" "$TITLE"
  printf '**Scope:** `%s`\n\n' "$SCOPE"
  if [ -n "$BODY" ]; then
    printf '%s\n\n' "$BODY"
  fi
  printf -- '---\n\n'
} >> "$FILE"

echo "[decision] logged to $FILE"
