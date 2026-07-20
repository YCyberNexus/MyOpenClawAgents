#!/usr/bin/env bash
# Persist the executor-wide acpx cap for future executions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULER_ENV_CMD="${SCHEDULER_ENV_CMD:-${SCRIPT_DIR}/scheduler_env.sh}"

timeout_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

if [ "$#" -ne 0 ]; then
  timeout_failure "usage: /timeout-executor <60..18000 seconds|Nm|Nh>"
fi

COMMAND_TEXT="$(cat)"
if [[ ! "${COMMAND_TEXT}" =~ ^/timeout-executor[[:blank:]]+([1-9][0-9]*)([smh]?)[[:blank:]]*$ ]]; then
  timeout_failure "usage: /timeout-executor <60..18000 seconds|Nm|Nh>"
fi
VALUE_TEXT="${BASH_REMATCH[1]}"
UNIT="${BASH_REMATCH[2]}"
if [ "${#VALUE_TEXT}" -gt 10 ]; then
  timeout_failure "acpx timeout must be between 60 and 18000 seconds"
fi
case "${UNIT}" in
  ""|s) MULTIPLIER=1 ;;
  m) MULTIPLIER=60 ;;
  h) MULTIPLIER=3600 ;;
  *) timeout_failure "usage: /timeout-executor <60..18000 seconds|Nm|Nh>" ;;
esac
ACPX_TIMEOUT_SECONDS=$((VALUE_TEXT * MULTIPLIER))
if [ "${ACPX_TIMEOUT_SECONDS}" -lt 60 ] \
    || [ "${ACPX_TIMEOUT_SECONDS}" -gt 18000 ]; then
  timeout_failure "acpx timeout must be between 60 and 18000 seconds"
fi

# Keep dispatcher-side outer deadlines derived from the same acpx value. The
# OpenClaw global subagent timeout remains an independent deployment setting.
EXECUTOR_AGENT_TIMEOUT_SECONDS=$((ACPX_TIMEOUT_SECONDS + 3600))
EXEC_TOOL_TIMEOUT_SECONDS=$((ACPX_TIMEOUT_SECONDS + 3900))
QUEUE_LAUNCH_RECLAIM_SECONDS=$((ACPX_TIMEOUT_SECONDS + 4200))
STUCK_AFTER_MINUTES=$(( (QUEUE_LAUNCH_RECLAIM_SECONDS + 59) / 60 + 20 ))

# shellcheck disable=SC1090
source "${SCHEDULER_ENV_CMD}" >/dev/null

exec {TIMEOUT_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${TIMEOUT_LOCK_FD}"
if ! SCHEDULER_STATE="$(jq -ce '
  if type == "object"
    and .version == 1
    and (.active_jobs | type == "object")
    and ((has("acpx_timeout_seconds") | not)
      or (.acpx_timeout_seconds | type == "number" and . == floor
        and . >= 60 and . <= 18000))
    and ((has("pending_transaction") | not)
      or ((.pending_transaction | type) == "object"
        and (.pending_transaction.scheduler_state | type == "object")
        and .pending_transaction.scheduler_state.version == 1
        and (.pending_transaction.scheduler_state.active_jobs | type == "object")))
  then . else error("invalid scheduler state") end
' "${SCHEDULER_STATE_FILE}")"; then
  flock -u "${TIMEOUT_LOCK_FD}"
  exec {TIMEOUT_LOCK_FD}>&-
  timeout_failure "scheduler state is invalid"
fi

PREVIOUS_TIMEOUT_SECONDS="$(jq -r \
  --argjson configured_timeout "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" \
  '.acpx_timeout_seconds // $configured_timeout' <<<"${SCHEDULER_STATE}")"
ACTIVE_COUNT="$(jq -r '.active_jobs | length' <<<"${SCHEDULER_STATE}")"
UPDATED_STATE="$(jq -c --argjson timeout "${ACPX_TIMEOUT_SECONDS}" '
  .acpx_timeout_seconds = $timeout
  | if has("pending_transaction")
    then .pending_transaction.scheduler_state.acpx_timeout_seconds = $timeout
    else .
    end
' <<<"${SCHEDULER_STATE}")"

scheduler_atomic_write_json "${SCHEDULER_STATE_FILE}" "${UPDATED_STATE}"
flock -u "${TIMEOUT_LOCK_FD}"
exec {TIMEOUT_LOCK_FD}>&-

jq -cn \
  --argjson acpx_timeout_seconds "${ACPX_TIMEOUT_SECONDS}" \
  --argjson previous_acpx_timeout_seconds "${PREVIOUS_TIMEOUT_SECONDS}" \
  --argjson executor_agent_timeout_seconds "${EXECUTOR_AGENT_TIMEOUT_SECONDS}" \
  --argjson exec_tool_timeout_seconds "${EXEC_TOOL_TIMEOUT_SECONDS}" \
  --argjson queue_launch_reclaim_seconds "${QUEUE_LAUNCH_RECLAIM_SECONDS}" \
  --argjson stuck_after_minutes "${STUCK_AFTER_MINUTES}" \
  --argjson active_count "${ACTIVE_COUNT}" '
  {
    status:"success",
    acpx_timeout_seconds:$acpx_timeout_seconds,
    previous_acpx_timeout_seconds:$previous_acpx_timeout_seconds,
    executor_agent_timeout_seconds:$executor_agent_timeout_seconds,
    exec_tool_timeout_seconds:$exec_tool_timeout_seconds,
    queue_launch_reclaim_seconds:$queue_launch_reclaim_seconds,
    stuck_after_minutes:$stuck_after_minutes,
    active_count:$active_count,
    applies_to:"future_attempts"
  }'
