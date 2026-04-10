#!/usr/bin/env bash
# Claude Swarm — Failure analyzer (Ralph Loop V2 phase 1)
#
# When an agent fails, this script captures the failure context, asks a
# Claude analyzer persona to either refine the prompt or escalate to human,
# and writes the result. Called from notify-on-complete.sh's retry path.
#
# Usage:
#   analyze-failure.sh <task-id> <project-dir> <original-prompt-file> <retry-round> <work-dir>
#
# Outputs (in order of preference):
#   /tmp/prompt-<task-id>-r<round>.md    ← refined prompt for the next attempt
#   /tmp/analyzer-verdict-<task-id>      ← "needs_human_review" + reason
#
# Always:
#   appends an entry to state/learnings.jsonl describing the analysis
#   prints the path to whatever output it produced (stdout)
#
# Exit codes:
#   0  refined prompt produced (use it for the retry)
#   1  needs human review (caller should escalate, not retry)
#   2  analyzer crashed (caller should fall back to original prompt)
set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SWARM_DIR/scripts"
LEARNINGS_HELPER="$SCRIPTS_DIR/learnings-helper.sh"

TASK_ID="${1:?Usage: analyze-failure.sh <task-id> <project-dir> <prompt-file> <retry-round> <work-dir>}"
PROJECT_DIR="${2:?Missing project-dir}"
ORIGINAL_PROMPT_FILE="${3:?Missing prompt file}"
RETRY_ROUND="${4:?Missing retry round}"
WORK_DIR="${5:?Missing work dir}"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
TMUX_SESSION="claude-${TASK_ID}"
LOG_FILE="$SWARM_DIR/logs/${TMUX_SESSION}.log"
WORKLOG_FILE="/tmp/worklog-${TMUX_SESSION}.md"

REFINED_PROMPT="/tmp/prompt-${TASK_ID}-r${RETRY_ROUND}.md"
VERDICT_FILE="/tmp/analyzer-verdict-${TASK_ID}"
ANALYSIS_FILE=$(mktemp /tmp/analyzer-out-XXXXXX.md)

# Clean any stale outputs from a prior round
rm -f "$REFINED_PROMPT" "$VERDICT_FILE"

echo "[analyzer] task=$TASK_ID round=$RETRY_ROUND project=$PROJECT_NAME" >&2

# ─── Capture failure context ────────────────────────────────────────────────

# Last 50 lines of the agent's log — actual stdout/stderr from the failed run
LOG_TAIL=""
if [ -f "$LOG_FILE" ]; then
  LOG_TAIL=$(tail -50 "$LOG_FILE" 2>/dev/null || echo "")
fi

# Original prompt the agent received
ORIGINAL_PROMPT_TEXT=""
if [ -f "$ORIGINAL_PROMPT_FILE" ]; then
  ORIGINAL_PROMPT_TEXT=$(cat "$ORIGINAL_PROMPT_FILE")
fi

# Agent's own worklog (what it tried, what it decided)
WORKLOG_TEXT=""
if [ -f "$WORKLOG_FILE" ]; then
  WORKLOG_TEXT=$(cat "$WORKLOG_FILE")
fi

# What the agent actually managed to commit (if any)
DIFF_STAT=""
if [ -d "$WORK_DIR/.git" ] || [ -d "$WORK_DIR" ]; then
  DIFF_STAT=$(cd "$WORK_DIR" 2>/dev/null && git diff origin/main...HEAD --stat 2>/dev/null || echo "(no diff available)")
fi

# Pick the first error-looking line for the signature
ERROR_LINE=$(echo "$LOG_TAIL" | grep -iE 'error|fail|exception|❌|denied|timeout|cannot|undefined|not found' | head -1 || echo "")
[ -z "$ERROR_LINE" ] && ERROR_LINE="(no obvious error line)"

SIGNATURE=$(bash "$LEARNINGS_HELPER" signature "$ERROR_LINE")
echo "[analyzer] signature=$SIGNATURE error_excerpt=${ERROR_LINE:0:120}" >&2

# ─── Look up prior similar incidents ────────────────────────────────────────

