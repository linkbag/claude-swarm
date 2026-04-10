#!/usr/bin/env bash
# Claude Swarm — Learnings store
#
# Append-only JSONL of failure-analysis and success patterns. Used by
# analyze-failure.sh to retrieve prior similar incidents and by future
# orchestrator planning to apply known-good patterns.
#
# state/learnings.jsonl entry shape:
#
#   Failure entry (analyzer ran, refined prompt produced):
#   {
#     "kind": "failure",
#     "ts": "2026-04-10T15:00:00-07:00",
#     "task_id": "feat-healthz",
#     "project": "Stock selector",
#     "role": "builder", "model": "sonnet",
#     "retry_round": 1,
#     "signature": "...",          # short stable key for grouping
#     "error_excerpt": "...",      # first matching error line
#     "verdict": "refined" | "needs_human_review",
#     "diagnosis": "...",          # analyzer's one-line summary
#     "refined_prompt_sha": "..." | null
#   }
#
#   Success entry (review converged on a task):
#   {
#     "kind": "success",
#     "ts": "...",
#     "task_id": "feat-healthz",
#     "project": "Stock selector",
#     "role": "builder", "model": "sonnet",
#     "retry_count": 1,            # 0 = zero-shot
#     "review_rounds": 1,          # 1 = first-round pass
#     "prompt_sha": "...",
#     "signature": "..."           # category extracted from prompt (rough)
#   }
#
# Usage:
#   learnings-helper.sh append-failure <jsonline>
#   learnings-helper.sh append-success <jsonline>
#   learnings-helper.sh find-similar <signature> [limit]
#   learnings-helper.sh find-successes-by-role <role> [limit]
#   learnings-helper.sh signature <text>           # → short hash
#   learnings-helper.sh stats
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LEARNINGS="$SWARM_DIR/state/learnings.jsonl"
mkdir -p "$SWARM_DIR/state"
[ -f "$LEARNINGS" ] || touch "$LEARNINGS"

_signature_for() {
  # Cheap, stable signature: lowercase the input, strip variable substrings
  # (timestamps, hex hashes, file paths, line numbers), then sha1 the first
  # 200 chars. Same root cause should produce the same signature most of the
  # time. Far from perfect — analyzer can override if it produces a better
  # categorization.
  printf '%s' "$1" \
    | tr 'A-Z' 'a-z' \
    | sed -E 's@/[a-z0-9._/-]+@PATH@g; s@[0-9a-f]{7,}@HASH@g; s@[0-9]+@N@g; s@\s+@ @g' \
    | head -c 200 \
    | sha1sum | cut -c1-12
}

_append_jsonl() {
  local line="$1"
  echo "$line" >> "$LEARNINGS"
}

_find_similar() {
  local sig="$1" limit="${2:-3}"
  [ -s "$LEARNINGS" ] || return 0
  jq -c --arg sig "$sig" 'select(.signature == $sig)' "$LEARNINGS" 2>/dev/null | tail -n "$limit"
}

_find_successes_by_role() {
  local role="$1" limit="${2:-5}"
  [ -s "$LEARNINGS" ] || return 0
  jq -c --arg role "$role" \
    'select(.kind == "success" and .role == $role)' \
    "$LEARNINGS" 2>/dev/null | tail -n "$limit"
}

_stats() {
  if [ ! -s "$LEARNINGS" ]; then
    echo "(no learnings yet)"
    return
  fi
  TOTAL=$(wc -l < "$LEARNINGS")
  FAILURES=$(grep -c '"kind":"failure"' "$LEARNINGS" 2>/dev/null || true)
  SUCCESSES=$(grep -c '"kind":"success"' "$LEARNINGS" 2>/dev/null || true)
  REFINED=$(grep -c '"verdict":"refined"' "$LEARNINGS" 2>/dev/null || true)
  HUMAN=$(grep -c '"verdict":"needs_human_review"' "$LEARNINGS" 2>/dev/null || true)
  : "${FAILURES:=0}" "${SUCCESSES:=0}" "${REFINED:=0}" "${HUMAN:=0}"
  echo "Learnings:        $TOTAL entries"
  echo "  failures:       $FAILURES (refined: $REFINED, escalated: $HUMAN)"
  echo "  successes:      $SUCCESSES"
}

case "${1:-}" in
  append-failure)  shift; _append_jsonl "$1" ;;
  append-success)  shift; _append_jsonl "$1" ;;
  find-similar)    shift; _find_similar "$@" ;;
  find-successes-by-role) shift; _find_successes_by_role "$@" ;;
  signature)       shift; _signature_for "$1" ;;
  stats)           _stats ;;
  *)
    cat <<USAGE >&2
Usage: learnings-helper.sh <command> [args]
  append-failure <json-line>
  append-success <json-line>
  find-similar <signature> [limit=3]
  find-successes-by-role <role> [limit=5]
  signature <text>
  stats
USAGE
    exit 1
    ;;
esac
