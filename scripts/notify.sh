#!/usr/bin/env bash
# Claude Swarm — Send notification via webhook or telegram
#
# Two modes:
#   1. Raw:        notify.sh "message text"
#   2. Milestone:  notify.sh --milestone <type> [key=val ...]
#
# Milestone types (OpenClaw-style, formatted with emojis + structure):
#   plan              key: batch, count, project
#   spawn             key: batch, count, project
#   agent_start       key: task, project, role, model
#   agent_done        key: task, project, status (ok|fail)
#   review_pass       key: task, round
#   review_fix        key: task, round
#   integration_start key: batch, branches
#   integration_pass  key: batch, round
#   integration_fail  key: batch, reason
#   ship              key: batch, project
#   fail              key: scope, reason
#
# Resilience:
#   - 3 curl attempts with exponential backoff (1s, 3s, 9s)
#   - Dedupe via SHA1 of last message in /tmp/.swarm-notify-last
#   - All sends logged to logs/notifications.log
set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Preserve any env-set overrides BEFORE sourcing the conf, so callers can do
# `SWARM_NOTIFY=none bash notify.sh ...` for testing or one-off sends.
# Precedence: env > swarm.conf > defaults.
_env_NOTIFY="${SWARM_NOTIFY-}"
_env_WEBHOOK="${SWARM_WEBHOOK_URL-}"
_env_TG_TOKEN="${SWARM_TELEGRAM_BOT_TOKEN-}"
_env_TG_CHAT="${SWARM_TELEGRAM_CHAT_ID-}"

[ -f "$SWARM_DIR/config/swarm.conf" ] && source "$SWARM_DIR/config/swarm.conf"

[ -n "$_env_NOTIFY" ]   && SWARM_NOTIFY="$_env_NOTIFY"
[ -n "$_env_WEBHOOK" ]  && SWARM_WEBHOOK_URL="$_env_WEBHOOK"
[ -n "$_env_TG_TOKEN" ] && SWARM_TELEGRAM_BOT_TOKEN="$_env_TG_TOKEN"
[ -n "$_env_TG_CHAT" ]  && SWARM_TELEGRAM_CHAT_ID="$_env_TG_CHAT"

NOTIFY="${SWARM_NOTIFY:-none}"
DEDUPE_FILE="/tmp/.swarm-notify-last"
LOG_FILE="$SWARM_DIR/logs/notifications.log"
mkdir -p "$SWARM_DIR/logs"

# ─── Helpers ────────────────────────────────────────────────────────────────

# Parse key=value args into associative array entries (echo'd as key|value)
_parse_kv() {
  for arg in "$@"; do
    if [[ "$arg" == *=* ]]; then
      printf '%s\n' "$arg"
    fi
  done
}

# Get value for a key from key=value args (default to empty)
_kv_get() {
  local key="$1"; shift
  for arg in "$@"; do
    if [[ "$arg" == "${key}="* ]]; then
      printf '%s' "${arg#${key}=}"
      return 0
    fi
  done
  printf ''
}

# Render a milestone type into a formatted message
_render_milestone() {
  local type="$1"; shift
  local batch task project role model count round status branches reason scope

  batch=$(_kv_get batch "$@")
  task=$(_kv_get task "$@")
  project=$(_kv_get project "$@")
  role=$(_kv_get role "$@")
  model=$(_kv_get model "$@")
  count=$(_kv_get count "$@")
  round=$(_kv_get round "$@")
  status=$(_kv_get status "$@")
  branches=$(_kv_get branches "$@")
  reason=$(_kv_get reason "$@")
  scope=$(_kv_get scope "$@")

  case "$type" in
    plan)
      printf '🎯 *Plan*  `%s`\n📦 %s · %s tasks queued' "${batch:-?}" "${project:-?}" "${count:-?}"
      ;;
    spawn)
      printf '🚀 *Spawning batch*  `%s`\n📦 %s · %s subteams' "${batch:-?}" "${project:-?}" "${count:-?}"
      ;;
    agent_start)
      printf '👷 *Agent started*  `%s`\n📦 %s · %s/%s' "${task:-?}" "${project:-?}" "${role:-builder}" "${model:-sonnet}"
      ;;
    agent_done)
      if [ "$status" = "fail" ]; then
        printf '❌ *Agent failed*  `%s`\n📦 %s' "${task:-?}" "${project:-?}"
      else
        printf '✨ *Agent complete*  `%s`\n📦 %s' "${task:-?}" "${project:-?}"
      fi
      ;;
    review_pass)
      printf '✅ *Review passed*  `%s` (round %s)' "${task:-?}" "${round:-1}"
      ;;
    review_fix)
      printf '🔧 *Review fix*  `%s` (round %s)' "${task:-?}" "${round:-1}"
      ;;
    integration_start)
      printf '🔗 *Integration starting*  `%s`\n🌿 Branches: %s' "${batch:-?}" "${branches:-?}"
      ;;
    integration_pass)
      printf '✅ *Integration passed*  `%s` (round %s)' "${batch:-?}" "${round:-1}"
      ;;
    integration_fail)
      printf '⚠️ *Integration issue*  `%s`\n%s' "${batch:-?}" "${reason:-unknown}"
      ;;
    ship)
      printf '🚢 *Shipped*  `%s` → main\n📦 %s' "${batch:-?}" "${project:-?}"
      ;;
    endorse_required)
      printf '🛂 *Approval needed*  `%s`\n📦 %s · %s tasks pending\n\nApprove: `/swarm approve %s`\nReject:  `/swarm reject %s`' \
        "${batch:-?}" "${project:-?}" "${count:-?}" "${batch:-?}" "${batch:-?}"
      ;;
    fail)
      printf '🛑 *Failure*  %s\n%s' "${scope:-swarm}" "${reason:-unknown}"
      ;;
    *)
      printf '%s' "$type"
      ;;
  esac
}

