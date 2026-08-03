#!/usr/bin/env bash
# Retry undelivered per-Issue batch notifications without holding LOCK_FILE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

DEFAULT_NOTIFY_USER_SCRIPT="${SCRIPT_DIR}/notify_user.sh"
NOTIFY_USER_SCRIPT="${NOTIFY_USER_SCRIPT:-${DEFAULT_NOTIFY_USER_SCRIPT}}"
NOTIFICATION_BUDGET="${EXECUTOR_BATCH_NOTIFICATION_BUDGET:-3}"
RETRY_BASE_SECONDS="${EXECUTOR_BATCH_NOTIFICATION_RETRY_BASE_SECONDS:-30}"
RETRY_MAX_SECONDS="${EXECUTOR_BATCH_NOTIFICATION_RETRY_MAX_SECONDS:-3600}"
case "${NOTIFICATION_BUDGET}" in
  ''|*[!0-9]*|0) echo "EXECUTOR_BATCH_NOTIFICATION_BUDGET must be a positive integer" >&2; exit 2 ;;
esac
case "${RETRY_BASE_SECONDS}" in
  ''|*[!0-9]*|0) echo "EXECUTOR_BATCH_NOTIFICATION_RETRY_BASE_SECONDS must be a positive integer" >&2; exit 2 ;;
esac
case "${RETRY_MAX_SECONDS}" in
  ''|*[!0-9]*|0) echo "EXECUTOR_BATCH_NOTIFICATION_RETRY_MAX_SECONDS must be a positive integer" >&2; exit 2 ;;
esac
[ "${RETRY_MAX_SECONDS}" -ge "${RETRY_BASE_SECONDS}" ] \
  || { echo "notification retry max must be >= base" >&2; exit 2; }

drain_die() {
  echo "drain_executor_batch_notifications.sh: $1" >&2
  exit "${2:-2}"
}

notification_event_key() {
  local event_id="$1"
  local helper="${EXECUTOR_BATCH_NOTIFICATION_KEY_HELPER:-}"
  local key

  if [ -n "${helper}" ]; then
    [ -x "${helper}" ] \
      || drain_die "notification key helper is not executable: ${helper}" 3
    if ! key="$("${helper}" "${event_id}")"; then
      drain_die "notification key helper failed" 3
    fi
  elif ! key="$(printf '%s' "${event_id}" | executor_batch_sha256)"; then
    drain_die "cannot derive notification SHA-256 key" 3
  fi

  if ! [[ "${key}" =~ ^[0-9a-f]{64}$ ]]; then
    drain_die "notification key must be one lowercase SHA-256 digest" 3
  fi
  printf '%s\n' "${key}"
}

