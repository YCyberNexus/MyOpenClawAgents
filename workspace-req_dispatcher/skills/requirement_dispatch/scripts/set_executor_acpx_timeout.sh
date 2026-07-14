#!/usr/bin/env bash
# Validate `/acpx-timeout <duration>` and forward it to req_executor main.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_AGENT_TURN_CMD="${RUN_AGENT_TURN_CMD:-${SCRIPT_DIR}/run_agent_turn.sh}"

emit_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

if [ "$#" -ne 0 ]; then
  emit_failure "usage: /acpx-timeout <60..18000 seconds|Nm|Nh>"
fi

if [ -n "${MESSAGE:-}" ]; then
  COMMAND_TEXT="${MESSAGE}"
else
  COMMAND_TEXT="$(cat)"
fi
if [[ ! "${COMMAND_TEXT}" =~ ^/acpx-timeout[[:blank:]]+([1-9][0-9]*)([smh]?)[[:blank:]]*$ ]]; then
  emit_failure "usage: /acpx-timeout <60..18000 seconds|Nm|Nh>"
fi
VALUE_TEXT="${BASH_REMATCH[1]}"
UNIT="${BASH_REMATCH[2]}"
if [ "${#VALUE_TEXT}" -gt 10 ]; then
  emit_failure "acpx timeout must be between 60 and 18000 seconds"
fi
case "${UNIT}" in
  ""|s) MULTIPLIER=1 ;;
  m) MULTIPLIER=60 ;;
  h) MULTIPLIER=3600 ;;
  *) emit_failure "usage: /acpx-timeout <60..18000 seconds|Nm|Nh>" ;;
esac
ACPX_TIMEOUT_SECONDS=$((VALUE_TEXT * MULTIPLIER))
if [ "${ACPX_TIMEOUT_SECONDS}" -lt 60 ] \
    || [ "${ACPX_TIMEOUT_SECONDS}" -gt 18000 ]; then
  emit_failure "acpx timeout must be between 60 and 18000 seconds"
fi

: "${DEFAULT_EXECUTOR_AGENT:?set_executor_acpx_timeout.sh: DEFAULT_EXECUTOR_AGENT required}"
if [[ ! "${DEFAULT_EXECUTOR_AGENT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  emit_failure "default executor agent is invalid"
fi
CANONICAL_COMMAND="/acpx-timeout ${ACPX_TIMEOUT_SECONDS}"

set +e
TURN_OUTPUT="$({
  unset MESSAGE MESSAGE_FILE
  printf '%s\n' "${CANONICAL_COMMAND}" | \
    TARGET_AGENT="${DEFAULT_EXECUTOR_AGENT}" \
    TARGET_SESSION_KEY="agent:${DEFAULT_EXECUTOR_AGENT}:main" \
    MESSAGE_SOURCE=stdin \
    bash "${RUN_AGENT_TURN_CMD}"
})"
TURN_RC=$?
set -e
if [ "${TURN_RC}" -ne 0 ]; then
  emit_failure "executor acpx timeout update transport failed"
fi

if ! RESULT_JSON="$(printf '%s' "${TURN_OUTPUT}" | jq -ce \
  --argjson requested "${ACPX_TIMEOUT_SECONDS}" '
  if type == "object"
      and .status == "success"
      and .exit_code == 0
      and (.worker_result_json | type == "object")
      and (.worker_result_json | keys | sort) == [
        "acpx_timeout_seconds","active_count","applies_to",
        "previous_acpx_timeout_seconds","status"
      ]
      and .worker_result_json.status == "success"
      and (.worker_result_json.acpx_timeout_seconds
        | type == "number" and . == floor and . >= 60 and . <= 18000)
      and (.worker_result_json.previous_acpx_timeout_seconds
        | type == "number" and . == floor and . >= 60 and . <= 18000)
      and (.worker_result_json.active_count
        | type == "number" and . == floor and . >= 0)
      and .worker_result_json.applies_to == "future_attempts"
      and .worker_result_json.acpx_timeout_seconds == $requested
    then .worker_result_json
    else error("invalid executor acpx timeout response") end
' 2>/dev/null)"; then
  emit_failure "executor returned an invalid acpx timeout response"
fi

printf '%s\n' "${RESULT_JSON}"
