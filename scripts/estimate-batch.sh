#!/usr/bin/env bash
# Claude Swarm — Pre-flight resource estimate
#
# Reads a tasks.json and prints estimated cost/tokens/time as JSON.
# Used by spawn-batch (plan preview) and bot's /swarm preview.
#
# Usage: estimate-batch.sh <tasks.json>
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HIST="$SWARM_DIR/state/batch-history.jsonl"
TASKS_JSON="${1:?Usage: estimate-batch.sh <tasks.json>}"

if [ ! -f "$TASKS_JSON" ]; then
  echo '{"error": "tasks file not found"}'
  exit 1
fi

TASK_COUNT=$(jq length "$TASKS_JSON")
TOTAL_PROMPT_CHARS=0

for i in $(seq 0 $((TASK_COUNT - 1))); do
  T_DESC=$(jq -r ".[$i].description" "$TASKS_JSON")
  if [ -f "$T_DESC" ]; then
    SIZE=$(wc -c < "$T_DESC")
    TOTAL_PROMPT_CHARS=$((TOTAL_PROMPT_CHARS + SIZE))
  else
    SIZE=$(printf '%s' "$T_DESC" | wc -c)
    TOTAL_PROMPT_CHARS=$((TOTAL_PROMPT_CHARS + SIZE))
  fi
done

EST_INPUT_TOKENS=$((TOTAL_PROMPT_CHARS / 4))
EST_OUTPUT_TOKENS=$((EST_INPUT_TOKENS * 3))
# Sonnet pricing (rough): $3/M in, $15/M out → cents = (in*3 + out*15)/10000
EST_COST_CENTS=$(( (EST_INPUT_TOKENS * 3 + EST_OUTPUT_TOKENS * 15) / 10000 ))

# Time estimate: use historical avg for this task count if we have data, else
# fall back to ~120s per task heuristic.
EST_TIME_SEC=$((TASK_COUNT * 120))
if [ -f "$HIST" ] && [ -s "$HIST" ]; then
  AVG=$(jq -s --argjson n "$TASK_COUNT" \
    '[.[] | select(.task_count == $n) | .duration_sec] | (add // 0) / (length // 1) | floor' \
    "$HIST" 2>/dev/null || echo 0)
  if [ "$AVG" -gt 0 ]; then
    EST_TIME_SEC="$AVG"
  fi
fi

jq -n \
  --argjson tasks "$TASK_COUNT" \
  --argjson chars "$TOTAL_PROMPT_CHARS" \
  --argjson in_tok "$EST_INPUT_TOKENS" \
  --argjson out_tok "$EST_OUTPUT_TOKENS" \
  --argjson cents "$EST_COST_CENTS" \
  --argjson sec "$EST_TIME_SEC" \
  '{task_count: $tasks, prompt_chars: $chars,
    est_input_tokens: $in_tok, est_output_tokens: $out_tok,
    est_cost_cents: $cents, est_duration_sec: $sec}'
