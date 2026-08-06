#!/usr/bin/env bash
# Re-emit the exact public repository-stop receipt from durable executor state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${STOP_ID:?emit_mission_stop_receipt.sh: STOP_ID is required}"

case "${STOP_ID}" in
  mission-stop-[A-Za-z0-9._-]*) ;;
  *)
    echo "emit_mission_stop_receipt.sh: invalid STOP_ID" >&2
    exit 2
    ;;
esac
[[ "${STOP_ID}" =~ ^mission-stop-[A-Za-z0-9._-]+$ ]] || {
  echo "emit_mission_stop_receipt.sh: invalid STOP_ID" >&2
  exit 2
}

# shellcheck source=scheduler_env.sh
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null
RESULT_FILE="${EXECUTOR_SCHEDULER_ROOT}/mission_stop_archive/${STOP_ID}/result.json"
if [ -L "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ] || [ ! -r "${RESULT_FILE}" ]; then
  echo "emit_mission_stop_receipt.sh: durable result is unavailable" >&2
  exit 3
fi

jq -ceS --arg stop_id "${STOP_ID}" '
  if type == "object"
    and (keys | sort) == [
      "cleanup_requested_count","project","status","stop_id",
      "stopped_batch_ids","stopped_issue_iids","stopped_job_count"
    ]
    and .status == "success" and .stop_id == $stop_id
    and (.project | type == "string"
      and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    and (.stopped_batch_ids | type == "array"
      and all(.[]; type == "string"))
    and (.stopped_issue_iids | type == "array"
      and all(.[]; type == "number" and . == floor and . > 0))
    and (.stopped_job_count | type == "number" and . == floor and . >= 0)
    and (.cleanup_requested_count | type == "number" and . == floor and . >= 0)
  then . else error("invalid durable mission stop result") end
' "${RESULT_FILE}"
