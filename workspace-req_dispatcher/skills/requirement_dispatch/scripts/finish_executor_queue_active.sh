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

if ! jq -e '
  .driven_callback_auth_mode == "legacy_pre_upgrade"
  and ((has("callback_nonce")) | not)
  and (.driven_callback_nonce_sha256 // null) == null
  and (.launch_state // "launched") == "launched"
' <<<"${active}" >/dev/null; then
  echo "finish_executor_queue_active.sh: active is not authorized for legacy I2" >&2
  exit 3
fi

# The callback nonce is a bearer secret kept only in private queue state. Public
# status responses expose the durable intent without that field.
public_active="$(jq -c 'del(.callback_nonce, .launch_error)' <<<"${active}")"

active_correlation="$(jq -r '.correlation_id // ""' <<<"${active}")"
active_project="$(jq -r '.project // ""' <<<"${active}")"
active_iid="$(jq -r '.iid // ""' <<<"${active}")"

if [ "${active_correlation}" != "${CORRELATION_ID}" ]; then
  echo "finish_executor_queue_active.sh: legacy I2 correlation identity mismatch" >&2
  exit 3
fi

if [ -n "${PROJECT}" ] && [ "${active_project}" != "${PROJECT}" ]; then
  echo "finish_executor_queue_active.sh: legacy I2 project identity mismatch" >&2
  exit 3
fi

if [ -n "${IID}" ] && [ "${active_iid}" != "${IID}" ]; then
  echo "finish_executor_queue_active.sh: legacy I2 IID identity mismatch" >&2
  exit 3
fi

active_run_id="$(jq -r '.run_id // ""' <<<"${active}")"
if jq -e --arg run_id "${active_run_id}" '.pending | has($run_id)' \
    "${PENDING_FILE}" >/dev/null \
  || ! jq -e --arg run_id "${active_run_id}" '
    select(.run_id == $run_id and .stage == "executor" and .was_pending == true)
  ' "${LEDGER_FILE}" >/dev/null 2>&1; then
  echo "finish_executor_queue_active.sh: legacy I2 drain proof is missing" >&2
  exit 3
fi

tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq '.active = null' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "cleared" \
  --arg correlation_id "${CORRELATION_ID}" \
  --argjson cleared_active "${public_active}" \
  --argjson queued_count "${queued_count}" \
  '{status:$status, correlation_id:$correlation_id,
    cleared_active:$cleared_active, queued_count:$queued_count}'
