#!/usr/bin/env bash
# Validate `/slot N` and forward it to the default req_executor main session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_AGENT_TURN_CMD="${RUN_AGENT_TURN_CMD:-${SCRIPT_DIR}/run_agent_turn.sh}"

emit_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

if [ "$#" -ne 0 ]; then
  emit_failure "usage: /slot <positive-integer>"
fi

if [ -n "${MESSAGE:-}" ]; then
  COMMAND_TEXT="${MESSAGE}"
else
  COMMAND_TEXT="$(cat)"
fi
if [[ ! "${COMMAND_TEXT}" =~ ^/slot[[:blank:]]+([1-9][0-9]*)[[:blank:]]*$ ]]; then
  emit_failure "usage: /slot <positive-integer>"
fi
SLOT_COUNT_TEXT="${BASH_REMATCH[1]}"
if [ "${#SLOT_COUNT_TEXT}" -gt 10 ] \
  || [ "${SLOT_COUNT_TEXT}" -gt 2147483647 ]; then
  emit_failure "slot number must be between 1 and 2147483647"
fi

: "${DEFAULT_EXECUTOR_AGENT:?set_executor_slots.sh: DEFAULT_EXECUTOR_AGENT required}"
if [[ ! "${DEFAULT_EXECUTOR_AGENT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  emit_failure "default executor agent is invalid"
fi
CANONICAL_COMMAND="/slot ${SLOT_COUNT_TEXT}"

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
  emit_failure "executor slot update transport failed"
fi

if ! RESULT_JSON="$(printf '%s' "${TURN_OUTPUT}" | jq -ce \
  --argjson requested "${SLOT_COUNT_TEXT}" '
  if type == "object"
      and .status == "success"
      and .exit_code == 0
      and (.worker_result_json | type == "object")
      and (.worker_result_json | keys | sort) == [
        "active_count","available_slots","draining","previous_slot_count",
        "slot_count","status"
      ]
      and .worker_result_json.status == "success"
      and (.worker_result_json.slot_count
        | type == "number" and . == floor and . > 0)
      and (.worker_result_json.previous_slot_count
        | type == "number" and . == floor and . > 0)
      and (.worker_result_json.active_count
        | type == "number" and . == floor and . >= 0)
      and (.worker_result_json.available_slots
        | type == "number" and . == floor and . >= 0)
      and (.worker_result_json.draining | type == "boolean")
      and .worker_result_json.slot_count == $requested
      and .worker_result_json.available_slots == (
        [(.worker_result_json.slot_count - .worker_result_json.active_count), 0]
        | max)
      and .worker_result_json.draining == (
        .worker_result_json.active_count > .worker_result_json.slot_count)
    then .worker_result_json
    else error("invalid executor slot response") end
' 2>/dev/null)"; then
  emit_failure "executor returned an invalid slot response"
fi

printf '%s\n' "${RESULT_JSON}"
