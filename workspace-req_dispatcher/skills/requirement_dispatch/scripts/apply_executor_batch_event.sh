#!/usr/bin/env bash
# Validate and durably apply one executor public I3 worker_result_json object.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

apply_die() {
  echo "apply_executor_batch_event.sh: $1" >&2
  exit "${2:-2}"
}

publish_json_locked() {
  local destination="$1"
  local json="$2"
  local destination_name candidate

  destination_name="$(basename "${destination}")"
  candidate="$(mktemp "${DISPATCHER_DIR}/.${destination_name}.XXXXXX")"
  printf '%s\n' "${json}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null \
    || apply_die "refusing to publish invalid JSON for ${destination_name}" 3
  mv "${candidate}" "${destination}"
}

publish_event_ledger_locked() {
  local ledger_array="$1"
  local candidate published_array

  candidate="$(mktemp "${DISPATCHER_DIR}/.executor_batch_events.jsonl.XXXXXX")"
  jq -c '.[]' <<<"${ledger_array}" >"${candidate}"
  published_array="$(jq -scS . "${candidate}")" \
    || apply_die "refusing to publish an invalid executor batch event ledger" 3
  [ "${published_array}" = "$(jq -cS . <<<"${ledger_array}")" ] \
    || apply_die "executor batch event ledger changed during serialization" 3
  mv "${candidate}" "${EXECUTOR_BATCH_EVENT_LEDGER_FILE}"
}

CALLBACK_TRANSPORT_MODE=legacy_pre_upgrade
CALLBACK_NONCE=""
CALLBACK_EXECUTOR_AGENT=""
CALLBACK_INPUT="${CALLBACK_ENVELOPE_JSON:-${callback_envelope:-}}"
WORKER_RESULT_INPUT="${WORKER_RESULT_JSON:-${worker_result_json:-}}"
if [ -n "${CALLBACK_INPUT}" ]; then
  if ! callback_envelope_json="$(jq -cseS '
    def printable:
      type == "string" and length > 0
      and (explode | all(. >= 32 and . != 127));
    if length == 1
      and (.[0] | type == "object")
      and ((.[0] | keys | sort) == [
        "callback_nonce","executor_agent","worker_result_json"
      ])
      and (.[0].callback_nonce | type == "string"
        and test("^[0-9a-f]{64}$"))
      and (.[0].executor_agent | printable)
      and (.[0].worker_result_json | type == "object")
    then .[0]
    else error("invalid authenticated callback envelope")
    end
  ' <<<"${CALLBACK_INPUT}" 2>/dev/null)"; then
    apply_die "callback envelope authentication failed" 3
  fi
  CALLBACK_TRANSPORT_MODE=nonce_v1
  CALLBACK_NONCE="$(jq -r '.callback_nonce' <<<"${callback_envelope_json}")"
  CALLBACK_EXECUTOR_AGENT="$(jq -r '.executor_agent' <<<"${callback_envelope_json}")"
  WORKER_RESULT_INPUT="$(jq -cS '.worker_result_json' <<<"${callback_envelope_json}")"
elif [ -z "${WORKER_RESULT_INPUT}" ] && [ "$#" -gt 0 ]; then
  WORKER_RESULT_INPUT="$1"
elif [ -z "${WORKER_RESULT_INPUT}" ] && [ ! -t 0 ]; then
  WORKER_RESULT_INPUT="$(cat)"
fi
[ -n "${WORKER_RESULT_INPUT}" ] \
  || apply_die "authenticated callback envelope or legacy worker_result_json is required"

# Keep the nonce only in non-exported shell variables after transport parsing.
# This prevents jq/date/hash helper subprocesses from inheriting the original
# nonce-bearing envelope environment.
unset CALLBACK_ENVELOPE_JSON callback_envelope WORKER_RESULT_JSON worker_result_json
unset CALLBACK_INPUT callback_envelope_json

if ! event_json="$(jq -ceS '
  def printable:
    type == "string"
    and length > 0
    and (explode | all(. >= 32 and . != 127));
  def nullable_string:
    . == null
    or (type == "string" and (explode | all(. >= 32 and . != 127)));
  if type == "object"
    and (keys | sort) == [
      "batch_id","event_id","iid","mr_url","project","reason",
      "snapshot_index","status"
    ]
    and (.batch_id | printable)
    and (.snapshot_index | type == "number" and . == floor and . >= 0)
    and (.event_id | printable)
    and .event_id == (.batch_id + ":snapshot-"
      + (.snapshot_index | tostring) + ":terminal-1")
    and (.project | printable)
    and (.project | test("^[^/[:space:]]+(/[^/[:space:]]+)+$"))
    and (.iid | type == "number" and . == floor and . > 0)
    and (.status == "done" or .status == "failed"
      or .status == "timeout" or .status == "skipped")
    and (.mr_url | nullable_string)
    and (.reason | nullable_string)
  then .
  else error("invalid public I3 worker_result_json")
  end