PRIOR_SIMILAR=""
if [ -x "$LEARNINGS_HELPER" ]; then
  PRIOR_SIMILAR=$(bash "$LEARNINGS_HELPER" find-similar "$SIGNATURE" 3 2>/dev/null || echo "")
fi
PRIOR_SUCCESSES=""
ROLE_GUESS="builder"
PRIOR_SUCCESSES=$(bash "$LEARNINGS_HELPER" find-successes-by-role "$ROLE_GUESS" 3 2>/dev/null || echo "")

# ─── Build the analyzer prompt ──────────────────────────────────────────────

ANALYZER_PROMPT_FILE=$(mktemp /tmp/analyzer-prompt-XXXXXX.md)
cat > "$ANALYZER_PROMPT_FILE" <<ANALYZER_EOF
You are the FAILURE ANALYZER for the claude-swarm system. An autonomous
coding agent just failed on a task. Your job is to read the failure context
and decide how to recover.

## Task that failed
- **Task ID:** $TASK_ID
- **Project:** $PROJECT_NAME
- **Project dir:** $PROJECT_DIR
- **Retry round:** $RETRY_ROUND (about to attempt next retry if you provide a refined prompt)
- **Worktree:** $WORK_DIR

## Original prompt the agent received

\`\`\`
$ORIGINAL_PROMPT_TEXT
\`\`\`

## Last 50 lines of the agent's runtime log

\`\`\`
$LOG_TAIL
\`\`\`

## Agent's own work log (what it tried, what it decided)

\`\`\`
$WORKLOG_TEXT
\`\`\`

## What the agent committed before failing (diff stat)

\`\`\`
$DIFF_STAT
\`\`\`

## Prior similar failures (same error signature)

\`\`\`
${PRIOR_SIMILAR:-(none)}
\`\`\`

## Prior successful $ROLE_GUESS tasks (for reference patterns)

\`\`\`
${PRIOR_SUCCESSES:-(none)}
\`\`\`

---

## Your job

Read everything above. Diagnose what went wrong. Then produce ONE of two outputs:

### Option A — REFINED PROMPT (preferred when the failure is recoverable)

If you can identify a concrete reason for the failure (missing context, wrong
file scope, missing dependency, ambiguous requirement, agent went the wrong
direction), produce a refined prompt that:

- Preserves the user's ORIGINAL GOAL exactly. Do not change what the agent is
  being asked to build.
- Adds the specific context, constraints, or scope adjustments the agent
  needed. Be concrete: file paths, exact behaviors, what NOT to touch.
- Keeps any sections of the original prompt that were working. Don't rewrite
  for the sake of rewriting.
- Is self-contained — the next agent has no memory of this analysis, only
  what's in the prompt.

Format your response as:

\`\`\`
DIAGNOSIS: <one-line root cause, will be saved to learnings>
REFINED_PROMPT:
<full refined prompt text — this will be saved verbatim and given to the
next agent. Markdown is fine. Include the work-log + when-done sections.>
\`\`\`

### Option B — NEEDS HUMAN REVIEW (when the failure isn't safely recoverable)

If the failure indicates a genuine ambiguity in the user's request, a missing
dependency the agent can't install, an environment problem, or a fundamental
disagreement about the goal — escalate. Don't try to "fix" things by rewriting
the prompt aggressively.

Format as:

\`\`\`
DIAGNOSIS: <one-line root cause>
ESCALATE:
<2-4 sentence explanation for the human, including: what the agent tried,
why it failed, and what the human needs to clarify or fix.>
\`\`\`

## Hard rules

- Never call spawn-batch.sh, spawn-agent.sh, or any swarm script. You only
  produce text. The orchestrator will use your refined prompt to retry.
- Never set SWARM_REQUIRE_APPROVAL=false in any environment.
- Don't refine the prompt to do more than the user asked. Refining = adding
  scope/context, not adding features.
- Be terse. Diagnoses are one line. Refined prompts are as short as the
  original (or shorter — strip dead context, add what's missing).
ANALYZER_EOF

# ─── Call claude --print as the analyzer ────────────────────────────────────
# Use sonnet to keep cost reasonable. The analyzer doesn't need opus depth;
# it just needs to read text and produce text.

if ! command -v claude &>/dev/null; then
  echo "[analyzer] claude CLI not found, falling back to original prompt" >&2
  exit 2
fi

if ! claude --model sonnet --permission-mode bypassPermissions --print \
    "$(cat "$ANALYZER_PROMPT_FILE")" \
    > "$ANALYSIS_FILE" 2>&1; then
  echo "[analyzer] claude invocation failed, falling back to original prompt" >&2
  rm -f "$ANALYZER_PROMPT_FILE"
  exit 2
fi
rm -f "$ANALYZER_PROMPT_FILE"

ANALYSIS=$(cat "$ANALYSIS_FILE")
rm -f "$ANALYSIS_FILE"

if [ -z "$ANALYSIS" ]; then
  echo "[analyzer] empty analyzer output, falling back" >&2
  exit 2
fi

# ─── Parse the analyzer's response ──────────────────────────────────────────

DIAGNOSIS=$(echo "$ANALYSIS" | grep -m1 -E '^DIAGNOSIS:' | sed -E 's/^DIAGNOSIS:[[:space:]]*//' || echo "")
[ -z "$DIAGNOSIS" ] && DIAGNOSIS="(analyzer did not provide a diagnosis)"

# Refined prompt block: everything from "REFINED_PROMPT:" to end-of-text
REFINED_BODY=$(echo "$ANALYSIS" | awk '/^REFINED_PROMPT:/{flag=1; next} flag' )

# Escalation block
ESCALATE_BODY=$(echo "$ANALYSIS" | awk '/^ESCALATE:/{flag=1; next} flag' )

_log_failure() {
  local verdict="$1" refined_sha="${2:-}"
  local entry
  entry=$(jq -cn \
    --arg ts "$(date -Iseconds)" \
    --arg task "$TASK_ID" \
    --arg project "$PROJECT_NAME" \
    --arg role "$ROLE_GUESS" \
    --argjson round "$RETRY_ROUND" \
    --arg sig "$SIGNATURE" \
    --arg err "${ERROR_LINE:0:200}" \
    --arg verdict "$verdict" \
    --arg diagnosis "$DIAGNOSIS" \
    --arg refined_sha "$refined_sha" \
    '{
       kind: "failure",
       ts: $ts,
       task_id: $task,
       project: $project,
       role: $role,
       retry_round: $round,
       signature: $sig,
       error_excerpt: $err,
       verdict: $verdict,
       diagnosis: $diagnosis,
       refined_prompt_sha: (if $refined_sha == "" then null else $refined_sha end)
     }')
  bash "$LEARNINGS_HELPER" append-failure "$entry" 2>/dev/null || true
}

if [ -n "$REFINED_BODY" ] && [ -z "$ESCALATE_BODY" ]; then
  printf '%s' "$REFINED_BODY" > "$REFINED_PROMPT"
  REFINED_SHA=$(sha1sum "$REFINED_PROMPT" | cut -c1-12)
  echo "[analyzer] ✅ refined prompt: $REFINED_PROMPT (sha=$REFINED_SHA)" >&2
  echo "[analyzer] diagnosis: $DIAGNOSIS" >&2
  _log_failure "refined" "$REFINED_SHA"
  echo "$REFINED_PROMPT"
  exit 0
fi

if [ -n "$ESCALATE_BODY" ]; then
  printf '%s' "$ESCALATE_BODY" > "$VERDICT_FILE"
  echo "[analyzer] ⛔ escalating: $VERDICT_FILE" >&2
  echo "[analyzer] diagnosis: $DIAGNOSIS" >&2
  _log_failure "needs_human_review" ""
  echo "$VERDICT_FILE"
  exit 1
fi

# Analyzer produced neither — fall back
echo "[analyzer] could not parse analyzer output, falling back to original prompt" >&2
echo "[analyzer] raw analysis (first 500 chars): ${ANALYSIS:0:500}" >&2
_log_failure "parse_failure" ""
exit 2
