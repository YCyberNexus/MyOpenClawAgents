#!/usr/bin/env bash
# Attach a driven-batch receipt to the currently launching legacy FIFO item.
# The bridge is published before the Task 8 mirror so an early I3 is retried as
# unknown rather than acknowledged without a way to clear the legacy active.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

: "${QUEUE_ID:?QUEUE_ID required}"
: "${CORRELATION_ID:?CORRELATION_ID required}"
: "${BATCH_ID:?BATCH_ID required}"
: "${EXECUTOR_AGENT:?EXECUTOR_AGENT required}"
: "${MATCHED_COUNT:?MATCHED_COUNT required}"
: "${SNAPSHOT_DIGEST:?SNAPSHOT_DIGEST required}"
: "${SCHEDULER_STATUS:?SCHEDULER_STATUS required}"
: "${REQUEST_DIGEST:?REQUEST_DIGEST required}"
case "${MATCHED_COUNT}" in 0|1) ;; *) echo "legacy receipt MATCHED_COUNT must be 0 or 1" >&2; exit 2 ;; esac
case "${SCHEDULER_STATUS}" in queued|running|completed) ;; *) echo "invalid legacy receipt SCHEDULER_STATUS" >&2; exit 2 ;; esac
[ "${MATCHED_COUNT}" -ne 0 ] || [ "${SCHEDULER_STATUS}" = completed ] \
  || { echo "zero-match legacy receipt must be completed" >&2; exit 2; }
if ! [[ "${BATCH_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "legacy receipt BATCH_ID is invalid" >&2
  exit 2
fi

scheduler_rank() {
  case "$1" in queued) printf '1\n' ;; running) printf '2\n' ;; completed) printf '3\n' ;; esac
}

receipt_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exec 9>"${LOCK_FILE}"
flock 9
active_json="$(jq -ce '.active // null' "${EXECUTOR_QUEUE_FILE}")" \
  || { echo "legacy queue is invalid" >&2; exit 3; }
[ "${active_json}" != null ] \
  || { echo "legacy active disappeared before receipt attach" >&2; exit 3; }
[ "$(jq -r '.queue_id // ""' <<<"${active_json}")" = "${QUEUE_ID}" ] \
  || { echo "legacy receipt queue_id mismatch" >&2; exit 3; }
[ "$(jq -r '.correlation_id // ""' <<<"${active_json}")" = "${CORRELATION_ID}" ] \
  || { echo "legacy receipt correlation_id mismatch" >&2; exit 3; }
[ "$(jq -r '.executor_agent // ""' <<<"${active_json}")" = "${EXECUTOR_AGENT}" ] \
  || { echo "legacy receipt executor_agent mismatch" >&2; exit 3; }