# Send via the configured channel, with retry. Returns 0 on success.
_send() {
  local msg="$1"
  local attempt
  local delays=(1 3 9)

  case "$NOTIFY" in
    webhook)
      [ -z "${SWARM_WEBHOOK_URL:-}" ] && return 0
      for attempt in 0 1 2; do
        if curl -fsS -X POST "$SWARM_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\": $(printf '%s' "$msg" | jq -Rs .)}" >/dev/null 2>&1; then
          return 0
        fi
        sleep "${delays[$attempt]}"
      done
      return 1
      ;;
    telegram)
      [ -z "${SWARM_TELEGRAM_BOT_TOKEN:-}" ] && return 0
      [ -z "${SWARM_TELEGRAM_CHAT_ID:-}" ] && return 0
      for attempt in 0 1 2; do
        # Capture the response so we can extract the message_id for threading.
        local resp
        resp=$(curl -fsS "https://api.telegram.org/bot${SWARM_TELEGRAM_BOT_TOKEN}/sendMessage" \
          --data-urlencode "chat_id=${SWARM_TELEGRAM_CHAT_ID}" \
          --data-urlencode "text=${msg}" \
          --data-urlencode "parse_mode=Markdown" \
          --data-urlencode "disable_web_page_preview=true" 2>/dev/null) && {
          # Tier 3 M: record message_id → task_id mapping for /reply threading
          if [ -n "${SWARM_NOTIFY_TASK_ID:-}" ] && command -v jq &>/dev/null; then
            local mid
            mid=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
            if [ -n "$mid" ]; then
              local map_file="$SWARM_DIR/state/message-task-map.json"
              [ -f "$map_file" ] || echo '{}' > "$map_file"
              jq --arg mid "$mid" --arg tid "$SWARM_NOTIFY_TASK_ID" \
                '. + {($mid): $tid}' "$map_file" \
                > "${map_file}.tmp" && mv "${map_file}.tmp" "$map_file"
            fi
          fi
          return 0
        }
        sleep "${delays[$attempt]}"
      done
      return 1
      ;;
    none|"")
      echo "[notify] $msg"
      return 0
      ;;
  esac
}

# ─── Main ───────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--milestone" ]; then
  shift
  TYPE="${1:?Usage: notify.sh --milestone <type> [key=val ...]}"
  shift
  MSG="$(_render_milestone "$TYPE" "$@")"
else
  MSG="${1:?Usage: notify.sh <message>  |  notify.sh --milestone <type> [key=val ...]}"
fi

# Dedupe: skip if identical to last message within last 30s
if command -v sha1sum &>/dev/null; then
  HASH=$(printf '%s' "$MSG" | sha1sum | cut -d' ' -f1)
  if [ -f "$DEDUPE_FILE" ]; then
    LAST_HASH=$(head -1 "$DEDUPE_FILE" 2>/dev/null || echo "")
    LAST_TS=$(sed -n '2p' "$DEDUPE_FILE" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    if [ "$HASH" = "$LAST_HASH" ] && [ $((NOW - LAST_TS)) -lt 30 ]; then
      echo "[$(date -Iseconds)] [dedupe] $MSG" >> "$LOG_FILE"
      exit 0
    fi
  fi
  printf '%s\n%s\n' "$HASH" "$(date +%s)" > "$DEDUPE_FILE"
fi

# Send (with retry). Always log, regardless of channel success.
if _send "$MSG"; then
  echo "[$(date -Iseconds)] $MSG" >> "$LOG_FILE"
else
  echo "[$(date -Iseconds)] [send-failed] $MSG" >> "$LOG_FILE"
fi
