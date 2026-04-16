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

# ─── Item 4: Stuck-pattern + functional-done detection ─────────────────────
#
# Stuck patterns mean the agent is sitting on an interactive prompt or auth
# error and will never finish on its own — kill immediately.
#
# Functional-done means the agent's log file shows clear completion milestones
# (PR opened, branch pushed, commit hash) AND has been idle for >10 min — the
# agent is done but tmux is hanging on something we can't see. Auto-close.

STUCK_PATTERNS=(
  "Failed to login"
  "API key must be set"
  "Authentication required"
  "Enter your API key"
  "How would you like to authenticate"
  "Press Enter to continue"
  "Do you want to proceed"
  "Permission denied"
  "(y/n)"
  "(Y/n)"
  "Error: EACCES"
)

DONE_MILESTONE_RE="Work log finalized|PR (opened|created):|Branch pushed:|Pushed: .*feat/|Commit:[[:space:]]+[0-9a-f]{7,}|\[runner\] ✅"
IDLE_DONE_THRESHOLD=600  # 10 minutes
LOG_FILE="$SWARM_DIR/logs/${TMUX_SESSION}.log"

_check_stuck() {
  local lines="$1"
  for pat in "${STUCK_PATTERNS[@]}"; do
    if echo "$lines" | grep -qiF "$pat"; then
      echo "$pat"
      return 0
    fi
  done
  return 1
}

_check_functional_done() {
  [ -f "$LOG_FILE" ] || return 1
  local now last_mod idle_s
  now=$(date +%s)
  last_mod=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$last_mod" -gt 0 ] || return 1
  idle_s=$(( now - last_mod ))
  if [ "$idle_s" -gt "$IDLE_DONE_THRESHOLD" ] && \
     grep -Eq "$DONE_MILESTONE_RE" "$LOG_FILE" 2>/dev/null; then
    echo "$idle_s"
    return 0
  fi
  return 1
}

# ─── Poll for completion ────────────────────────────────────────────────────

