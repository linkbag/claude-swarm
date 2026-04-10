#!/usr/bin/env bash
# Claude Swarm — Watch all agents in a batch, then auto-integrate
#
# Usage: integration-watcher.sh <project-dir> <batch-id> <tmux-sessions...>

set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

PROJECT_DIR="${1:?Missing project-dir}"
BATCH_ID="${2:?Missing batch-id}"
shift 2
SESSIONS=("$@")

POLL_INTERVAL=60
MAX_INTEGRATION_ROUNDS="${SWARM_MAX_REVIEW_ROUNDS:-3}"
BATCH_START_TS=$(date +%s)

echo "[integration] Watching ${#SESSIONS[@]} sessions: ${SESSIONS[*]}"

# ─── Wait for all agents to complete ────────────────────────────────────────

while true; do
  sleep "$POLL_INTERVAL"
  ALL_DONE=true

  for SESSION in "${SESSIONS[@]}"; do
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      LAST=$(tmux capture-pane -t "$SESSION" -p -S -10 2>/dev/null || echo "")
      if ! echo "$LAST" | grep -q "\[runner\] ✅\|\[runner\] ❌\|DONE"; then
        ALL_DONE=false
        break
      fi
    fi
  done

  if $ALL_DONE; then
    echo "[integration] All agents completed"
    break
  fi
done

PROJECT_NAME="$(basename "$PROJECT_DIR")"
bash "$SCRIPTS_DIR/notify.sh" --milestone integration_start \
  "batch=$BATCH_ID" "branches=${SESSIONS[*]}" 2>/dev/null || true

# ─── Collect branches ───────────────────────────────────────────────────────

cd "$PROJECT_DIR"
git fetch origin 2>/dev/null || true

BRANCHES=()
for SESSION in "${SESSIONS[@]}"; do
  TASK_ID="${SESSION#claude-}"
  BRANCH="feat/$TASK_ID"
  if git rev-parse "origin/$BRANCH" &>/dev/null; then
    BRANCHES+=("$BRANCH")
  fi
done

