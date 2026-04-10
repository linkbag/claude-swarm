#!/usr/bin/env bash
# Claude Swarm — Watch a tmux session and notify + review on completion
# Called automatically by spawn-agent.sh
#
# Usage: notify-on-complete.sh <tmux-session> <task-id> <work-dir> <project-dir> <branch>

set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

TMUX_SESSION="${1:?Missing tmux session}"
TASK_ID="${2:?Missing task-id}"
WORK_DIR="${3:?Missing work-dir}"
PROJECT_DIR="${4:?Missing project-dir}"
BRANCH="${5:?Missing branch}"

MAX_REVIEW_ROUNDS="${SWARM_MAX_REVIEW_ROUNDS:-3}"
POLL_INTERVAL=60

# ─── Poll for completion ────────────────────────────────────────────────────

while true; do
  sleep "$POLL_INTERVAL"

  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[watcher] Session $TMUX_SESSION ended"
    break
  fi

  # Check if agent finished (look for runner completion message)
  LAST_LINES=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -20 2>/dev/null || echo "")
  if echo "$LAST_LINES" | grep -q "\[runner\] ✅\|\[runner\] ❌"; then
    echo "[watcher] Agent completed"
    break
  fi
done

# ─── Notify completion ──────────────────────────────────────────────────────

PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Detect ok/fail from runner exit marker
LAST_LINES=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -20 2>/dev/null || echo "")
if echo "$LAST_LINES" | grep -q "\[runner\] ❌"; then
  AGENT_STATUS="fail"
else
  AGENT_STATUS="ok"
fi

# ─── Tier 2 F: Retry budget on failure ──────────────────────────────────────
if [ "$AGENT_STATUS" = "fail" ]; then
  RETRY_INFO=$(bash "$SCRIPTS_DIR/state-helper.sh" get-retry-info "$TASK_ID" 2>/dev/null || echo "0:2")
  RETRY_COUNT="${RETRY_INFO%:*}"
  MAX_RETRIES="${RETRY_INFO#*:}"

  if [ -n "$RETRY_COUNT" ] && [ -n "$MAX_RETRIES" ] && [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
    bash "$SCRIPTS_DIR/state-helper.sh" increment-retry "$TASK_ID"
    NEW_COUNT=$((RETRY_COUNT + 1))

    # Pick fallback model (opus → sonnet → haiku)
    CUR_MODEL=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .model' \
                  "$SWARM_DIR/state/active-tasks.json" 2>/dev/null || echo "sonnet")
    case "$CUR_MODEL" in
      opus)   FALLBACK="sonnet" ;;
      sonnet) FALLBACK="haiku" ;;
      *)      FALLBACK="$CUR_MODEL" ;;
    esac

    bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
      "scope=$TASK_ID" "reason=Retry $NEW_COUNT/$MAX_RETRIES — falling back $CUR_MODEL→$FALLBACK" \
      2>/dev/null || true
    bash "$SCRIPTS_DIR/log-decision.sh" "task:$TASK_ID" \
      "Retry with model fallback" \
      "Round $NEW_COUNT/$MAX_RETRIES — switching from $CUR_MODEL to $FALLBACK" \
      2>/dev/null || true

    # Kill old tmux session and respawn (this script is the watcher; spawn a fresh one)
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    bash "$SCRIPTS_DIR/state-helper.sh" remove "$TASK_ID"
    bash "$SCRIPTS_DIR/spawn-agent.sh" "$PROJECT_DIR" "$TASK_ID" \
      "$SWARM_DIR/logs/${TMUX_SESSION}-prompt.md" \
      "$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .role // "builder"' \
          "$SWARM_DIR/state/active-tasks.json" 2>/dev/null || echo "builder")" \
      "$FALLBACK" "high" 2>&1 | tail -5 || true
    exit 0
  fi

  # Budget exhausted → mark failed for real and escalate
  bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" failed 2>/dev/null || true
  bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
    "scope=$TASK_ID" "reason=Retry budget exhausted ($RETRY_COUNT/$MAX_RETRIES) — needs human review" \
    2>/dev/null || true
  bash "$SCRIPTS_DIR/notify.sh" --milestone agent_done \
    "task=$TASK_ID" "project=$PROJECT_NAME" "status=fail" 2>/dev/null || true
  bash "$SCRIPTS_DIR/state-helper.sh" remove "$TASK_ID" 2>/dev/null || true
  echo "[watcher] Agent failed permanently; budget exhausted."
  exit 0
fi

bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" reviewing 2>/dev/null || true
bash "$SCRIPTS_DIR/notify.sh" --milestone agent_done \
  "task=$TASK_ID" "project=$PROJECT_NAME" "status=$AGENT_STATUS" 2>/dev/null || true

# ─── Auto-review (Tier 2 G: multi-reviewer with shared findings) ────────────
#
# Reviewers per round:
#   round 1: correctness reviewer (sonnet medium) → security reviewer (sonnet medium)
#   round 2: same pair, with previous round's findings as context
#   round 3+: senior reviewer (opus high) — only if rounds 1 and 2 found unresolved issues

