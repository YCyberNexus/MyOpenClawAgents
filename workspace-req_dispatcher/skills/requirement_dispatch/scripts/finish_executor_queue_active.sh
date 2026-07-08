#!/usr/bin/env bash
# Clear one durable executor queue active item after an executor terminal callback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${CORRELATION_ID:?CORRELATION_ID required}"
PROJECT="${PROJECT:-}"
IID="${IID:-}"

if [ -n "${IID}" ]; then
  [[ "${IID}" =~ ^[1-9][0-9]*$ ]] || { echo "IID must be a positive integer when set (got: ${IID})" >&2; exit 1; }
fi

exec 9>"${LOCK_FILE}"
flock 9

tmp_normalized="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq '
  def active_array:
    if (.active | type) == "array" then .active
    elif .active == null then []
    else [.active]
    end;
  .active = active_array
  | .queue = (.queue // [])
' "${EXECUTOR_QUEUE_FILE}" > "${tmp_normalized}"
mv "${tmp_normalized}" "${EXECUTOR_QUEUE_FILE}"

active="$(jq -c '.active' "${EXECUTOR_QUEUE_FILE}")" \
  || { echo "jq read failed on ${EXECUTOR_QUEUE_FILE} (corrupt?)" >&2; exit 1; }
active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"

if [ "${active_count}" = "0" ]; then
  flock -u 9
  jq -nc --arg status "no_active" \
    --argjson active_count "${active_count}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, active_count:$active_count, queued_count:$queued_count}'
  exit 0
fi

matched="$(jq -c --arg cid "${CORRELATION_ID}" \
  '[.active[] | select(.correlation_id == $cid)][0] // empty' "${EXECUTOR_QUEUE_FILE}")"

if [ -z "${matched}" ]; then
  flock -u 9
  jq -nc \
    --arg status "ignored" \
    --arg reason "correlation_mismatch" \
    --arg correlation_id "${CORRELATION_ID}" \
    --argjson active "${active}" \
    --argjson active_count "${active_count}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, reason:$reason, correlation_id:$correlation_id,
      active:$active, active_count:$active_count, queued_count:$queued_count}'
  exit 0
fi

active_project="$(jq -r '.project // ""' <<<"${matched}")"
active_iid="$(jq -r '.iid // ""' <<<"${matched}")"

if [ -n "${PROJECT}" ] && [ "${active_project}" != "${PROJECT}" ]; then
  flock -u 9
  jq -nc \
    --arg status "ignored" \
    --arg reason "project_mismatch" \
    --arg active_project "${active_project}" \
    --arg project "${PROJECT}" \
    --argjson active "${matched}" \
    --argjson active_count "${active_count}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, reason:$reason, active_project:$active_project,
      project:$project, active:$active, active_count:$active_count,
      queued_count:$queued_count}'
  exit 0
fi

if [ -n "${IID}" ] && [ "${active_iid}" != "${IID}" ]; then
  flock -u 9
  jq -nc \
    --arg status "ignored" \
    --arg reason "iid_mismatch" \
    --arg active_iid "${active_iid}" \
    --arg iid "${IID}" \
    --argjson active "${matched}" \
    --argjson active_count "${active_count}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, reason:$reason, active_iid:$active_iid,
      iid:$iid, active:$active, active_count:$active_count,
      queued_count:$queued_count}'
  exit 0
fi

tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq --arg cid "${CORRELATION_ID}" '
  .active = [.active[] | select(.correlation_id != $cid)]
' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "cleared" \
  --arg correlation_id "${CORRELATION_ID}" \
  --argjson cleared_active "${matched}" \
  --argjson active_count "${active_count}" \
  --argjson queued_count "${queued_count}" \
  '{status:$status, correlation_id:$correlation_id,
    cleared_active:$cleared_active, active_count:$active_count,
    queued_count:$queued_count}'