if [ ${#BRANCHES[@]} -eq 0 ]; then
  echo "[integration] No branches found to integrate"
  exit 0
fi

echo "[integration] Integrating ${#BRANCHES[@]} branches: ${BRANCHES[*]}"

# ─── Tier 2 H: Staged pair-wise compatibility test (only for ≥3 branches) ──
#
# Build state/integration-matrix-<batch>.json with which pairs cleanly merge.
# This catches "branch X conflicts with branch Y" before we touch main.
# Skipped for batches <3 since pair-wise on 2 == sequential merge.

if [ "${#BRANCHES[@]}" -ge 3 ]; then
  echo "[integration] Running pair-wise compatibility tests..."
  bash "$SCRIPTS_DIR/notify.sh" --milestone integration_start \
    "batch=$BATCH_ID" "branches=pair-wise testing ${#BRANCHES[@]} branches" 2>/dev/null || true

  MATRIX_FILE="$SWARM_DIR/state/integration-matrix-${BATCH_ID}.json"
  echo '{}' > "$MATRIX_FILE"
  CONFLICTS=()

  for i in $(seq 0 $((${#BRANCHES[@]} - 2))); do
    for j in $(seq $((i + 1)) $((${#BRANCHES[@]} - 1))); do
      A="${BRANCHES[$i]}"
      B="${BRANCHES[$j]}"
      TMP_BRANCH="swarm-pair-test/${BATCH_ID}-$i-$j"
      git checkout -B "$TMP_BRANCH" "origin/main" 2>/dev/null
      if git merge "origin/$A" --no-edit --no-ff 2>/dev/null && \
         git merge "origin/$B" --no-edit --no-ff 2>/dev/null; then
        STATUS="ok"
      else
        STATUS="conflict"
        CONFLICTS+=("$A↔$B")
        git merge --abort 2>/dev/null || true
      fi
      jq --arg pair "$A↔$B" --arg s "$STATUS" '. + {($pair): $s}' \
        "$MATRIX_FILE" > "${MATRIX_FILE}.tmp" && mv "${MATRIX_FILE}.tmp" "$MATRIX_FILE"
      git checkout main 2>/dev/null || true
      git branch -D "$TMP_BRANCH" 2>/dev/null || true
    done
  done

  if [ ${#CONFLICTS[@]} -gt 0 ]; then
    echo "[integration] ⚠️ Pair-wise conflicts detected: ${CONFLICTS[*]}"
    bash "$SCRIPTS_DIR/notify.sh" --milestone integration_fail \
      "batch=$BATCH_ID" "reason=Pair-wise conflicts: ${CONFLICTS[*]}" 2>/dev/null || true
    bash "$SCRIPTS_DIR/log-decision.sh" "batch:$BATCH_ID" \
      "Pair-wise integration test detected conflicts" \
      "Conflicting pairs: ${CONFLICTS[*]}. See $MATRIX_FILE for full matrix. Continuing with sequential merge — opus will resolve at merge time." \
      2>/dev/null || true
    # Continue anyway — sequential merge with opus conflict resolution will try
  else
    echo "[integration] ✅ All pairs compatible — proceeding"
  fi
fi

# ─── Merge branches sequentially ────────────────────────────────────────────

git checkout main 2>/dev/null || git checkout -b main origin/main
git pull origin main 2>/dev/null || true

MERGE_FAILURES=()
for BRANCH in "${BRANCHES[@]}"; do
  echo "[integration] Merging $BRANCH..."
  if git merge "origin/$BRANCH" --no-edit 2>/dev/null; then
    echo "[integration] ✅ $BRANCH merged cleanly"
  else
    echo "[integration] ⚠️ Conflict in $BRANCH — attempting auto-resolve..."
    
    # Use Claude to resolve conflicts
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
    if [ -n "$CONFLICTS" ]; then
      claude --model opus --effort high --permission-mode bypassPermissions --print \
        "Resolve the merge conflicts in these files: $CONFLICTS
         
         Keep the most complete version. For i18n files, combine both sets of translations.
         For code files, keep both features working.
         After resolving, run: git add . && git commit --no-edit" 2>/dev/null || {
        git merge --abort 2>/dev/null || true
        MERGE_FAILURES+=("$BRANCH")
        continue
      }
    fi
    echo "[integration] ✅ $BRANCH merged (conflicts resolved)"
  fi
done

# ─── Integration review ─────────────────────────────────────────────────────

for ROUND in $(seq 1 "$MAX_INTEGRATION_ROUNDS"); do
  echo "[integration] 🔍 Integration review round $ROUND/$MAX_INTEGRATION_ROUNDS"

  REVIEW=$(mktemp)
  DIFF_STAT=$(git diff origin/main...HEAD --stat 2>/dev/null || echo "no changes")

  claude --model opus --effort high --permission-mode bypassPermissions --print \
    "Integration review for batch $BATCH_ID.

Changes merged from ${#BRANCHES[@]} branches:
$DIFF_STAT

Check for:
1. Cross-branch conflicts or duplicate code
2. API contract mismatches between subteams
3. Import errors or missing dependencies
4. Build/compile issues (run build command if applicable)

If issues found, fix them and commit with 'integration fix (round $ROUND)'.
If all good, say 'INTEGRATION PASSED'." 2>&1 | tee "$REVIEW"

  if grep -qi "INTEGRATION PASSED\|PASSED\|LGTM\|all good\|no issues" "$REVIEW"; then
    echo "[integration] ✅ Integration review passed (round $ROUND)"
    bash "$SCRIPTS_DIR/notify.sh" --milestone integration_pass \
      "batch=$BATCH_ID" "round=$ROUND" 2>/dev/null || true
    rm -f "$REVIEW"
    break
  fi
  rm -f "$REVIEW"
done

# ─── Push to main ───────────────────────────────────────────────────────────

AUTO_MERGE="${SWARM_AUTO_MERGE:-true}"
SHIP_VIA_PR="${SWARM_SHIP_VIA_PR:-false}"

if [ "$SHIP_VIA_PR" = "true" ]; then
  # PR mode: push the integration branch (NOT main) and open a PR
  PR_BRANCH="swarm/integration/$BATCH_ID"
  echo "[integration] PR mode — creating $PR_BRANCH"

  # Move HEAD onto the PR branch (we already merged into main locally, but we
  # don't want to push that). Reset main back to origin/main and re-create the
  # work on a side branch.
  WORK_HEAD=$(git rev-parse HEAD)
  git reset --hard "origin/main" 2>/dev/null || true
  git checkout -B "$PR_BRANCH" "$WORK_HEAD" 2>/dev/null || git checkout "$WORK_HEAD" -B "$PR_BRANCH"

  if git push -u origin "$PR_BRANCH" --force-with-lease 2>/dev/null; then
    PR_BODY=$(cat <<PRBODY
Auto-generated by claude-swarm batch \`$BATCH_ID\`

**Project:** $PROJECT_NAME
**Branches merged:** ${BRANCHES[*]}

### Diff stat
\`\`\`
$(git diff origin/main...HEAD --stat 2>/dev/null | tail -50)
\`\`\`

🤖 Generated by claude-swarm
PRBODY
)
    if PR_URL=$(gh pr create --base main --head "$PR_BRANCH" \
        --title "swarm: batch $BATCH_ID ($PROJECT_NAME)" \
        --body "$PR_BODY" 2>&1); then
      echo "[integration] ✅ Opened PR: $PR_URL"
      bash "$SCRIPTS_DIR/notify.sh" --milestone ship \
        "batch=$BATCH_ID" "project=$PROJECT_NAME (PR opened)" 2>/dev/null || true
    else
      echo "[integration] ❌ gh pr create failed: $PR_URL"
      bash "$SCRIPTS_DIR/notify.sh" --milestone integration_fail \
        "batch=$BATCH_ID" "reason=gh pr create failed" 2>/dev/null || true
    fi
  else
    bash "$SCRIPTS_DIR/notify.sh" --milestone integration_fail \
      "batch=$BATCH_ID" "reason=PR branch push failed" 2>/dev/null || true
  fi
elif [ "$AUTO_MERGE" = "true" ]; then
  git push origin main 2>/dev/null && {
    echo "[integration] ✅ Pushed to main"
    bash "$SCRIPTS_DIR/notify.sh" --milestone ship \
      "batch=$BATCH_ID" "project=$PROJECT_NAME" 2>/dev/null || true
  } || {
    echo "[integration] ❌ Push failed"
    bash "$SCRIPTS_DIR/notify.sh" --milestone integration_fail \
      "batch=$BATCH_ID" "reason=push to main failed" 2>/dev/null || true
  }
else
  echo "[integration] Auto-merge disabled. Review and push manually."
fi

# ─── Report failures ────────────────────────────────────────────────────────

if [ ${#MERGE_FAILURES[@]} -gt 0 ]; then
  echo "[integration] ⚠️ Failed to merge: ${MERGE_FAILURES[*]}"
  bash "$SCRIPTS_DIR/notify.sh" --milestone integration_fail \
    "batch=$BATCH_ID" "reason=Merge failures: ${MERGE_FAILURES[*]}" 2>/dev/null || true
  bash "$SCRIPTS_DIR/log-decision.sh" "batch:$BATCH_ID" \
    "Merge failures during integration" \
    "Failed branches: ${MERGE_FAILURES[*]}" 2>/dev/null || true
fi

# ─── ESR + batch history ────────────────────────────────────────────────────

BATCH_END_TS=$(date +%s)
BATCH_DURATION=$((BATCH_END_TS - BATCH_START_TS))

if [ ${#MERGE_FAILURES[@]} -gt 0 ]; then
  FINAL_STATUS="partial"
elif [ ${#BRANCHES[@]} -eq 0 ]; then
  FINAL_STATUS="failed"
else
  FINAL_STATUS="shipped"
fi

bash "$SCRIPTS_DIR/append-esr.sh" "$BATCH_ID" "$PROJECT_NAME" "$FINAL_STATUS" \
  "${#BRANCHES[@]}" "$BATCH_DURATION" "Branches: ${BRANCHES[*]:-none}" \
  2>/dev/null || true

# Append to batch history (jsonl, one line per batch — used by metrics + bot)
HIST_FILE="$SWARM_DIR/state/batch-history.jsonl"
mkdir -p "$SWARM_DIR/state"
HIST_LINE=$(jq -cn \
  --arg id "$BATCH_ID" --arg project "$PROJECT_NAME" \
  --arg status "$FINAL_STATUS" --argjson tasks "${#BRANCHES[@]}" \
  --argjson dur "$BATCH_DURATION" \
  --arg started "$(date -Iseconds -d @$BATCH_START_TS 2>/dev/null || date -Iseconds)" \
  --arg finished "$(date -Iseconds)" \
  --arg branches "${BRANCHES[*]:-}" \
  --arg merge_fails "${MERGE_FAILURES[*]:-}" \
  '{batch_id: $id, project: $project, status: $status, task_count: $tasks,
    duration_sec: $dur, started: $started, finished: $finished,
    branches: $branches, merge_failures: $merge_fails}')
echo "$HIST_LINE" >> "$HIST_FILE"

# Aggregate worklogs (Tier 1 item C) before exiting
[ -x "$SCRIPTS_DIR/aggregate-worklogs.sh" ] && \
  bash "$SCRIPTS_DIR/aggregate-worklogs.sh" "$BATCH_ID" "${SESSIONS[@]}" 2>/dev/null || true
