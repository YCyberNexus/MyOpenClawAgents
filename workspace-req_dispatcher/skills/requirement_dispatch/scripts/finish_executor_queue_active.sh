#!/usr/bin/env bash
# Clear the durable executor queue active item after an executor terminal callback.
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

active="$(jq -c '.active // null' "${EXECUTOR_QUEUE_FILE}")" \
  || { echo "jq read failed on ${EXECUTOR_QUEUE_FILE} (corrupt?)" >&2; exit 1; }
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"

if [ "${active}" = "null" ]; then
  flock -u 9
  jq -nc --arg status "no_active" --argjson queued_count "${queued_count}" \
    '{status:$status, queued_count:$queued_count}'
  exit 0
fi

active_correlation="$(jq -r '.correlation_id // ""' <<<"${active}")"
active_project="$(jq -r '.project // ""' <<<"${active}")"
active_iid="$(jq -r '.iid // ""' <<<"${active}")"

if [ "${active_correlation}" != "${CORRELATION_ID}" ]; then
  flock -u 9
  jq -nc \
    --arg status "ignored" \
    --arg reason "correlation_mismatch" \
    --arg active_correlation "${active_correlation}" \
    --arg correlation_id "${CORRELATION_ID}" \
    --argjson active "${active}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, reason:$reason, active_correlation:$active_correlation,
      correlation_id:$correlation_id, active:$active, queued_count:$queued_count}'
  exit 0
fi

if [ -n "${PROJECT}" ] && [ "${active_project}" != "${PROJECT}" ]; then
  flock -u 9
  jq -nc \
    --arg status "ignored" \
    --arg reason "project_mismatch" \
    --arg active_project "${active_project}" \
    --arg project "${PROJECT}" \
    --argjson active "${active}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, reason:$reason, active_project:$active_project,
      project:$project, active:$active, queued_count:$queued_count}'
  exit 0
fi

if [ -n "${IID}" ] && [ "${active_iid}" != "${IID}" ]; then
  flock -u 9
  jq -nc \
    --arg status "ignored" \
    --arg reason "iid_mismatch" \
    --arg active_iid "${active_iid}" \
    --arg iid "${IID}" \
    --argjson active "${active}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, reason:$reason, active_iid:$active_iid,
      iid:$iid, active:$active, queued_count:$queued_count}'
  exit 0
fi

tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq '.active = null' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "cleared" \
  --arg correlation_id "${CORRELATION_ID}" \
  --argjson cleared_active "${active}" \
  --argjson queued_count "${queued_count}" \
  '{status:$status, correlation_id:$correlation_id,
    cleared_active:$cleared_active, queued_count:$queued_count}'