project="$(jq -r '.project // ""' <<<"${active_json}")"
callback_nonce="$(jq -r '.callback_nonce // ""' <<<"${active_json}")"
if [ -n "${callback_nonce}" ]; then
  if ! [[ "${SNAPSHOT_DIGEST}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "nonce_v1 legacy receipt SNAPSHOT_DIGEST is invalid" >&2
    exit 2
  fi
  callback_auth_mode=nonce_v1
  callback_nonce_sha256="$(executor_callback_nonce_sha256 "${callback_nonce}")"
  if [[ "${SNAPSHOT_DIGEST}" == *"${callback_nonce}"* ]]; then
    echo "legacy receipt contains callback authentication material" >&2
    exit 3
  fi
else
  callback_auth_mode=legacy_pre_upgrade
  callback_nonce_sha256=""
fi

receipt_status=accepted
existing_batch_id="$(jq -r '.driven_batch_id // ""' <<<"${active_json}")"
if [ -n "${existing_batch_id}" ]; then
  receipt_status=duplicate
  [ "${existing_batch_id}" = "${BATCH_ID}" ] \
    || { echo "legacy receipt batch_id conflict" >&2; exit 3; }
  [ "$(jq -r '.driven_request_digest // ""' <<<"${active_json}")" = "${REQUEST_DIGEST}" ] \
    || { echo "legacy receipt request_digest conflict" >&2; exit 3; }
  [ "$(jq -r '.driven_executor_agent // ""' <<<"${active_json}")" = "${EXECUTOR_AGENT}" ] \
    || { echo "legacy receipt executor_agent conflict" >&2; exit 3; }
  existing_project="$(jq -r '.driven_project // ""' <<<"${active_json}")"
  if [ "${existing_project}" != "${project}" ] \
    && ! { [ "${callback_auth_mode}" = legacy_pre_upgrade ] \
      && [ -z "${existing_project}" ]; }; then
    echo "legacy receipt project conflict" >&2
    exit 3
  fi
  existing_callback_auth_mode="$(jq -r '.driven_callback_auth_mode // ""' <<<"${active_json}")"
  if [ "${existing_callback_auth_mode}" != "${callback_auth_mode}" ] \
    && ! { [ "${callback_auth_mode}" = legacy_pre_upgrade ] \
      && [ -z "${existing_callback_auth_mode}" ]; }; then
    echo "legacy receipt callback_auth_mode conflict" >&2
    exit 3
  fi
  [ "$(jq -r '.driven_callback_nonce_sha256 // ""' <<<"${active_json}")" = "${callback_nonce_sha256}" ] \
    || { echo "legacy receipt callback nonce digest conflict" >&2; exit 3; }
  [ "$(jq -r '.driven_matched_count // -1' <<<"${active_json}")" = "${MATCHED_COUNT}" ] \
    || { echo "legacy receipt matched_count conflict" >&2; exit 3; }
  [ "$(jq -r '.driven_snapshot_digest // ""' <<<"${active_json}")" = "${SNAPSHOT_DIGEST}" ] \
    || { echo "legacy receipt snapshot_digest conflict" >&2; exit 3; }
  existing_scheduler="$(jq -r '.driven_scheduler_status // ""' <<<"${active_json}")"
  [ "$(scheduler_rank "${SCHEDULER_STATUS}")" -ge "$(scheduler_rank "${existing_scheduler}")" ] \
    || { echo "legacy receipt scheduler_status moved backwards" >&2; exit 3; }
fi

next_queue="$(jq -c \
  --arg queue_id "${QUEUE_ID}" \
  --arg correlation_id "${CORRELATION_ID}" \
  --arg batch_id "${BATCH_ID}" \
  --arg request_digest "${REQUEST_DIGEST}" \
  --arg executor_agent "${EXECUTOR_AGENT}" \
  --arg project "${project}" \
  --arg callback_auth_mode "${callback_auth_mode}" \
  --arg callback_nonce_sha256 "${callback_nonce_sha256}" \
  --argjson matched_count "${MATCHED_COUNT}" \
  --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
  --arg scheduler_status "${SCHEDULER_STATUS}" \
  --arg receipt_at "${receipt_at}" '
  if .active != null
    and .active.queue_id == $queue_id
    and .active.correlation_id == $correlation_id
  then .active += {
    driven_batch_id:$batch_id,
    driven_request_digest:$request_digest,
    driven_executor_agent:$executor_agent,
    driven_project:$project,
    driven_callback_auth_mode:$callback_auth_mode,
    driven_callback_nonce_sha256:(if $callback_nonce_sha256 == "" then null else $callback_nonce_sha256 end),
    driven_matched_count:$matched_count,
    driven_snapshot_digest:$snapshot_digest,
    driven_scheduler_status:$scheduler_status,
    driven_receipt_at:(.active.driven_receipt_at // $receipt_at)
  }
  else error("legacy active changed during receipt attach")
  end
' "${EXECUTOR_QUEUE_FILE}")"
queue_candidate="$(mktemp "${DISPATCHER_DIR}/.executor_queue.bridge.XXXXXX")"
printf '%s\n' "${next_queue}" >"${queue_candidate}"
jq -e . "${queue_candidate}" >/dev/null
mv "${queue_candidate}" "${EXECUTOR_QUEUE_FILE}"

run_id="$(jq -r '.active.run_id' <<<"${next_queue}")"
if jq -e --arg run_id "${run_id}" '.pending | has($run_id)' \
  "${PENDING_FILE}" >/dev/null; then
  next_pending="$(jq -c \
    --arg run_id "${run_id}" \
    --arg batch_id "${BATCH_ID}" \
    --arg project "${project}" \
    --arg callback_auth_mode "${callback_auth_mode}" \
    --arg callback_nonce_sha256 "${callback_nonce_sha256}" \
    --arg snapshot_digest "${SNAPSHOT_DIGEST}" \
    --argjson matched_count "${MATCHED_COUNT}" '
    .pending[$run_id] += {
      driven_batch_id:$batch_id,
      project:$project,
      callback_auth_mode:$callback_auth_mode,
      callback_nonce_sha256:(if $callback_nonce_sha256 == "" then null else $callback_nonce_sha256 end),
      driven_matched_count:$matched_count,
      driven_snapshot_digest:$snapshot_digest
    }
  ' "${PENDING_FILE}")"
  pending_candidate="$(mktemp "${DISPATCHER_DIR}/.pending.bridge.XXXXXX")"
  printf '%s\n' "${next_pending}" >"${pending_candidate}"
  jq -e . "${pending_candidate}" >/dev/null
  mv "${pending_candidate}" "${PENDING_FILE}"
fi
flock -u 9

jq -cn \
  --arg status "${receipt_status}" \
  --arg batch_id "${BATCH_ID}" \
  --arg scheduler_status "${SCHEDULER_STATUS}" '{
    status:$status,batch_id:$batch_id,scheduler_status:$scheduler_status
  }'
