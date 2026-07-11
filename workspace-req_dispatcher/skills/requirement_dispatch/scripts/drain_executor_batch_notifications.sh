#!/usr/bin/env bash
# Retry undelivered per-Issue batch notifications without holding LOCK_FILE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

DEFAULT_NOTIFY_USER_SCRIPT="${SCRIPT_DIR}/notify_user.sh"
NOTIFY_USER_SCRIPT="${NOTIFY_USER_SCRIPT:-${DEFAULT_NOTIFY_USER_SCRIPT}}"

drain_die() {
  echo "drain_executor_batch_notifications.sh: $1" >&2
  exit "${2:-2}"
}

load_notifications_locked() {
  jq -ce '
    def printable:
      type == "string"
      and length > 0
      and (explode | all(. >= 32 and . != 127));
    def valid_origin:
      . == null
      or (type == "object"
        and ((keys - [
          "channel","conversation","reply_agent","source_agent",
          "source_session","user"
        ]) | length == 0)
        and all(to_entries[]; .value | printable));
    if type == "object"
      and (.notifications | type == "array")
      and all(.notifications[];
        type == "object"
        and (keys | sort) == [
          "attempts","delivered_at","event_id","iid","mr_url","origin",
          "project","reason","status"
        ]
        and (.event_id | printable)
        and (.origin | valid_origin)
        and (.project | printable)
        and (.iid | type == "number" and . == floor and . > 0)
        and (.status == "done" or .status == "failed"
          or .status == "timeout" or .status == "skipped")
        and ((.mr_url == null) or (.mr_url | type == "string"))
        and ((.reason == null) or (.reason | type == "string"))
        and (.attempts | type == "number" and . == floor and . >= 0)
        and ((.delivered_at == null) or (.delivered_at | printable))
      )
    then .
    else error("invalid executor batch notifications")
    end
  ' "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" 2>/dev/null \
    || drain_die "executor batch notifications are invalid" 3
}

publish_notifications_locked() {
  local json="$1"
  local candidate
  candidate="$(mktemp "${DISPATCHER_DIR}/.executor_batch_notifications.json.XXXXXX")"
  printf '%s\n' "${json}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null \
    || drain_die "refusing to publish invalid executor batch notifications" 3
  mv "${candidate}" "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}"
}

exec 9>"${LOCK_FILE}"
flock 9
notifications_json="$(load_notifications_locked)"
SCANNED_COUNT="$(jq -r '.notifications | length' <<<"${notifications_json}")"
pending_event_ids="$(jq -r '.notifications[] | select(.delivered_at == null) | .event_id' \
  <<<"${notifications_json}")"
flock -u 9

ATTEMPTED_COUNT=0
DELIVERED_COUNT=0
FAILED_COUNT=0

