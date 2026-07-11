#!/usr/bin/env bash
# Repair a legacy single-shim mirror, and clear the old FIFO active only after
# that batch has a durable terminal projection (I3 or zero-match receipt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

exec 9>"${LOCK_FILE}"
flock 9
active_json="$(jq -c '.active // null' "${EXECUTOR_QUEUE_FILE}")" \
  || { echo "legacy queue is invalid" >&2; exit 3; }
if [ "${active_json}" = null ] \
  || [ -z "$(jq -r '.driven_batch_id // ""' <<<"${active_json}")" ]; then
  flock -u 9
  jq -cn '{status:"no_bridge"}'
  exit 0
fi
flock -u 9

batch_id="$(jq -r '.driven_batch_id' <<<"${active_json}")"
executor_agent="$(jq -r '.driven_executor_agent' <<<"${active_json}")"
matched_count="$(jq -r '.driven_matched_count' <<<"${active_json}")"
request_digest="$(jq -r '.driven_request_digest' <<<"${active_json}")"
origin_json="$(jq -c '.origin // null' <<<"${active_json}")"
project="$(jq -r '.project' <<<"${active_json}")"

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

mirror_status="$(jq -r --arg batch_id "${batch_id}" \
  '.batches[$batch_id].status // ""' "${EXECUTOR_BATCH_MIRROR_FILE}")"
if [ "${mirror_status}" != completed ]; then
  jq -cn \
    --arg batch_id "${batch_id}" \
    --arg record_status "$(jq -r '.status' <<<"${record_result}")" '{
      status:"attached",batch_id:$batch_id,record_status:$record_status
    }'
  exit 0
fi

event_json=null
if [ "${matched_count}" -gt 0 ]; then
  event_json="$(jq -sc --arg batch_id "${batch_id}" '
    [.[] | select(.batch_id == $batch_id)][-1] // null
  ' "${EXECUTOR_BATCH_EVENT_LEDGER_FILE}")"
  [ "${event_json}" != null ] \
    || { echo "completed legacy mirror has no terminal I3" >&2; exit 3; }
fi

exec 9>"${LOCK_FILE}"
flock 9
current_active="$(jq -c '.active // null' "${EXECUTOR_QUEUE_FILE}")"
if [ "${current_active}" = null ] \
  || [ "$(jq -r '.driven_batch_id // ""' <<<"${current_active}")" != "${batch_id}" ]; then
  flock -u 9
  jq -cn --arg batch_id "${batch_id}" '{status:"already_cleared",batch_id:$batch_id}'
  exit 0
fi

run_id="$(jq -r '.run_id' <<<"${current_active}")"
correlation_id="$(jq -r '.correlation_id' <<<"${current_active}")"
iid="$(jq -r '.iid' <<<"${current_active}")"
was_pending="$(jq -r --arg run_id "${run_id}" '.pending | has($run_id)' "${PENDING_FILE}")"
if [ "${event_json}" = null ]; then
  terminal_status=no_matches
  mr_url=""
  reason="无匹配 OPEN Issue"
  event_id="${batch_id}:no-matches"
  outcome=success
else
  terminal_status="$(jq -r '.status' <<<"${event_json}")"
  mr_url="$(jq -r '.mr_url // ""' <<<"${event_json}")"
  reason="$(jq -r '.reason // ""' <<<"${event_json}")"
  event_id="$(jq -r '.event_id' <<<"${event_json}")"
  case "${terminal_status}" in done|skipped) outcome=success ;; *) outcome=failed ;; esac
fi

if ! jq -e --arg batch_id "${batch_id}" '
  select(.kind == "legacy_batch_terminal" and .batch_id == $batch_id)
' "${LEDGER_FILE}" >/dev/null 2>&1; then
  drained_at="$(date -u +%s)"
  jq -nc \
    --arg run_id "${run_id}" \
    --arg outcome "${outcome}" \
    --arg project "${project}" \
    --argjson iid "${iid}" \
    --arg status "${terminal_status}" \
    --arg mr_url "${mr_url}" \
    --arg reason "${reason}" \
    --arg batch_id "${batch_id}" \
    --arg event_id "${event_id}" \
    --argjson drained_at "${drained_at}" \
    --argjson was_pending "${was_pending}" '{
      kind:"legacy_batch_terminal",
      run_id:$run_id,
      outcome:$outcome,
      stage:"executor",
      project:$project,
      issue_iid:$iid,
      issue_url:null,
      status:$status,
      mr_url:($mr_url | select(. != "") // null),
      reason:($reason | select(. != "") // null),
      batch_id:$batch_id,
      event_id:$event_id,
      drained_at:$drained_at,
      was_pending:$was_pending
    }' >>"${LEDGER_FILE}"
fi

pending_candidate="$(mktemp "${DISPATCHER_DIR}/.pending.legacy-terminal.XXXXXX")"
jq --arg run_id "${run_id}" 'del(.pending[$run_id])' \
  "${PENDING_FILE}" >"${pending_candidate}"
mv "${pending_candidate}" "${PENDING_FILE}"

queue_candidate="$(mktemp "${DISPATCHER_DIR}/.executor_queue.legacy-terminal.XXXXXX")"
jq \
  --arg batch_id "${batch_id}" \
  --arg correlation_id "${correlation_id}" '
  if .active != null
    and .active.driven_batch_id == $batch_id
    and .active.correlation_id == $correlation_id
  then .active = null
  else .
  end
' "${EXECUTOR_QUEUE_FILE}" >"${queue_candidate}"
mv "${queue_candidate}" "${EXECUTOR_QUEUE_FILE}"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -cn \
  --arg batch_id "${batch_id}" \
  --arg correlation_id "${correlation_id}" \
  --argjson queued_count "${queued_count}" '{
    status:"cleared",
    batch_id:$batch_id,
    correlation_id:$correlation_id,
    queued_count:$queued_count
  }'
