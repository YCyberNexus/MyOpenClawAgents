#!/usr/bin/env bash
# Persist the executor-wide parallel-repository ceiling from `/slot N`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULER_ENV_CMD="${SCHEDULER_ENV_CMD:-${SCRIPT_DIR}/scheduler_env.sh}"

slot_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

if [ "$#" -ne 0 ]; then
  slot_failure "usage: /slot <positive-integer>"
fi

COMMAND_TEXT="$(cat)"
if [[ ! "${COMMAND_TEXT}" =~ ^/slot[[:blank:]]+([1-9][0-9]*)[[:blank:]]*$ ]]; then
  slot_failure "usage: /slot <positive-integer>"
fi
SLOT_COUNT_TEXT="${BASH_REMATCH[1]}"
if [ "${#SLOT_COUNT_TEXT}" -gt 10 ] \
  || [ "${SLOT_COUNT_TEXT}" -gt 2147483647 ]; then
  slot_failure "parallel project limit must be between 1 and 2147483647"
fi
SLOT_COUNT="${SLOT_COUNT_TEXT}"

# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null

exec {SLOT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SLOT_LOCK_FD}"
if ! SCHEDULER_STATE="$(jq -ce '
  if type == "object"
    and .version == 1
    and (.active_jobs | type == "object")
    and ((has("max_concurrency") | not)
      or (.max_concurrency | type == "number" and . == floor and . > 0))
    and ((has("pending_transaction") | not)
      or ((.pending_transaction | type) == "object"
        and (.pending_transaction.scheduler_state | type == "object")
        and .pending_transaction.scheduler_state.version == 1
        and (.pending_transaction.scheduler_state.active_jobs | type == "object")))
  then . else error("invalid scheduler state") end
' "${SCHEDULER_STATE_FILE}")"; then
  flock -u "${SLOT_LOCK_FD}"
  exec {SLOT_LOCK_FD}>&-
  slot_failure "scheduler state is invalid"
fi

PREVIOUS_SLOT_COUNT="$(jq -r \
  --argjson configured_max "${EXECUTOR_MAX_CONCURRENCY}" \
  '.max_concurrency // $configured_max' <<<"${SCHEDULER_STATE}")"
ACTIVE_COUNT="$(jq -r '[.active_jobs[].project] | unique | length' <<<"${SCHEDULER_STATE}")"
UPDATED_STATE="$(jq -c --argjson slots "${SLOT_COUNT}" '
  .max_concurrency = $slots
  | if has("pending_transaction")
    then .pending_transaction.scheduler_state.max_concurrency = $slots
    else .
    end
' <<<"${SCHEDULER_STATE}")"
scheduler_atomic_write_json "${SCHEDULER_STATE_FILE}" "${UPDATED_STATE}"
flock -u "${SLOT_LOCK_FD}"
exec {SLOT_LOCK_FD}>&-

if [ "${ACTIVE_COUNT}" -ge "${SLOT_COUNT}" ]; then
  AVAILABLE_SLOTS=0
else
  AVAILABLE_SLOTS=$((SLOT_COUNT - ACTIVE_COUNT))
fi
if [ "${ACTIVE_COUNT}" -gt "${SLOT_COUNT}" ]; then
  DRAINING=true
else
  DRAINING=false
fi

jq -cn \
  --argjson parallel_project_limit "${SLOT_COUNT}" \
  --argjson previous_parallel_project_limit "${PREVIOUS_SLOT_COUNT}" \
  --argjson active_project_count "${ACTIVE_COUNT}" \
  --argjson available_project_slots "${AVAILABLE_SLOTS}" \
  --argjson draining "${DRAINING}" '
  {
    status:"success",
    parallel_project_limit:$parallel_project_limit,
    previous_parallel_project_limit:$previous_parallel_project_limit,
    active_project_count:$active_project_count,
    available_project_slots:$available_project_slots,
    draining:$draining
  }'