iso_from_epoch() {
  local epoch="$1" iso
  [[ "${epoch}" =~ ^[0-9]+$ ]] || return 1
  if iso="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
      && [[ "${iso}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "${iso}"
  elif iso="$(date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
      && [[ "${iso}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "${iso}"
  else
    return 1
  fi
}

retry_delay_for_attempt() {
  local attempts="$1"
  local delay="${RETRY_BASE_SECONDS}"
  local index=1
  while [ "${index}" -lt "${attempts}" ] && [ "${delay}" -lt "${RETRY_MAX_SECONDS}" ]; do
    delay=$((delay * 2))
    [ "${delay}" -le "${RETRY_MAX_SECONDS}" ] || delay="${RETRY_MAX_SECONDS}"
    index=$((index + 1))
  done
  printf '%s\n' "${delay}"
}

initialize_outcome_metadata() {
  local outcome_root="$1"
  local event_id="$2"
  local metadata_file="${outcome_root}/event_metadata.json"
  local candidate
  local recorded_event_id

  if [ -f "${metadata_file}" ]; then
    if ! recorded_event_id="$(jq -er '
      if type == "object"
      and (keys | sort) == ["event_id","version"]
      and .version == 1
      and (.event_id | type == "string" and length > 0
        and (explode | all(. >= 32 and . != 127)))
      then .event_id
      else error("invalid event metadata")
      end
    ' "${metadata_file}" 2>/dev/null)"; then
      drain_die "durable notification event metadata is invalid" 3
    fi
    [ "${recorded_event_id}" = "${event_id}" ] && return 0
    return 10
  fi

  # Outcome rows without identity metadata cannot be attributed safely.
  if [ -s "${outcome_root}/_dispatcher/log/user_notify.jsonl" ] \
    || [ -s "${outcome_root}/_dispatcher/ledger.jsonl" ]; then
    drain_die "durable notification outcome is missing event metadata" 3
  fi

  mkdir -p "${outcome_root}"
  candidate="$(mktemp "${outcome_root}/.event_metadata.json.XXXXXX")"
  jq -cn --arg event_id "${event_id}" \
    '{version:1,event_id:$event_id}' >"${candidate}"
  mv "${candidate}" "${metadata_file}"
}

durable_outcome_root() {
  local event_key="$1"
  local event_id="$2"
  local outcome_root="${EXECUTOR_BATCH_NOTIFICATION_ATTEMPTS_DIR}/${event_key}"
  local actual_sha256
  local metadata_rc

  if initialize_outcome_metadata "${outcome_root}" "${event_id}"; then
    printf '%s\n' "${outcome_root}"
    return 0
  else
    metadata_rc=$?
  fi
  [ "${metadata_rc}" -eq 10 ] \
    || drain_die "cannot validate durable notification outcome metadata" 3

  # A test helper can force a primary-key collision. Keep the second identity
  # in its own SHA-256 namespace; malformed metadata still fails closed.
  if ! actual_sha256="$(printf '%s' "${event_id}" | executor_batch_sha256)"; then
    drain_die "cannot derive notification collision namespace" 3
  fi
  outcome_root="${EXECUTOR_BATCH_NOTIFICATION_ATTEMPTS_DIR}/${event_key}.collision.${actual_sha256}"
  if ! initialize_outcome_metadata "${outcome_root}" "${event_id}"; then
    drain_die "notification SHA-256 collision namespace conflicts with another event" 3
  fi
  printf '%s\n' "${outcome_root}"
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
          "attempts","delivered_at","event_id","iid","mr_url","next_attempt_at",
          "origin","project","reason","status"
        ]
        and (.event_id | printable)
        and (.origin | valid_origin)
        and (.project | printable)
        and (
          ((.status == "done" or .status == "failed"
              or .status == "timeout" or .status == "skipped")
            and (.iid | type == "number" and . == floor and . > 0)
            and ((.mr_url == null) or (.mr_url | type == "string"))
            and ((.reason == null) or (.reason | type == "string")))
          or (.status == "no_matches"
            and .iid == null
            and .mr_url == null
            and .reason == "无匹配 OPEN Issue")
        )
        and (.attempts | type == "number" and . == floor and . >= 0)
        and ((.delivered_at == null) or (.delivered_at | printable))
        and ((.next_attempt_at == null) or (.next_attempt_at | printable))
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

load_delivered_notification_archive_file() {
  local archive_file="$1"

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
      and (keys | sort) == [
        "attempts","delivered_at","event_id","iid","mr_url","origin",
        "project","reason","status","version"
      ]
      and .version == 1
      and (.event_id | printable)
      and (.origin | valid_origin)
      and (.project | printable)
      and (
        ((.status == "done" or .status == "failed"
            or .status == "timeout" or .status == "skipped")
          and (.iid | type == "number" and . == floor and . > 0)
          and (.mr_url == null or (.mr_url | type == "string"))
          and (.reason == null or (.reason | type == "string")))
        or (.status == "no_matches"
          and .iid == null
          and .mr_url == null
          and .reason == "无匹配 OPEN Issue")
      )
      and (.attempts | type == "number" and . == floor and . >= 0)
      and (.delivered_at | printable)
    then .
    else error("invalid delivered notification archive")
    end
  ' "${archive_file}" 2>/dev/null \
    || drain_die "delivered notification archive is invalid: ${archive_file}" 3
}

compact_delivered_notification() {
  local notification_item="$1"

  jq -ce '
    if type == "object" and .delivered_at != null then {
      version:1,
      event_id:.event_id,
      origin:.origin,
      project:.project,
      iid:.iid,
      status:.status,
      mr_url:.mr_url,
      reason:.reason,
      attempts:.attempts,
      delivered_at:.delivered_at
    }
    else error("cannot archive an undelivered notification")
    end
  ' <<<"${notification_item}" 2>/dev/null \
    || drain_die "cannot compact delivered notification" 3
}

archive_delivered_notification_locked() {
  local notification_item="$1"
  local compact_item event_id archive_key archive_file candidate validated existing

  compact_item="$(compact_delivered_notification "${notification_item}")"
  event_id="$(jq -r '.event_id' <<<"${compact_item}")"
  archive_key="$(printf '%s' "${event_id}" | executor_batch_sha256)"
  [[ "${archive_key}" =~ ^[0-9a-f]{64}$ ]] \
    || drain_die "delivered notification archive key is invalid" 3
  archive_file="${EXECUTOR_BATCH_DELIVERED_NOTIFICATIONS_DIR}/${archive_key}.json"

  if [ -e "${archive_file}" ]; then
    [ -f "${archive_file}" ] \
      || drain_die "delivered notification archive path is not a regular file: ${archive_file}" 3
    existing="$(load_delivered_notification_archive_file "${archive_file}")"
    if [ "$(jq -cS . <<<"${existing}")" != "$(jq -cS . <<<"${compact_item}")" ]; then
      drain_die "delivered notification archive conflicts with hot state: ${event_id}" 3
    fi
    return 0
  fi

  candidate="$(mktemp "${EXECUTOR_BATCH_DELIVERED_NOTIFICATIONS_DIR}/.${archive_key}.json.XXXXXX")"
  printf '%s\n' "${compact_item}" >"${candidate}"
  validated="$(load_delivered_notification_archive_file "${candidate}")"
  [ "$(jq -cS . <<<"${validated}")" = "$(jq -cS . <<<"${compact_item}")" ] \
    || drain_die "delivered notification archive changed during validation: ${event_id}" 3
  mv "${candidate}" "${archive_file}"
}

compact_delivered_notifications_locked() {
  local notifications_json="$1"
  local notification_item next_notifications

  while IFS= read -r notification_item; do
    [ -n "${notification_item}" ] || continue
    archive_delivered_notification_locked "${notification_item}"
  done < <(jq -c '.notifications[] | select(.delivered_at != null)' <<<"${notifications_json}")

  next_notifications="$(jq -c '
    .notifications |= map(select(.delivered_at == null))
  ' <<<"${notifications_json}")"
  if [ "$(jq -cS . <<<"${next_notifications}")" != "$(jq -cS . <<<"${notifications_json}")" ]; then
    publish_notifications_locked "${next_notifications}"
  fi
  printf '%s' "${next_notifications}"
}

exec 9>"${LOCK_FILE}"
flock 9
notifications_json="$(load_notifications_locked)"
SCANNED_COUNT="$(jq -r '.notifications | length' <<<"${notifications_json}")"
notifications_json="$(compact_delivered_notifications_locked "${notifications_json}")"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pending_event_ids="$(jq -r \
  --arg now "${NOW_ISO}" \
  --argjson budget "${NOTIFICATION_BUDGET}" '
  [.notifications[]
    | select(.delivered_at == null)
    | select(.next_attempt_at == null or .next_attempt_at <= $now)
  ][: $budget][] | .event_id
' <<<"${notifications_json}")"
flock -u 9

ATTEMPTED_COUNT=0
DELIVERED_COUNT=0
FAILED_COUNT=0

while IFS= read -r event_id; do
  [ -n "${event_id}" ] || continue

  event_key="$(notification_event_key "${event_id}")"
  event_lock_file="${DISPATCHER_DIR}/executor_batch_notification.${event_key}.lock"
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
  if [ "${match_count}" -eq 0 ]; then
    delivered_notification="$(
      load_executor_delivered_notification_by_event_id_locked "${event_id}"
    )"
    if [ "${delivered_notification}" != null ]; then
      flock -u 9
      flock -u "${event_lock_fd}"
      exec {event_lock_fd}>&-
      continue
    fi
    drain_die "notification event_id is missing: ${event_id}" 3
  elif [ "${match_count}" -ne 1 ]; then
    drain_die "notification event_id is duplicated: ${event_id}" 3
  fi

  if [ "$(jq -r --arg event_id "${event_id}" \
    '.notifications[] | select(.event_id == $event_id) | .delivered_at != null' \
    <<<"${notifications_json}")" = true ]; then
    flock -u 9
    flock -u "${event_lock_fd}"
    exec {event_lock_fd}>&-
    continue
  fi

  notification_item="$(jq -c --arg event_id "${event_id}" \
    '.notifications[] | select(.event_id == $event_id)' \
    <<<"${notifications_json}")"
  origin_json="$(jq -c '.origin' <<<"${notification_item}")"
  use_durable_notify_outcome=0
  notify_state_root=""
  notify_log_file=""
  notify_ledger_file=""
  notify_log_before=0
  durable_outcome_already_committed=0
  if [ "${NOTIFY_USER_SCRIPT}" = "${DEFAULT_NOTIFY_USER_SCRIPT}" ]; then
    use_durable_notify_outcome=1
    notify_state_root="$(durable_outcome_root "${event_key}" "${event_id}")"
    notify_log_file="${notify_state_root}/_dispatcher/log/user_notify.jsonl"
    notify_ledger_file="${notify_state_root}/_dispatcher/ledger.jsonl"
    if [ -f "${notify_log_file}" ]; then
      notify_log_before="$(wc -l <"${notify_log_file}" | tr -d ' ')"
      if jq -e 'select(.kind == "user_notify" and .delivered == true)' \
        "${notify_log_file}" >/dev/null 2>&1; then
        durable_outcome_already_committed=1
      fi
    fi
    if [ "${durable_outcome_already_committed}" -eq 0 ] \
      && [ -f "${notify_ledger_file}" ] \
      && jq -e 'select(.kind == "user_notify_skipped")' \
        "${notify_ledger_file}" >/dev/null 2>&1; then
      durable_outcome_already_committed=1
    fi
  fi

  if [ "${durable_outcome_already_committed}" -eq 1 ]; then
    delivered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    next_notifications="$(jq -c \
      --arg event_id "${event_id}" \
      --arg delivered_at "${delivered_at}" '
      .notifications |= map(
        if .event_id == $event_id and .delivered_at == null
        then .delivered_at = $delivered_at
        else . end
      )
    ' <<<"${notifications_json}")"
    publish_notifications_locked "${next_notifications}"
    flock -u 9
    DELIVERED_COUNT=$((DELIVERED_COUNT + 1))
    flock -u "${event_lock_fd}"
    exec {event_lock_fd}>&-
    continue
  fi

  next_notifications="$(jq -c --arg event_id "${event_id}" '
    .notifications |= map(
      if .event_id == $event_id
      then .attempts += 1 | .next_attempt_at = null
      else . end
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
  iid="$(jq -r '.iid // ""' <<<"${notification_item}")"
  mr_url="$(jq -r '.mr_url // ""' <<<"${notification_item}")"
  reason="$(jq -r '.reason // ""' <<<"${notification_item}")"
  origin_json="$(jq -c '.origin' <<<"${notification_item}")"

  notify_event=result
  notify_status="${status}"
  if [ "${status}" = no_matches ]; then
    notify_event=failure
    notify_status=""
  fi

  set +e
  env \
    -u CALLBACK_ENVELOPE_JSON \
    -u callback_envelope \
    -u WORKER_RESULT_JSON \
    -u worker_result_json \
    EVENT="${notify_event}" \
    STATUS="${notify_status}" \
    PROJECT="${project}" \
    IID="${iid}" \
    MR_URL="${mr_url}" \
    REASON="${reason}" \
    ORIGIN_JSON="${origin_json}" \
    NOTIFY_EVENT_ID="${event_id}" \
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
    attempts="$(jq -r '.attempts' <<<"${notification_item}")"
    retry_delay="$(retry_delay_for_attempt "${attempts}")"
    retry_epoch=$(( $(date -u +%s) + retry_delay ))
    next_attempt_at="$(iso_from_epoch "${retry_epoch}")"
    flock 9
    notifications_json="$(load_notifications_locked)"
    next_notifications="$(jq -c \
      --arg event_id "${event_id}" \
      --arg next_attempt_at "${next_attempt_at}" '
      .notifications |= map(
        if .event_id == $event_id and .delivered_at == null
        then .next_attempt_at = $next_attempt_at
        else . end
      )
    ' <<<"${notifications_json}")"
    publish_notifications_locked "${next_notifications}"
    flock -u 9
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
      then .delivered_at = $delivered_at | .next_attempt_at = null
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
