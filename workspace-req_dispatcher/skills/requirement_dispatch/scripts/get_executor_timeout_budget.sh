#!/usr/bin/env bash
# Load, validate, and return the effective executor timeout chain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=source_executor_timeout_budget.sh
source "${SCRIPT_DIR}/source_executor_timeout_budget.sh"

: "${EXECUTOR_ACPX_TIMEOUT_SECONDS:?EXECUTOR_ACPX_TIMEOUT_SECONDS required}"
: "${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS:?OPENCLAW_SUBAGENT_TIMEOUT_SECONDS required}"
: "${EXECUTOR_AGENT_TIMEOUT_SECONDS:?EXECUTOR_AGENT_TIMEOUT_SECONDS required}"
: "${EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS:?EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS required}"
: "${EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS:?EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS required}"
: "${STUCK_AFTER_MINUTES:?STUCK_AFTER_MINUTES required}"

for value in \
  "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" \
  "${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS}" \
  "${EXECUTOR_AGENT_TIMEOUT_SECONDS}" \
  "${EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS}" \
  "${EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS}" \
  "${STUCK_AFTER_MINUTES}"
do
  case "${value}" in
    ''|*[!0-9]*)
      echo "get_executor_timeout_budget.sh: timeout budget must contain integers" >&2
      exit 2
      ;;
  esac
done

EXPECTED_AGENT=$((EXECUTOR_ACPX_TIMEOUT_SECONDS + 3600))
EXPECTED_EXEC=$((EXECUTOR_ACPX_TIMEOUT_SECONDS + 3900))
EXPECTED_RECLAIM=$((EXECUTOR_ACPX_TIMEOUT_SECONDS + 4200))
EXPECTED_STUCK=$(( (EXPECTED_RECLAIM + 59) / 60 + 20 ))
if [ "${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS}" -lt 20400 ] \
    || [ "${EXECUTOR_AGENT_TIMEOUT_SECONDS}" -ne "${EXPECTED_AGENT}" ] \
    || [ "${EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS}" -ne "${EXPECTED_EXEC}" ] \
    || [ "${EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS}" -ne "${EXPECTED_RECLAIM}" ] \
    || [ "${STUCK_AFTER_MINUTES}" -ne "${EXPECTED_STUCK}" ]; then
  echo "get_executor_timeout_budget.sh: timeout budget is inconsistent" >&2
  exit 2
fi

jq -cn \
  --argjson acpx "${EXECUTOR_ACPX_TIMEOUT_SECONDS}" \
  --argjson global "${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS}" \
  --argjson agent "${EXECUTOR_AGENT_TIMEOUT_SECONDS}" \
  --argjson exec_tool "${EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS}" \
  --argjson reclaim "${EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS}" \
  --argjson stuck "${STUCK_AFTER_MINUTES}" '{
    status:"success",
    acpx_timeout_seconds:$acpx,
    global_subagent_timeout_seconds:$global,
    executor_agent_timeout_seconds:$agent,
    exec_tool_timeout_seconds:$exec_tool,
    queue_launch_reclaim_seconds:$reclaim,
    stuck_after_minutes:$stuck
  }'