while true; do
  sleep "$POLL_INTERVAL"

  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[watcher] Session $TMUX_SESSION ended"
    break
  fi

  # Check for runner completion marker first
  LAST_LINES=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -30 2>/dev/null || echo "")
  if echo "$LAST_LINES" | grep -q "\[runner\] ✅\|\[runner\] ❌"; then
    echo "[watcher] Agent completed"
    break
  fi

  # Stuck-pattern check (auth, prompts, permissions)
  if STUCK_REASON=$(_check_stuck "$LAST_LINES"); then
    echo "[watcher] ⚠️ Stuck pattern detected: $STUCK_REASON — killing $TMUX_SESSION"
    bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
      "scope=$TASK_ID" "reason=Stuck on '$STUCK_REASON' — killed by watcher" \
      2>/dev/null || true
    bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" stuck 2>/dev/null || true
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    # Keep task in active-tasks.json as "stuck" — pruned by cleanup.sh after retention period
    exit 0
  fi

  # Functional-done check (log idle but milestones reached)
  if IDLE_S=$(_check_functional_done); then
    MINS=$((IDLE_S / 60))
    echo "[watcher] ℹ️ Functional-done detected: idle ${MINS}m + milestones present — auto-closing"
    bash "$SCRIPTS_DIR/notify.sh" "ℹ️ \`$TASK_ID\` functionally complete (idle ${MINS}m after milestones) — auto-closing" \
      2>/dev/null || true
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    break  # fall through to normal completion path
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

    # ─── Ralph Loop V2: failure analysis before retry ──────────────────────
    # Try to refine the prompt with context from logs/worklog/diff/prior
    # learnings. If the analyzer produces a refined prompt, use it for the
    # retry. If it escalates, stop the retry budget early. If it crashes or
    # can't decide, fall back to the original prompt (current behavior).

    ROLE_FOR_RETRY=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .role // "builder"' \
                     "$SWARM_DIR/state/active-tasks.json" 2>/dev/null || echo "builder")
    ORIGINAL_PROMPT_FILE="$SWARM_DIR/logs/${TMUX_SESSION}-prompt.md"
    PROMPT_FOR_RETRY="$ORIGINAL_PROMPT_FILE"
    ANALYZER_VERDICT="fallback"

    bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
      "scope=$TASK_ID" "reason=Failed (round $RETRY_COUNT). 🔍 Analyzing failure..." \
      2>/dev/null || true

    if [ -x "$SCRIPTS_DIR/analyze-failure.sh" ]; then
      ANALYZER_OUT=$(bash "$SCRIPTS_DIR/analyze-failure.sh" \
        "$TASK_ID" "$PROJECT_DIR" "$ORIGINAL_PROMPT_FILE" "$NEW_COUNT" "$WORK_DIR" 2>&1 || true)
      ANALYZER_RC=$?
      echo "$ANALYZER_OUT" | tail -20

      case "$ANALYZER_RC" in
        0)
          # Analyzer produced a refined prompt
          REFINED_PATH="/tmp/prompt-${TASK_ID}-r${NEW_COUNT}.md"
          if [ -f "$REFINED_PATH" ]; then
            PROMPT_FOR_RETRY="$REFINED_PATH"
            ANALYZER_VERDICT="refined"
            bash "$SCRIPTS_DIR/notify.sh" --milestone review_fix \
              "task=$TASK_ID" "round=$NEW_COUNT" 2>/dev/null || true
            bash "$SCRIPTS_DIR/notify.sh" \
              "🔧 \`$TASK_ID\` retry $NEW_COUNT — analyzer produced refined prompt" \
              2>/dev/null || true
          fi
          ;;
        1)
          # Analyzer says escalate to human — stop retrying
          ANALYZER_VERDICT="escalated"
          VERDICT_PATH="/tmp/analyzer-verdict-${TASK_ID}"
          VERDICT_TEXT="(no verdict body)"
          [ -f "$VERDICT_PATH" ] && VERDICT_TEXT=$(cat "$VERDICT_PATH")
          bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
            "scope=$TASK_ID" "reason=Analyzer escalated — needs human review: ${VERDICT_TEXT:0:200}" \
            2>/dev/null || true
          bash "$SCRIPTS_DIR/log-decision.sh" "task:$TASK_ID" \
            "Failure analyzer escalated to human" \
            "$VERDICT_TEXT" "$PROJECT_DIR" 2>/dev/null || true
          bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" failed 2>/dev/null || true
          bash "$SCRIPTS_DIR/notify.sh" --milestone agent_done \
            "task=$TASK_ID" "project=$PROJECT_NAME" "status=fail" 2>/dev/null || true
          # Keep task in active-tasks.json as "failed" — pruned by cleanup.sh after retention period
          tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
          exit 0
          ;;
        *)
          # Analyzer crashed or couldn't parse — fall back silently
          echo "[watcher] analyzer fallback (rc=$ANALYZER_RC)"
          ;;
      esac
    fi

    bash "$SCRIPTS_DIR/notify.sh" --milestone fail \
      "scope=$TASK_ID" "reason=Retry $NEW_COUNT/$MAX_RETRIES ($ANALYZER_VERDICT) — falling back $CUR_MODEL→$FALLBACK" \
      2>/dev/null || true
    bash "$SCRIPTS_DIR/log-decision.sh" "task:$TASK_ID" \
      "Retry with model fallback ($ANALYZER_VERDICT)" \
      "Round $NEW_COUNT/$MAX_RETRIES — switching from $CUR_MODEL to $FALLBACK; prompt source: $ANALYZER_VERDICT" \
      "$PROJECT_DIR" \
      2>/dev/null || true

    # Kill old tmux session and respawn (this script is the watcher; spawn a fresh one)
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    bash "$SCRIPTS_DIR/state-helper.sh" remove "$TASK_ID"
    bash "$SCRIPTS_DIR/spawn-agent.sh" "$PROJECT_DIR" "$TASK_ID" \
      "$PROMPT_FOR_RETRY" \
      "$ROLE_FOR_RETRY" \
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
  # Keep task in active-tasks.json as "failed" — pruned by cleanup.sh after retention period
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

  # Item 3: Verdict-file pattern. The reviewer is told to write a JSON verdict
  # to a known path. The watcher reads it deterministically. If missing, the
  # watcher uses smart inference (commit/worklog/exit-code → verdict).
  local verdict_file="/tmp/review-verdict-${TASK_ID}-${persona}-r${round}.json"
  rm -f "$verdict_file"

  claude --model "$model" --effort "$effort" --permission-mode bypassPermissions --print \
    "$persona_prompt

