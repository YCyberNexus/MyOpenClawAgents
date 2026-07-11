#!/usr/bin/env bash
# Deliver at most one persisted I1 request. Failed/ambiguous delivery stays queued.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

TARGET_BATCH_ID="${BATCH_ID:-}"
if [ -n "${TARGET_BATCH_ID}" ] \
  && ! [[ "${TARGET_BATCH_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  executor_batch_outbox_die "BATCH_ID must be a valid batch identifier"
fi

publish_status_transitions_locked() {
  local outbox_json="$1"
  local desired_status="$2"
  local now="$3"
  local next_outbox

  next_outbox="$(jq -c --arg status "${desired_status}" --arg now "${now}" '
    .requests |= map(
      if .status == "queued" or .status == "waiting_for_legacy_drain"
      then .status = $status | .updated_at = $now
      else .
      end
    )
  ' <<<"${outbox_json}")"
  if [ "$(jq -cS . <<<"${next_outbox}")" != "$(jq -cS . <<<"${outbox_json}")" ]; then
    publish_executor_batch_outbox_locked "${next_outbox}"
  fi
  printf '%s' "${next_outbox}"
}

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exec 9>"${LOCK_FILE}"
flock 9
outbox_json="$(load_executor_batch_outbox_locked)"
legacy_queue_json="$(load_legacy_executor_queue_locked)"
if legacy_executor_queue_is_busy "${legacy_queue_json}" >/dev/null; then
  outbox_json="$(publish_status_transitions_locked "${outbox_json}" waiting_for_legacy_drain "${now}")"
  if [ -n "${TARGET_BATCH_ID}" ]; then
    entry_json="$(jq -c --arg batch_id "${TARGET_BATCH_ID}" '
      [.requests[] | select(.batch_id == $batch_id and .status == "received")][0] // null
    ' <<<"${outbox_json}")"
  else
    entry_json="$(jq -c '[.requests[] | select(.status == "received")][0] // null' \
      <<<"${outbox_json}")"
  fi
  if [ "${entry_json}" = null ]; then
    waiting_count="$(jq -r '[.requests[] | select(.status == "waiting_for_legacy_drain")] | length' <<<"${outbox_json}")"
    if [ -n "${TARGET_BATCH_ID}" ]; then
      waiting_count=0
      first_waiting="$(jq -r --arg batch_id "${TARGET_BATCH_ID}" '
        [.requests[] | select(
          .batch_id == $batch_id and .status == "waiting_for_legacy_drain"
        )][0].batch_id // ""
      ' <<<"${outbox_json}")"
      [ -n "${first_waiting}" ] && waiting_count=1
    else
      first_waiting="$(jq -r '.requests[] | select(.status == "waiting_for_legacy_drain") | .batch_id' \
        <<<"${outbox_json}" | sed -n '1p')"
    fi
    flock -u 9
    jq -cn \
      --arg batch_id "${first_waiting}" \
      --argjson waiting_count "${waiting_count}" '{
        status:"waiting_for_legacy_drain",
        batch_id:($batch_id | select(. != "") // null),
        waiting_count:$waiting_count
      }'
    exit 0
  fi
else
  outbox_json="$(publish_status_transitions_locked "${outbox_json}" queued "${now}")"
  if [ -n "${TARGET_BATCH_ID}" ]; then
    entry_json="$(jq -c --arg batch_id "${TARGET_BATCH_ID}" '
      [.requests[] | select(
        .batch_id == $batch_id and (.status == "received" or .status == "queued")
      )][0] // null
    ' <<<"${outbox_json}")"
  else
    entry_json="$(jq -c '
      ([.requests[] | select(.status == "received")][0]
        // [.requests[] | select(.status == "queued")][0]) // null
    ' <<<"${outbox_json}")"
  fi
fi
flock -u 9
if [ "${entry_json}" = null ]; then
  jq -cn --arg batch_id "${TARGET_BATCH_ID}" '{
    status:"idle",
    batch_id:($batch_id | select(. != "") // null),
    queued_count:0
  }'
  exit 0
fi

batch_id="$(jq -r '.batch_id' <<<"${entry_json}")"
read -r batch_lock_crc batch_lock_length _batch_lock_name \
  < <(printf '%s' "${batch_id}" | cksum)
batch_lock_file="${DISPATCHER_DIR}/executor_batch_outbox.${batch_lock_crc}.${batch_lock_length}.lock"
exec {batch_lock_fd}>"${batch_lock_file}"
if ! flock -n "${batch_lock_fd}"; then
  exec {batch_lock_fd}>&-
  jq -cn --arg batch_id "${batch_id}" '{status:"busy",batch_id:$batch_id}'
  exit 0
fi

# Recheck the migration gate after acquiring the per-batch delivery lock.
flock 9
outbox_json="$(load_executor_batch_outbox_locked)"
legacy_queue_json="$(load_legacy_executor_queue_locked)"
current_status="$(jq -r --arg batch_id "${batch_id}" '
  [.requests[] | select(.batch_id == $batch_id)][0].status // ""
' <<<"${outbox_json}")"
if legacy_executor_queue_is_busy "${legacy_queue_json}" >/dev/null \
  && [ "${current_status}" != received ]; then
  next_outbox="$(jq -c --arg batch_id "${batch_id}" --arg now "${now}" '
    .requests |= map(
      if .batch_id == $batch_id
        and (.status == "queued" or .status == "waiting_for_legacy_drain")
      then .status = "waiting_for_legacy_drain" | .updated_at = $now
      else . end
    )
  ' <<<"${outbox_json}")"
  publish_executor_batch_outbox_locked "${next_outbox}"
  flock -u 9
  flock -u "${batch_lock_fd}"
  exec {batch_lock_fd}>&-
  jq -cn --arg batch_id "${batch_id}" \
    '{status:"waiting_for_legacy_drain",batch_id:$batch_id,waiting_count:1}'
  exit 0
fi

entry_json="$(jq -c --arg batch_id "${batch_id}" '
  [.requests[] | select(
    .batch_id == $batch_id and (.status == "queued" or .status == "received")
  )][0] // null
' <<<"${outbox_json}")"
if [ "${entry_json}" = null ]; then
  flock -u 9
  flock -u "${batch_lock_fd}"
  exec {batch_lock_fd}>&-
  jq -cn --arg batch_id "${batch_id}" '{status:"idle",batch_id:$batch_id}'
  exit 0
fi

correlation_id="$(jq -r '.correlation_id' <<<"${entry_json}")"
executor_agent="$(jq -r '.executor_agent' <<<"${entry_json}")"
payload="$(jq -r '.payload' <<<"${entry_json}")"
attempts="$(jq -r '.attempts' <<<"${entry_json}")"
entry_status="$(jq -r '.status' <<<"${entry_json}")"

acceptance_json=null
network_attempted=false
if [ "${entry_status}" = received ]; then
  acceptance_json="$(jq -c '{
    status:"success",
    batch_id:.batch_id,
    matched_count:.matched_count,
    snapshot_digest:.snapshot_digest,
    scheduler_status:.scheduler_status
  }' <<<"${entry_json}")"
  flock -u 9
else
  attempted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  next_outbox="$(jq -c --arg batch_id "${batch_id}" --arg attempted_at "${attempted_at}" '
    .requests |= map(
      if .batch_id == $batch_id then
        .attempts += 1
        | .last_attempt_at = $attempted_at
        | .last_error = null
        | .updated_at = $attempted_at
      else . end
    )
  ' <<<"${outbox_json}")"
  publish_executor_batch_outbox_locked "${next_outbox}"
  entry_json="$(jq -c --arg batch_id "${batch_id}" \
    '.requests[] | select(.batch_id == $batch_id)' <<<"${next_outbox}")"
  attempts="$(jq -r '.attempts' <<<"${entry_json}")"
  flock -u 9
  network_attempted=true

  set +e
  envelope="$(
    env \
      -u GITLAB_TOKEN \
      -u GLAB_TOKEN \
      -u GITLAB_PRIVATE_TOKEN \
      -u PRIVATE_TOKEN \
      -u WIKI_GITLAB_TOKEN \
      OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}" \
      TARGET_AGENT="${executor_agent}" \
      RUN_ID="executor-batch-${batch_id}" \
      DEFAULT_EXECUTOR_AGENT="${executor_agent}" \
      DOWNSTREAM_AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
      EXECUTOR_AGENT_TIMEOUT_SECONDS="${EXECUTOR_AGENT_TIMEOUT_SECONDS:-${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}}" \
      AGENT_TIMEOUT_SECONDS="${EXECUTOR_AGENT_TIMEOUT_SECONDS:-${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}}" \
        "${BASH}" "${SCRIPT_DIR}/run_agent_turn.sh" <<<"${payload}"
  )"
  run_rc=$?
  set -e

  failure_reason=run_agent_turn_failed
  if [ "${run_rc}" -eq 0 ] && jq -e '.status == "success"' <<<"${envelope}" >/dev/null 2>&1; then
    candidate_acceptance="$(jq -c '.worker_result_json // null' <<<"${envelope}" 2>/dev/null || printf null)"
    if acceptance_json="$(jq -ce --arg batch_id "${batch_id}" '
      if type == "object"
        and (keys | sort) == [
          "batch_id","matched_count","scheduler_status","snapshot_digest","status"
        ]
        and .status == "success"
        and .batch_id == $batch_id
        and (.matched_count | type == "number" and . == floor and . >= 0)
        and (.snapshot_digest | type == "string" and length > 0
          and (explode | all(. >= 32 and . != 127)))
        and (.scheduler_status == "queued" or .scheduler_status == "running"
          or .scheduler_status == "completed")
        and (if .matched_count == 0 then .scheduler_status == "completed" else true end)
      then .
      else error("invalid compact executor acceptance")
      end
    ' <<<"${candidate_acceptance}" 2>/dev/null)"; then
      failure_reason=""
    else
      acceptance_json=null
      failure_reason=invalid_executor_acceptance
    fi
  elif [ "${run_rc}" -eq 0 ]; then
    failure_reason=executor_turn_failed
  fi