FINDINGS_DIR="$SWARM_DIR/state/review-findings"
mkdir -p "$FINDINGS_DIR"
FINDINGS_FILE="$FINDINGS_DIR/${TASK_ID}.md"
: > "$FINDINGS_FILE"

_run_reviewer() {
  local persona="$1" model="$2" effort="$3" round="$4" review_out="$5"
  local persona_prompt
  case "$persona" in
    correctness)
      persona_prompt="You are the CORRECTNESS reviewer. Focus on bugs, logic errors, edge cases, missing error handling, off-by-one, null/empty handling, race conditions."
      ;;
    security)
      persona_prompt="You are the SECURITY reviewer. Focus on injection vulnerabilities, secret leakage, unsafe deserialization, privilege escalation, unsafe defaults, authn/authz."
      ;;
    senior)
      persona_prompt="You are the SENIOR reviewer (opus). Earlier rounds did not converge. Read prior findings, identify the root cause, and either fix it definitively or write a clear blocker explanation for human review."
      ;;
  esac

  local prior_findings=""
  if [ -s "$FINDINGS_FILE" ]; then
    prior_findings=$'\n\n## Prior round findings (build on these — do not repeat fixes already made)\n'
    prior_findings+="$(cat "$FINDINGS_FILE")"
  fi

  claude --model "$model" --effort "$effort" --permission-mode bypassPermissions --print \
    "$persona_prompt

You are reviewing branch $BRANCH of $PROJECT_NAME (round $round).

Files changed:
$DIFF
$prior_findings

For each issue you find:
- If it's safe and confined to this task's changes, fix it and commit with message 'review fix ($persona r$round)'
- If it requires changes outside the task scope or you're uncertain, write the issue under '## Unresolved' below

End your response with one of:
- LGTM (no issues found)
- FIXED (issues found and fixed)
- UNRESOLVED (issues remain — describe them)" 2>&1 | tee "$review_out"
}

for ROUND in $(seq 1 "$MAX_REVIEW_ROUNDS"); do
  echo "[watcher] 🔍 Review round $ROUND/$MAX_REVIEW_ROUNDS for $TASK_ID"
  bash "$SCRIPTS_DIR/notify.sh" --milestone review_fix \
    "task=$TASK_ID" "round=$ROUND" 2>/dev/null || true

  cd "$WORK_DIR"
  DIFF=$(git diff origin/main...HEAD --stat 2>/dev/null || echo "no diff")
  ROUND_FINDINGS=$(mktemp)

  if [ "$ROUND" -ge 3 ]; then
    # Senior escalation
    REVIEW_OUT=$(mktemp)
    _run_reviewer senior opus high "$ROUND" "$REVIEW_OUT"
    echo "## Round $ROUND — senior" >> "$FINDINGS_FILE"
    cat "$REVIEW_OUT" >> "$FINDINGS_FILE"
    if grep -qiE "LGTM|FIXED|no issues|all good" "$REVIEW_OUT"; then
      VERDICT="pass"
    else
      VERDICT="unresolved"
    fi
    rm -f "$REVIEW_OUT"
  else
    # Round 1 / 2: pair of specialized reviewers
    PASS_COUNT=0
    for PERSONA in correctness security; do
      REVIEW_OUT=$(mktemp)
      _run_reviewer "$PERSONA" sonnet medium "$ROUND" "$REVIEW_OUT"
      echo "## Round $ROUND — $PERSONA" >> "$FINDINGS_FILE"
      cat "$REVIEW_OUT" >> "$FINDINGS_FILE"
      echo "" >> "$FINDINGS_FILE"
      if grep -qiE "LGTM|FIXED|no issues|all good" "$REVIEW_OUT"; then
        PASS_COUNT=$((PASS_COUNT + 1))
      fi
      rm -f "$REVIEW_OUT"
    done
    if [ "$PASS_COUNT" -eq 2 ]; then VERDICT="pass"; else VERDICT="unresolved"; fi
  fi

  rm -f "$ROUND_FINDINGS"

  if [ "$VERDICT" = "pass" ]; then
    echo "[watcher] ✅ Review passed (round $ROUND)"
    bash "$SCRIPTS_DIR/notify.sh" --milestone review_pass \
      "task=$TASK_ID" "round=$ROUND" 2>/dev/null || true
    break
  fi

  echo "[watcher] Round $ROUND unresolved — continuing"
done

# If review didn't converge, log a decision and notify
LAST_VERDICT="${VERDICT:-unresolved}"
if [ "$LAST_VERDICT" != "pass" ]; then
  bash "$SCRIPTS_DIR/log-decision.sh" "task:$TASK_ID" \
    "Review did not converge after $MAX_REVIEW_ROUNDS rounds" \
    "See $FINDINGS_FILE for the full reviewer transcript." 2>/dev/null || true
fi

# ─── Push final state ───────────────────────────────────────────────────────

cd "$WORK_DIR"
git push origin "$BRANCH" --force-with-lease 2>/dev/null || git push origin "$BRANCH" 2>/dev/null || true

# ─── Mark done + prune ──────────────────────────────────────────────────────

bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" done 2>/dev/null || true
bash "$SCRIPTS_DIR/state-helper.sh" remove "$TASK_ID" 2>/dev/null || true

echo "[watcher] Done with $TASK_ID"
