#!/usr/bin/env bash
# Enqueue the one durable user-visible notification for a zero-match batch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

: "${BATCH_ID:?BATCH_ID required}"
: "${PROJECT:?PROJECT required}"
ORIGIN_JSON="${ORIGIN_JSON:-null}"
ORIGIN_JSON="$(printf '%s' "${ORIGIN_JSON}" | normalize_executor_batch_origin 2>/dev/null)" \
  || executor_batch_outbox_die "ORIGIN_JSON is invalid"
EVENT_ID="${BATCH_ID}:no-matches"

exec 9>"${LOCK_FILE}"
flock 9
if ! notifications_json="$(jq -ce '
  if type == "object" and (.notifications | type == "array") then .
  else error("invalid notification state")
  end
' "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" 2>/dev/null)"; then
  executor_batch_outbox_die "executor batch notifications are invalid" 3
fi

item="$(jq -cn \
  --arg event_id "${EVENT_ID}" \
  --argjson origin "${ORIGIN_JSON}" \
  --arg project "${PROJECT}" '{
    event_id:$event_id,
    origin:$origin,
    project:$project,
    iid:null,
    status:"no_matches",
    mr_url:null,
    reason:"无匹配 OPEN Issue",
    attempts:0,
    delivered_at:null,
    next_attempt_at:null
  }')"
delivered_notification="$(
  load_executor_delivered_notification_by_event_id_locked "${EVENT_ID}"
)"

matches="$(jq -c --arg event_id "${EVENT_ID}" \
  '[.notifications[] | select(.event_id == $event_id)]' <<<"${notifications_json}")"
match_count="$(jq -r 'length' <<<"${matches}")"
if [ "${match_count}" -gt 1 ]; then
  executor_batch_outbox_die "duplicate zero-match notification: ${EVENT_ID}" 3
elif [ "${delivered_notification}" != null ]; then
  if ! jq -en \
    --argjson delivered "${delivered_notification}" \
    --argjson expected "${item}" '
      $delivered.event_id == $expected.event_id
      and $delivered.origin == $expected.origin
      and $delivered.project == $expected.project
      and $delivered.iid == $expected.iid
      and $delivered.status == $expected.status
      and $delivered.mr_url == $expected.mr_url
      and $delivered.reason == $expected.reason
    ' >/dev/null; then
    executor_batch_outbox_die \
      "delivered zero-match notification conflicts with canonical event" 3
  fi
  if [ "${match_count}" -eq 1 ] \
    && ! jq -e --argjson expected "${item}" '
      .[0].event_id == $expected.event_id
      and .[0].origin == $expected.origin
      and .[0].project == $expected.project
      and .[0].iid == $expected.iid
      and .[0].status == $expected.status
      and .[0].mr_url == $expected.mr_url
      and .[0].reason == $expected.reason
    ' <<<"${matches}" >/dev/null; then
    executor_batch_outbox_die \
      "zero-match notification conflicts with delivered state" 3
  fi
  if [ "${match_count}" -eq 1 ]; then
    next_notifications="$(jq -c --arg event_id "${EVENT_ID}" '
      .notifications |= map(select(.event_id != $event_id))
    ' <<<"${notifications_json}")"
    candidate="$(mktemp "${DISPATCHER_DIR}/.executor_batch_notifications.json.XXXXXX")"
    printf '%s\n' "${next_notifications}" >"${candidate}"
    jq -e . "${candidate}" >/dev/null \
      || executor_batch_outbox_die "refusing to publish invalid notifications" 3
    mv "${candidate}" "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}"
  fi
  flock -u 9
  jq -cn --arg event_id "${EVENT_ID}" '{status:"duplicate",event_id:$event_id}'
  exit 0
elif [ "${match_count}" -eq 1 ]; then
  if ! jq -e --argjson origin "${ORIGIN_JSON}" --arg project "${PROJECT}" '
    .[0] == {
      event_id:(.[0].event_id),
      origin:$origin,
      project:$project,
      iid:null,
      status:"no_matches",
      mr_url:null,
      reason:"无匹配 OPEN Issue",
      attempts:(.[0].attempts),
      delivered_at:(.[0].delivered_at),
      next_attempt_at:(.[0].next_attempt_at)
    }
  ' <<<"${matches}" >/dev/null; then
    executor_batch_outbox_die "zero-match notification conflicts with existing state" 3
  fi
  flock -u 9
  jq -cn --arg event_id "${EVENT_ID}" '{status:"duplicate",event_id:$event_id}'
  exit 0
fi

next_notifications="$(jq -c --argjson item "${item}" \
  '.notifications += [$item]' <<<"${notifications_json}")"
candidate="$(mktemp "${DISPATCHER_DIR}/.executor_batch_notifications.json.XXXXXX")"
printf '%s\n' "${next_notifications}" >"${candidate}"
jq -e . "${candidate}" >/dev/null \
  || executor_batch_outbox_die "refusing to publish invalid notifications" 3
mv "${candidate}" "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}"
flock -u 9

jq -cn --arg event_id "${EVENT_ID}" '{status:"accepted",event_id:$event_id}'