' <<<"${WORKER_RESULT_INPUT}" 2>/dev/null)"; then
  apply_die "worker_result_json must be the exact valid public I3 shape"
fi
if [ "${CALLBACK_TRANSPORT_MODE}" = nonce_v1 ] \
  && [[ "${event_json}" == *"${CALLBACK_NONCE}"* ]]; then
  apply_die "worker_result_json contains callback authentication material" 3
fi

event_id="$(jq -r '.event_id' <<<"${event_json}")"
batch_id="$(jq -r '.batch_id' <<<"${event_json}")"
snapshot_index="$(jq -r '.snapshot_index' <<<"${event_json}")"
received_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

exec 9>"${LOCK_FILE}"
flock 9

if ! mirror_json="$(jq -ce '
  if type == "object" and (.batches | type == "object") then .
  else error("invalid executor batch mirror")
  end
' "${EXECUTOR_BATCH_MIRROR_FILE}" 2>/dev/null)"; then
  apply_die "executor batch mirror is invalid" 3
fi

if ! ledger_json="$(jq -sce '
  def printable:
    type == "string"
    and length > 0
    and (explode | all(. >= 32 and . != 127));
  def nullable_string:
    . == null
    or (type == "string" and (explode | all(. >= 32 and . != 127)));
  if all(.[];
    type == "object"
    and (keys | sort) == [
      "batch_id","event_id","iid","mr_url","project","reason",
      "received_at","snapshot_index","status"
    ]
    and (.event_id | printable)
    and (.batch_id | printable)
    and (.snapshot_index | type == "number" and . == floor and . >= 0)
    and .event_id == (.batch_id + ":snapshot-"
      + (.snapshot_index | tostring) + ":terminal-1")
    and (.project | printable)
    and (.project | test("^[^/[:space:]]+(/[^/[:space:]]+)+$"))
    and (.iid | type == "number" and . == floor and . > 0)
    and (.status == "done" or .status == "failed"
      or .status == "timeout" or .status == "skipped")
    and (.mr_url | nullable_string)
    and (.reason | nullable_string)
    and (.received_at | printable)
  ) then .
  else error("invalid executor batch event ledger")
  end
' "${EXECUTOR_BATCH_EVENT_LEDGER_FILE}" 2>/dev/null)"; then
  apply_die "executor batch event ledger is invalid" 3
fi

if ! notifications_json="$(jq -ce '
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
' "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" 2>/dev/null)"; then
  apply_die "executor batch notifications are invalid" 3
fi

if ! jq -e --arg batch_id "${batch_id}" '.batches | has($batch_id)' \
  <<<"${mirror_json}" >/dev/null; then
  flock -u 9
  jq -cn --arg event_id "${event_id}" \
    '{status:"unknown_batch",event_id:$event_id}'
  exit 3
fi

stored_batch_json="$(jq -c --arg batch_id "${batch_id}" \
  '.batches[$batch_id]' <<<"${mirror_json}")"