fi

if [ "${acceptance_json}" = null ]; then
  failed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  flock 9
  outbox_json="$(load_executor_batch_outbox_locked)"
  legacy_queue_json="$(load_legacy_executor_queue_locked)"
  if legacy_executor_queue_is_busy "${legacy_queue_json}" >/dev/null; then
    retained_status=waiting_for_legacy_drain
  else
    retained_status=queued
  fi
  next_outbox="$(jq -c \
    --arg batch_id "${batch_id}" \
    --arg status "${retained_status}" \
    --arg error "${failure_reason}" \
    --arg updated_at "${failed_at}" '
    .requests |= map(
      if .batch_id == $batch_id and .status != "accepted" then
        .status = $status
        | .last_error = $error
        | .updated_at = $updated_at
      else . end
    )
  ' <<<"${outbox_json}")"
  publish_executor_batch_outbox_locked "${next_outbox}"
  flock -u 9
  flock -u "${batch_lock_fd}"
  exec {batch_lock_fd}>&-
  jq -cn \
    --arg batch_id "${batch_id}" \
    --arg correlation_id "${correlation_id}" \
    --arg reason "${failure_reason}" \
    --argjson attempts "${attempts}" '{
      status:"retryable_failure",
      batch_id:$batch_id,
      correlation_id:$correlation_id,
      reason:$reason,
      attempts:$attempts
    }'
  exit 0
