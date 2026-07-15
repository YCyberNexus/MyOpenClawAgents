#!/usr/bin/env bash
# Read and export the executor timeout chain for execution/recovery paths only.

if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  echo "source_executor_timeout_budget.sh: bash or zsh is required" >&2
  return 14 2>/dev/null || exit 14
fi
if [ -n "${BASH_VERSION:-}" ]; then
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "source_executor_timeout_budget.sh: source this file instead of executing it" >&2
    exit 14
  fi
elif [ "${ZSH_EVAL_CONTEXT:-}" = toplevel ]; then
  echo "source_executor_timeout_budget.sh: source this file instead of executing it" >&2
  exit 14
fi

source_executor_timeout_budget_fail() {
  echo "source_executor_timeout_budget: $1" >&2
  unset -f source_executor_timeout_budget_fail
  return 14
}

case "${EXECUTOR_SCHEDULER_STATE_FILE:-}" in
  /*) ;;
  *) source_executor_timeout_budget_fail "EXECUTOR_SCHEDULER_STATE_FILE must be absolute"; return 14 ;;
esac
case "${EXECUTOR_SCHEDULER_STATE_FILE}" in
  *//*|*/./*|*/.|*/../*|*/..)
    source_executor_timeout_budget_fail "EXECUTOR_SCHEDULER_STATE_FILE is unsafe"
    return 14
    ;;
esac
if [[ ! "${EXECUTOR_SCHEDULER_STATE_FILE}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  source_executor_timeout_budget_fail "EXECUTOR_SCHEDULER_STATE_FILE contains unsupported characters"
  return 14
fi
if [ -L "${EXECUTOR_SCHEDULER_STATE_FILE}" ]; then
  source_executor_timeout_budget_fail "executor scheduler state must not be a symlink"
  return 14
fi
if [ ! -e "${EXECUTOR_SCHEDULER_STATE_FILE}" ]; then
  source_executor_timeout_budget_fail "executor scheduler state does not exist"
  return 14
fi
if [ ! -f "${EXECUTOR_SCHEDULER_STATE_FILE}" ] \
    || [ ! -r "${EXECUTOR_SCHEDULER_STATE_FILE}" ]; then
  source_executor_timeout_budget_fail "executor scheduler state must be a readable regular file"
  return 14
fi

SOURCE_EXECUTOR_ACPX_FALLBACK="${EXECUTOR_ACPX_TIMEOUT_SECONDS:-3600}"
case "${SOURCE_EXECUTOR_ACPX_FALLBACK}" in
  ''|*[!0-9]*)
    source_executor_timeout_budget_fail "EXECUTOR_ACPX_TIMEOUT_SECONDS must be an integer"
    unset SOURCE_EXECUTOR_ACPX_FALLBACK
    return 14
    ;;
esac
if [ "${SOURCE_EXECUTOR_ACPX_FALLBACK}" -lt 60 ] \
    || [ "${SOURCE_EXECUTOR_ACPX_FALLBACK}" -gt 18000 ]; then
  source_executor_timeout_budget_fail "EXECUTOR_ACPX_TIMEOUT_SECONDS must be between 60 and 18000"
  unset SOURCE_EXECUTOR_ACPX_FALLBACK
  return 14
fi

if ! SOURCE_EXECUTOR_ACPX_TIMEOUT="$(jq -er \
  --argjson fallback "${SOURCE_EXECUTOR_ACPX_FALLBACK}" '
  if type == "object" and .version == 1
      and ((has("acpx_timeout_seconds") | not)
        or (.acpx_timeout_seconds | type == "number" and . == floor
          and . >= 60 and . <= 18000))
  then (.acpx_timeout_seconds // $fallback | tostring)
  else error("invalid scheduler state") end
' "${EXECUTOR_SCHEDULER_STATE_FILE}" 2>/dev/null)"; then
  source_executor_timeout_budget_fail "executor scheduler state has an invalid timeout budget"
  unset SOURCE_EXECUTOR_ACPX_FALLBACK SOURCE_EXECUTOR_ACPX_TIMEOUT
  return 14
fi

OPENCLAW_SUBAGENT_TIMEOUT_SECONDS="${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS:-20400}"
case "${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS}" in
  ''|*[!0-9]*)
    source_executor_timeout_budget_fail "OPENCLAW_SUBAGENT_TIMEOUT_SECONDS must be an integer"
    unset SOURCE_EXECUTOR_ACPX_FALLBACK SOURCE_EXECUTOR_ACPX_TIMEOUT
    return 14
    ;;
esac
if [ "${OPENCLAW_SUBAGENT_TIMEOUT_SECONDS}" -lt 20400 ]; then
  source_executor_timeout_budget_fail "OPENCLAW_SUBAGENT_TIMEOUT_SECONDS must be at least 20400"
  unset SOURCE_EXECUTOR_ACPX_FALLBACK SOURCE_EXECUTOR_ACPX_TIMEOUT
  return 14
fi

EXECUTOR_ACPX_TIMEOUT_SECONDS="${SOURCE_EXECUTOR_ACPX_TIMEOUT}"
EXECUTOR_AGENT_TIMEOUT_SECONDS=$((EXECUTOR_ACPX_TIMEOUT_SECONDS + 3600))
EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS=$((EXECUTOR_ACPX_TIMEOUT_SECONDS + 3900))
EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS=$((EXECUTOR_ACPX_TIMEOUT_SECONDS + 4200))
STUCK_AFTER_MINUTES=$(( (EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS + 59) / 60 + 20 ))
export EXECUTOR_SCHEDULER_STATE_FILE EXECUTOR_ACPX_TIMEOUT_SECONDS
export OPENCLAW_SUBAGENT_TIMEOUT_SECONDS EXECUTOR_AGENT_TIMEOUT_SECONDS
export EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS
export STUCK_AFTER_MINUTES

unset SOURCE_EXECUTOR_ACPX_FALLBACK SOURCE_EXECUTOR_ACPX_TIMEOUT
unset -f source_executor_timeout_budget_fail