if ! batch_json="$(jq -ce --arg batch_id "${batch_id}" '
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
  .
  | if type == "object"
      and (
        (keys | sort) == [
          "batch_id","created_at","executor_agent","matched_count","origin",
          "request_digest","status","terminal_count","updated_at"
        ]
        or (keys | sort) == [
          "batch_id","callback_auth_mode","callback_nonce_sha256","created_at",
          "executor_agent","matched_count","origin","project","request_digest",
          "status","terminal_count","updated_at"
        ]
      )
      and .batch_id == $batch_id
      and (.executor_agent | type == "string" and length > 0)
      and (if has("callback_auth_mode") then
        (
          (.callback_auth_mode == "nonce_v1"
            and (.project | printable
              and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
            and (.callback_nonce_sha256 | type == "string"
              and test("^[0-9a-f]{64}$")))
          or (.callback_auth_mode == "legacy_pre_upgrade"
            and (.project == null
              or (.project | printable
                and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$")))
            and .callback_nonce_sha256 == null)
        )
      else true end)
      and (.origin | valid_origin)
      and (.matched_count | type == "number" and . == floor and . >= 0)
      and (.terminal_count | type == "number" and . == floor and . >= 0)
      and .terminal_count <= .matched_count
      and (.status == "resolving" or .status == "queued"
        or .status == "running" or .status == "completed"
        or .status == "failed" or .status == "waiting_for_legacy_drain")
      and (.request_digest | type == "string" and length > 0)
      and (.created_at | type == "string" and length > 0)
      and (.updated_at | type == "string" and length > 0)
    then
      if has("callback_auth_mode") then .
      else . + {
        callback_auth_mode:"legacy_pre_upgrade",
        callback_nonce_sha256:null,
        project:null
      }
      end
    else error("invalid batch mirror entry")
    end
' <<<"${stored_batch_json}" 2>/dev/null)"; then
  apply_die "batch mirror entry is invalid: ${batch_id}" 3
fi

batch_auth_mode="$(jq -r '.callback_auth_mode' <<<"${batch_json}")"
persisted_project="$(jq -r '.project // ""' <<<"${batch_json}")"
persisted_executor_agent="$(jq -r '.executor_agent' <<<"${batch_json}")"
event_project="$(jq -r '.project' <<<"${event_json}")"
case "${batch_auth_mode}" in
  nonce_v1)
    callback_nonce_sha256="$(executor_callback_nonce_sha256 "${CALLBACK_NONCE}" 2>/dev/null || true)"
    if [ "${CALLBACK_TRANSPORT_MODE}" != nonce_v1 ] \
      || [ -z "${callback_nonce_sha256}" ] \
      || [ "${callback_nonce_sha256}" != "$(jq -r '.callback_nonce_sha256' <<<"${batch_json}")" ] \
      || [ "${CALLBACK_EXECUTOR_AGENT}" != "${persisted_executor_agent}" ] \
      || [ "${event_project}" != "${persisted_project}" ]; then
      apply_die "callback envelope authentication failed" 3
    fi
    ;;
  legacy_pre_upgrade)
    if [ "${CALLBACK_TRANSPORT_MODE}" != legacy_pre_upgrade ] \
      || { [ -n "${persisted_project}" ] \
        && [ "${event_project}" != "${persisted_project}" ]; }; then
      apply_die "legacy callback compatibility check failed" 3
    fi
    ;;
  *) apply_die "batch mirror callback authentication mode is invalid" 3 ;;
esac

matched_count="$(jq -r '.matched_count' <<<"${batch_json}")"
if [ "${snapshot_index}" -ge "${matched_count}" ]; then
  apply_die "snapshot_index is outside the recorded batch: ${batch_id}/${snapshot_index}" 3
fi

event_matches="$(jq -c --arg event_id "${event_id}" \
  '[.[] | select(.event_id == $event_id)]' <<<"${ledger_json}")"
event_match_count="$(jq -r 'length' <<<"${event_matches}")"
if [ "${event_match_count}" -gt 1 ]; then
  apply_die "event ledger contains duplicate event IDs: ${event_id}" 3
fi

batch_status="$(jq -r '.status' <<<"${batch_json}")"
if [ "${event_match_count}" -eq 0 ]; then
  case "${batch_status}" in
    queued|running) ;;
    *) apply_die "batch status does not accept a new I3 event: ${batch_id}/${batch_status}" 3 ;;
  esac
else
  case "${batch_status}" in
    resolving|waiting_for_legacy_drain|failed)
      apply_die "batch status forbids duplicate projection repair: ${batch_id}/${batch_status}" 3
      ;;
  esac
fi

ack_status="accepted"
if [ "${event_match_count}" -eq 1 ]; then
  persisted_event="$(jq -cS '.[0] | del(.received_at)' <<<"${event_matches}")"
  if [ "${persisted_event}" != "${event_json}" ]; then
    apply_die "event_id conflicts with a different public event: ${event_id}" 3
  fi
  ack_status="duplicate"
  canonical_ledger="${ledger_json}"
else
  ledger_row="$(jq -c --arg received_at "${received_at}" \
    '. + {received_at:$received_at}' <<<"${event_json}")"
  canonical_ledger="$(jq -c --argjson row "${ledger_row}" '. + [$row]' \
    <<<"${ledger_json}")"

  # The ledger is the canonical commit. It is published atomically before
  # either derived projection, so a crash can always be repaired by replay.
  publish_event_ledger_locked "${canonical_ledger}"
fi

batch_events="$(jq -c --arg batch_id "${batch_id}" \
  '[.[] | select(.batch_id == $batch_id)]' <<<"${canonical_ledger}")"
if ! jq -e --argjson matched_count "${matched_count}" '
  length <= $matched_count
  and ([.[].snapshot_index] | length) == ([.[].snapshot_index] | unique | length)
  and all(.[]; .snapshot_index < $matched_count)
' <<<"${batch_events}" >/dev/null; then
  apply_die "event ledger cannot project a valid batch mirror: ${batch_id}" 3
fi

