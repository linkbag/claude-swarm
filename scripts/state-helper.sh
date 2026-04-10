#!/usr/bin/env bash
# Claude Swarm — Task state machine helpers
#
# Source this file or call functions directly:
#   bash state-helper.sh set-status <task-id> <status>
#   bash state-helper.sh get-status <task-id>
#   bash state-helper.sh count-by-status <status>
#   bash state-helper.sh add-task <task-id> <key=val ...>
#   bash state-helper.sh remove-task <task-id>
#   bash state-helper.sh list-by-status <status>
#
# Statuses: pending | endorsed | running | reviewing | done | failed | stuck
#
# Schema (active-tasks.json):
#   [{"id": "...", "tmux": "...", "branch": "...", "role": "...", "model": "...",
#     "project": "...", "started": "...", "status": "running",
#     "last_update": "...", "history": [{"at": "...", "status": "running"}]}]

set -uo pipefail

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_FILE="$SWARM_DIR/state/active-tasks.json"
mkdir -p "$SWARM_DIR/state"
[ -f "$TASKS_FILE" ] || echo '[]' > "$TASKS_FILE"

# File-lock to avoid concurrent jq read-modify-write races.
_lock_file="$SWARM_DIR/state/.tasks.lock"
_with_lock() {
  if command -v flock &>/dev/null; then
    (
      flock -w 5 9 || { echo "[state] lock timeout" >&2; exit 1; }
      "$@"
    ) 9>"$_lock_file"
  else
    "$@"
  fi
}

_jq_inplace() {
  local filter="$1"; shift
  jq "$@" "$filter" "$TASKS_FILE" > "${TASKS_FILE}.tmp" \
    && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
}

# task_set_status <task-id> <status>
_set_status() {
  local id="$1" status="$2"
  local now
  now=$(date -Iseconds)
  _jq_inplace \
    'map(if .id == $id then
            .status = $status
            | .last_update = $now
            | .history = ((.history // []) + [{at: $now, status: $status}])
          else . end)' \
    --arg id "$id" --arg status "$status" --arg now "$now"
}

# task_get_status <task-id> → status (or "" if not found)
_get_status() {
  jq -r --arg id "$1" \
    '.[] | select(.id == $id) | .status // "running"' "$TASKS_FILE"
}

# task_count_by_status <status>  → integer
_count_by_status() {
  jq -r --arg status "$1" \
    '[.[] | select((.status // "running") == $status)] | length' "$TASKS_FILE"
}

# task_list_by_status <status>  → newline-separated task IDs
_list_by_status() {
  jq -r --arg status "$1" \
    '.[] | select((.status // "running") == $status) | .id' "$TASKS_FILE"
}

# task_add <task-id> <k=v ...>
# Required keys: tmux branch role model project. Sets status=running, started=now.
# Optional: max_retries (default 2)
_add_task() {
  local id="$1"; shift
  local now tmux branch role model project effort max_retries
  now=$(date -Iseconds)
  max_retries="2"

  for kv in "$@"; do
    case "$kv" in
      tmux=*)        tmux="${kv#tmux=}" ;;
      branch=*)      branch="${kv#branch=}" ;;
      role=*)        role="${kv#role=}" ;;
      model=*)       model="${kv#model=}" ;;
      project=*)     project="${kv#project=}" ;;
      effort=*)      effort="${kv#effort=}" ;;
      max_retries=*) max_retries="${kv#max_retries=}" ;;
    esac
  done

  _jq_inplace \
    '. + [{
        id: $id, tmux: $tmux, branch: $branch, role: $role, model: $model,
        project: $project, effort: $effort, started: $now,
        status: "running", last_update: $now,
        retry_count: 0, max_retries: ($max_retries | tonumber),
        history: [{at: $now, status: "running"}]
      }]' \
    --arg id "$id" --arg tmux "${tmux:-}" --arg branch "${branch:-}" \
    --arg role "${role:-builder}" --arg model "${model:-sonnet}" \
    --arg project "${project:-}" --arg effort "${effort:-high}" \
    --arg now "$now" --arg max_retries "$max_retries"
}

# task_increment_retry <task-id>
_increment_retry() {
  local id="$1"
  local now
  now=$(date -Iseconds)
  _jq_inplace \
    'map(if .id == $id then
            .retry_count = ((.retry_count // 0) + 1)
            | .last_update = $now
            | .history = ((.history // []) + [{at: $now, status: ("retry-" + ((.retry_count // 0) | tostring))}])
          else . end)' \
    --arg id "$id" --arg now "$now"
}

# task_get_retry_info <task-id> → "<retry_count>:<max_retries>"
_get_retry_info() {
  jq -r --arg id "$1" \
    '.[] | select(.id == $id) | "\((.retry_count // 0)):\((.max_retries // 2))"' \
    "$TASKS_FILE"
}

# task_remove <task-id>
_remove_task() {
  local id="$1"
  _jq_inplace 'map(select(.id != $id))' --arg id "$id"
}

case "${1:-}" in
  set-status)      shift; _with_lock _set_status "$@" ;;
  get-status)      shift; _get_status "$@" ;;
  count-by-status) shift; _count_by_status "$@" ;;
  list-by-status)  shift; _list_by_status "$@" ;;
  add)             shift; _with_lock _add_task "$@" ;;
  remove)          shift; _with_lock _remove_task "$@" ;;
  increment-retry) shift; _with_lock _increment_retry "$@" ;;
  get-retry-info)  shift; _get_retry_info "$@" ;;
  *)
    cat <<USAGE >&2
Usage: state-helper.sh <command> [args...]
  set-status <task-id> <status>
  get-status <task-id>
  count-by-status <status>
  list-by-status <status>
  add <task-id> tmux=... branch=... role=... model=... project=... [effort=...] [max_retries=N]
  remove <task-id>
  increment-retry <task-id>
  get-retry-info <task-id>      → "<retry_count>:<max_retries>"

Statuses: pending endorsed running reviewing done failed stuck
USAGE
    exit 1
    ;;
esac