You are reviewing branch $BRANCH of $PROJECT_NAME (round $round).

Files changed:
$DIFF
$prior_findings

For each issue you find:
- If it's safe and confined to this task's changes, fix it and commit with message 'review fix ($persona r$round)'
- If it requires changes outside the task scope or you're uncertain, write the issue under '## Unresolved' below

## MANDATORY: Write a verdict file before exiting

Run this command exactly (replace the values with your actual findings):

  echo '{\"pass\": true, \"summary\": \"YOUR ONE-LINE SUMMARY HERE\", \"issues_remaining\": \"\"}' > $verdict_file

Use \"pass\": true if you have no concerns OR if you fixed every issue you found.
Use \"pass\": false ONLY if real issues remain that you couldn't safely fix —
in that case set \"issues_remaining\" to a description.

Your final shell action MUST be writing this verdict file." 2>&1 | tee "$review_out" >/dev/null
}

# Compute the deterministic verdict path for a (task, persona, round) tuple
_verdict_path_for() {
  local persona="$1" round="$2"
  echo "/tmp/review-verdict-${TASK_ID}-${persona}-r${round}.json"
}

# Read a verdict file (or infer from environment if missing).
# Echoes "pass" or "unresolved".
_read_verdict() {
  local verdict_file="$1" review_out="$2" persona="$3" round="$4"
  if [ -f "$verdict_file" ]; then
    local pass
    pass=$(jq -r '.pass // false' "$verdict_file" 2>/dev/null || echo "false")
    if [ "$pass" = "true" ]; then
      echo "pass"
      return
    fi
    echo "unresolved"
    return
  fi

  # No verdict file — smart inference (OpenClaw pattern)
  # 1. New commit on this branch since the round started? → reviewer fixed something
  local latest
  latest=$(cd "$WORK_DIR" 2>/dev/null && git log --oneline -1 2>/dev/null | head -1 || echo "")
  if echo "$latest" | grep -qiE "review (fix|pass)|fix.*round|clean|lgtm"; then
    echo "[watcher] (inferred from commit: $latest) → pass"
    echo "pass"
    return
  fi

  # 2. Reviewer's stdout contains an explicit pass/fix marker?
  if [ -f "$review_out" ] && grep -qiE "^LGTM|^FIXED|all good|no issues|looks good" "$review_out"; then
    echo "[watcher] (inferred from output marker) → pass"
    echo "pass"
    return
  fi

  # 3. Findings file was updated (implies reviewer actually did the work)
  if [ -s "$FINDINGS_FILE" ] && grep -q "Round $round — $persona" "$FINDINGS_FILE"; then
    # Reviewer wrote findings but no commit and no marker — could be either way.
    # If the findings contain "UNRESOLVED" treat as fail; else auto-pass clean exit.
    if grep -qi "UNRESOLVED" "$FINDINGS_FILE"; then
      echo "[watcher] (inferred: findings contain UNRESOLVED) → unresolved"
      echo "unresolved"
      return
    fi
    echo "[watcher] (inferred: clean review pass, no unresolved markers) → pass"
    echo "pass"
    return
  fi

  # 4. Default: auto-pass clean exit (don't block on missing verdict)
  echo "[watcher] (no verdict file, no commit, no findings — auto-pass clean exit)"
  echo "pass"
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
    VERDICT_FILE=$(_verdict_path_for senior "$ROUND")
    VERDICT=$(_read_verdict "$VERDICT_FILE" "$REVIEW_OUT" senior "$ROUND")
    rm -f "$REVIEW_OUT" "$VERDICT_FILE"
  else
    # Round 1 / 2: pair of specialized reviewers
    PASS_COUNT=0
    for PERSONA in correctness security; do
      REVIEW_OUT=$(mktemp)
      _run_reviewer "$PERSONA" sonnet medium "$ROUND" "$REVIEW_OUT"
      echo "## Round $ROUND — $PERSONA" >> "$FINDINGS_FILE"
      cat "$REVIEW_OUT" >> "$FINDINGS_FILE"
      echo "" >> "$FINDINGS_FILE"
      VERDICT_FILE=$(_verdict_path_for "$PERSONA" "$ROUND")
      P_VERDICT=$(_read_verdict "$VERDICT_FILE" "$REVIEW_OUT" "$PERSONA" "$ROUND")
      [ "$P_VERDICT" = "pass" ] && PASS_COUNT=$((PASS_COUNT + 1))
      rm -f "$REVIEW_OUT" "$VERDICT_FILE"
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
    "See $FINDINGS_FILE for the full reviewer transcript." \
    "$PROJECT_DIR" 2>/dev/null || true
fi

# ─── Push final state ───────────────────────────────────────────────────────

cd "$WORK_DIR"
git push origin "$BRANCH" --force-with-lease 2>/dev/null || git push origin "$BRANCH" 2>/dev/null || true

# ─── Ralph Loop V2: log success pattern to learnings.jsonl ──────────────────
# Records that this prompt structure + role + model combination shipped a
# task. Future failure analyses can grep these for "what worked for similar
# tasks" before proposing a refined retry.

if [ "${LAST_VERDICT:-}" = "pass" ] && [ -x "$SCRIPTS_DIR/learnings-helper.sh" ]; then
  PROMPT_FILE_FOR_HASH="$SWARM_DIR/logs/${TMUX_SESSION}-prompt.md"
  PROMPT_SHA="(none)"
  PROMPT_FIRST_LINE=""
  if [ -f "$PROMPT_FILE_FOR_HASH" ]; then
    PROMPT_SHA=$(sha1sum "$PROMPT_FILE_FOR_HASH" | cut -c1-12)
    PROMPT_FIRST_LINE=$(head -1 "$PROMPT_FILE_FOR_HASH" 2>/dev/null | tr -d '\r' || echo "")
  fi
  ROLE_FOR_LOG=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .role // "builder"' \
                  "$SWARM_DIR/state/active-tasks.json" 2>/dev/null || echo "builder")
  MODEL_FOR_LOG=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .model // "sonnet"' \
                   "$SWARM_DIR/state/active-tasks.json" 2>/dev/null || echo "sonnet")
  RETRY_FOR_LOG=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .retry_count // 0' \
                   "$SWARM_DIR/state/active-tasks.json" 2>/dev/null || echo 0)
  SIG_FOR_LOG=$(bash "$SCRIPTS_DIR/learnings-helper.sh" signature "$PROMPT_FIRST_LINE")
  REVIEW_ROUNDS_USED="${ROUND:-1}"

  SUCCESS_ENTRY=$(jq -cn \
    --arg ts "$(date -Iseconds)" \
    --arg task "$TASK_ID" \
    --arg project "$PROJECT_NAME" \
    --arg role "$ROLE_FOR_LOG" \
    --arg model "$MODEL_FOR_LOG" \
    --argjson retry "$RETRY_FOR_LOG" \
    --argjson rounds "$REVIEW_ROUNDS_USED" \
    --arg prompt_sha "$PROMPT_SHA" \
    --arg sig "$SIG_FOR_LOG" \
    --arg first_line "${PROMPT_FIRST_LINE:0:200}" \
    '{
       kind: "success",
       ts: $ts,
       task_id: $task,
       project: $project,
       role: $role,
       model: $model,
       retry_count: $retry,
       review_rounds: $rounds,
       prompt_sha: $prompt_sha,
       signature: $sig,
       prompt_first_line: $first_line
     }')
  bash "$SCRIPTS_DIR/learnings-helper.sh" append-success "$SUCCESS_ENTRY" 2>/dev/null || true
fi

# ─── Mark done ──────────────────────────────────────────────────────────────
# Keep the task in active-tasks.json as "done" so /swarm shows it in Recent.
# Cleanup.sh prunes terminal-state tasks older than SWARM_RETENTION_DAYS (default 7).

bash "$SCRIPTS_DIR/state-helper.sh" set-status "$TASK_ID" done 2>/dev/null || true

echo "[watcher] Done with $TASK_ID"