next_terminal_count="$(jq -r 'length' <<<"${batch_events}")"
if [ "${batch_status}" = completed ] && [ "${next_terminal_count}" -ne "${matched_count}" ]; then
  apply_die "completed batch conflicts with its canonical event ledger: ${batch_id}" 3
fi
if [ "${next_terminal_count}" -eq "${matched_count}" ]; then
  next_batch_status="completed"
else
  next_batch_status="running"
fi
projection_updated_at="$(jq -r '[.[].received_at] | max' <<<"${batch_events}")"

next_mirror="$(jq -c \
  --arg batch_id "${batch_id}" \
  --arg project "${event_project}" \
  --argjson terminal_count "${next_terminal_count}" \
  --arg status "${next_batch_status}" \
  --arg updated_at "${projection_updated_at}" '
  if (.batches[$batch_id] | has("callback_auth_mode")) then .
  else .batches[$batch_id] += {
    callback_auth_mode:"legacy_pre_upgrade",
    callback_nonce_sha256:null,
    project:$project
  }
  end
  | .batches[$batch_id].terminal_count = $terminal_count
  | .batches[$batch_id].project = (.batches[$batch_id].project // $project)
  | .batches[$batch_id].status = $status
  | .batches[$batch_id].updated_at = $updated_at
' <<<"${mirror_json}")"

notification_item="$(jq -c \
  --argjson event "${event_json}" \
  --argjson origin "$(jq -c '.origin' <<<"${batch_json}")" '{
  event_id:$event.event_id,
  origin:$origin,
  project:$event.project,
  iid:$event.iid,
  status:$event.status,
  mr_url:$event.mr_url,
  reason:$event.reason,
  attempts:0,
  delivered_at:null,
  next_attempt_at:null
}' <<<"${event_json}")"
notification_matches="$(jq -c --arg event_id "${event_id}" \
  '[.notifications[] | select(.event_id == $event_id)]' \
  <<<"${notifications_json}")"
notification_match_count="$(jq -r 'length' <<<"${notification_matches}")"
delivered_notification="$(
  load_executor_delivered_notification_by_event_id_locked "${event_id}"
)"
if [ "${notification_match_count}" -gt 1 ]; then
  apply_die "notification state contains duplicate event IDs: ${event_id}" 3
elif [ "${delivered_notification}" != null ]; then
  if ! jq -en \
    --argjson delivered "${delivered_notification}" \
    --argjson expected "${notification_item}" '
      $delivered.event_id == $expected.event_id
      and $delivered.origin == $expected.origin
      and $delivered.project == $expected.project
      and $delivered.iid == $expected.iid
      and $delivered.status == $expected.status
      and $delivered.mr_url == $expected.mr_url
      and $delivered.reason == $expected.reason
    ' >/dev/null; then
    apply_die "delivered notification conflicts with canonical event: ${event_id}" 3
  fi
  if [ "${notification_match_count}" -eq 1 ] \
    && ! jq -e --argjson expected "${notification_item}" '
      .[0].event_id == $expected.event_id
      and .[0].origin == $expected.origin
      and .[0].project == $expected.project
      and .[0].iid == $expected.iid
      and .[0].status == $expected.status
      and .[0].mr_url == $expected.mr_url
      and .[0].reason == $expected.reason
    ' <<<"${notification_matches}" >/dev/null; then
    apply_die "notification conflicts with canonical event: ${event_id}" 3
  fi
  next_notifications="$(jq -c --arg event_id "${event_id}" '
    .notifications |= map(select(.event_id != $event_id))
  ' <<<"${notifications_json}")"
elif [ "${notification_match_count}" -eq 1 ]; then
  if ! jq -e --argjson expected "${notification_item}" '
    .[0].event_id == $expected.event_id
    and .[0].origin == $expected.origin
    and .[0].project == $expected.project
    and .[0].iid == $expected.iid
    and .[0].status == $expected.status
    and .[0].mr_url == $expected.mr_url
    and .[0].reason == $expected.reason
  ' <<<"${notification_matches}" >/dev/null; then
    apply_die "notification conflicts with canonical event: ${event_id}" 3
  fi
  next_notifications="${notifications_json}"
else
  next_notifications="$(jq -c --argjson item "${notification_item}" \
    '.notifications += [$item]' <<<"${notifications_json}")"
fi

# Both projections are derived from the committed ledger while the shared
# dispatcher lock is held. Replaying a committed event repairs either
# projection if a process died between these atomic writes.
publish_json_locked "${EXECUTOR_BATCH_MIRROR_FILE}" "${next_mirror}"
publish_json_locked "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" "${next_notifications}"
flock -u 9

jq -cn --arg status "${ack_status}" --arg event_id "${event_id}" \
  '{status:$status,event_id:$event_id}'