while IFS= read -r event_id; do
  [ -n "${event_id}" ] || continue

  read -r event_lock_crc event_lock_length _event_lock_name \
    < <(printf '%s' "${event_id}" | cksum)
  event_lock_file="${DISPATCHER_DIR}/executor_batch_notification.${event_lock_crc}.${event_lock_length}.lock"
  exec {event_lock_fd}>"${event_lock_file}"
  if ! flock -n "${event_lock_fd}"; then
    exec {event_lock_fd}>&-
    continue
  fi

  # Re-read and increment attempts under the shared lock. The resulting item
  # is an immutable snapshot for this one lock-free notify call.
  flock 9
  notifications_json="$(load_notifications_locked)"
  match_count="$(jq -r --arg event_id "${event_id}" \
    '[.notifications[] | select(.event_id == $event_id)] | length' \
    <<<"${notifications_json}")"
  [ "${match_count}" -eq 1 ] \
    || drain_die "notification event_id is missing or duplicated: ${event_id}" 3

  if [ "$(jq -r --arg event_id "${event_id}" \
    '.notifications[] | select(.event_id == $event_id) | .delivered_at != null' \
    <<<"${notifications_json}")" = true ]; then
    flock -u 9
    flock -u "${event_lock_fd}"
    exec {event_lock_fd}>&-
    continue
  fi

  next_notifications="$(jq -c --arg event_id "${event_id}" '
    .notifications |= map(
      if .event_id == $event_id then .attempts += 1 else . end
    )
  ' <<<"${notifications_json}")"
  publish_notifications_locked "${next_notifications}"
  notification_item="$(jq -c --arg event_id "${event_id}" \
    '.notifications[] | select(.event_id == $event_id)' \
    <<<"${next_notifications}")"
  flock -u 9

  ATTEMPTED_COUNT=$((ATTEMPTED_COUNT + 1))
  status="$(jq -r '.status' <<<"${notification_item}")"
  project="$(jq -r '.project' <<<"${notification_item}")"
  iid="$(jq -r '.iid' <<<"${notification_item}")"
  mr_url="$(jq -r '.mr_url // ""' <<<"${notification_item}")"
  reason="$(jq -r '.reason // ""' <<<"${notification_item}")"
  origin_json="$(jq -c '.origin' <<<"${notification_item}")"

  use_durable_notify_outcome=0
  notify_state_root=""
  notify_log_file=""
  notify_log_before=0
  if [ "${NOTIFY_USER_SCRIPT}" = "${DEFAULT_NOTIFY_USER_SCRIPT}" ]; then
    use_durable_notify_outcome=1
    notify_state_root="${EXECUTOR_BATCH_NOTIFICATION_ATTEMPTS_DIR}/${event_lock_crc}.${event_lock_length}"
    notify_log_file="${notify_state_root}/_dispatcher/log/user_notify.jsonl"
    if [ -f "${notify_log_file}" ]; then
      notify_log_before="$(wc -l <"${notify_log_file}" | tr -d ' ')"
    fi
  fi

  set +e
  EVENT="result" \
  STATUS="${status}" \
  PROJECT="${project}" \
  IID="${iid}" \
  MR_URL="${mr_url}" \
  REASON="${reason}" \
  ORIGIN_JSON="${origin_json}" \
  STATE_ROOT="${notify_state_root:-${STATE_ROOT}}" \
    "${BASH}" "${NOTIFY_USER_SCRIPT}" >/dev/null
  notify_rc=$?
  set -e

  notify_succeeded=0
  if [ "${notify_rc}" -eq 0 ] && [ "${use_durable_notify_outcome}" -eq 0 ]; then
    notify_succeeded=1
  elif [ "${notify_rc}" -eq 0 ] && [ "${origin_json}" = null ]; then
    # Manual/no-origin entries are intentionally non-deliverable in
    # notify_user.sh. Its durable skipped ledger is the terminal outcome.
    notify_succeeded=1
  elif [ "${notify_rc}" -eq 0 ] && [ -f "${notify_log_file}" ]; then
    notify_log_start=$((notify_log_before + 1))
    new_notify_rows="$(sed -n "${notify_log_start},\$p" "${notify_log_file}")"
    if jq -s -e 'any(.[]; .kind == "user_notify" and .delivered == true)' \
      <<<"${new_notify_rows}" >/dev/null 2>&1; then
      notify_succeeded=1
    fi
  fi

  if [ "${notify_succeeded}" -ne 1 ]; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "drain_executor_batch_notifications.sh: notify not delivered rc=${notify_rc}; retained ${event_id}" >&2
    flock -u "${event_lock_fd}"
    exec {event_lock_fd}>&-
    continue
  fi

  delivered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  flock 9
  notifications_json="$(load_notifications_locked)"
  match_count="$(jq -r --arg event_id "${event_id}" \
    '[.notifications[] | select(.event_id == $event_id)] | length' \
    <<<"${notifications_json}")"
  [ "${match_count}" -eq 1 ] \
    || drain_die "notification disappeared before delivery commit: ${event_id}" 3
  next_notifications="$(jq -c \
    --arg event_id "${event_id}" \
    --arg delivered_at "${delivered_at}" '
    .notifications |= map(
      if .event_id == $event_id and .delivered_at == null
      then .delivered_at = $delivered_at
      else .
      end
    )
  ' <<<"${notifications_json}")"
  publish_notifications_locked "${next_notifications}"
  flock -u 9
  DELIVERED_COUNT=$((DELIVERED_COUNT + 1))
  flock -u "${event_lock_fd}"
  exec {event_lock_fd}>&-
done <<<"${pending_event_ids}"

jq -cn \
  --argjson scanned "${SCANNED_COUNT}" \
  --argjson attempted "${ATTEMPTED_COUNT}" \
  --argjson delivered "${DELIVERED_COUNT}" \
  --argjson failed "${FAILED_COUNT}" '{
  status:"drained",
  scanned:$scanned,
  attempted:$attempted,
  delivered:$delivered,
  failed:$failed
}'