fi

matched_count="$(jq -r '.matched_count' <<<"${acceptance_json}")"
snapshot_digest="$(jq -r '.snapshot_digest' <<<"${acceptance_json}")"
scheduler_status="$(jq -r '.scheduler_status' <<<"${acceptance_json}")"
request_digest="$(jq -r '.request_digest' <<<"${entry_json}")"
origin_json="$(jq -c '.origin' <<<"${entry_json}")"
project="$(jq -r '.project' <<<"${entry_json}")"

if [ "${network_attempted}" = true ]; then
  STATE_ROOT="${STATE_ROOT}" \
  BATCH_ID="${batch_id}" \
  EXECUTOR_AGENT="${executor_agent}" \
  MATCHED_COUNT="${matched_count}" \
  SNAPSHOT_DIGEST="${snapshot_digest}" \
  SCHEDULER_STATUS="${scheduler_status}" \
    "${BASH}" "${SCRIPT_DIR}/record_executor_batch_receipt.sh" >/dev/null
fi

record_result="$(
  STATE_ROOT="${STATE_ROOT}" \
  BATCH_ID="${batch_id}" \
  EXECUTOR_AGENT="${executor_agent}" \
  ORIGIN_JSON="${origin_json}" \
  MATCHED_COUNT="${matched_count}" \
  REQUEST_DIGEST="${request_digest}" \
    "${BASH}" "${SCRIPT_DIR}/record_executor_batch.sh"
)"
if [ "${matched_count}" -eq 0 ]; then
  STATE_ROOT="${STATE_ROOT}" \
  BATCH_ID="${batch_id}" \
  PROJECT="${project}" \
  ORIGIN_JSON="${origin_json}" \
    "${BASH}" "${SCRIPT_DIR}/enqueue_executor_batch_empty_notification.sh" >/dev/null
fi

accepted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
flock 9
outbox_json="$(load_executor_batch_outbox_locked)"
next_outbox="$(jq -c \
  --arg batch_id "${batch_id}" \
  --argjson matched_count "${matched_count}" \
  --arg snapshot_digest "${snapshot_digest}" \
  --arg scheduler_status "${scheduler_status}" \
  --arg accepted_at "${accepted_at}" '
  .requests |= map(
    if .batch_id == $batch_id
      and .status == "received"
      and .matched_count == $matched_count
      and .snapshot_digest == $snapshot_digest
    then
      .status = "accepted"
      | .matched_count = $matched_count
      | .snapshot_digest = $snapshot_digest
      | .scheduler_status = $scheduler_status
      | .last_error = null
      | .updated_at = $accepted_at
      | .accepted_at = $accepted_at
    else . end
  )
' <<<"${outbox_json}")"
publish_executor_batch_outbox_locked "${next_outbox}"
flock -u 9
flock -u "${batch_lock_fd}"
exec {batch_lock_fd}>&-

"${BASH}" "${SCRIPT_DIR}/drain_executor_batch_notifications.sh" >/dev/null

jq -cn \
  --arg batch_id "${batch_id}" \
  --arg correlation_id "${correlation_id}" \
  --argjson matched_count "${matched_count}" \
  --arg snapshot_digest "${snapshot_digest}" \
  --arg scheduler_status "${scheduler_status}" \
  --arg record_status "$(jq -r '.status' <<<"${record_result}")" '{
    status:"accepted",
    batch_id:$batch_id,
    correlation_id:$correlation_id,
    matched_count:$matched_count,
    snapshot_digest:$snapshot_digest,
    scheduler_status:$scheduler_status,
    record_status:$record_status
  }'
