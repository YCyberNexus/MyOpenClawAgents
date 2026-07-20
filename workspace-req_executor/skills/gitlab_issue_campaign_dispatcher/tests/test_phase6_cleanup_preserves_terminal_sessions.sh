#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-cleanup.XXXXXX")"
export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export DISPATCHER_LOG_DIR="${TEST_ROOT}/log"
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT_URI="claw_gitlab%2Freq_executor_test"
export PROJECT="req_executor_test"
export REPO_PARENT_PATH="${TEST_ROOT}/repos"

mkdir -p "${DISPATCHER_LOG_DIR}" "${ISSUES_ROOT}/issue-10/executions"
printf '{}\n' >"${ISSUES_ROOT}/issue-10/state.json"
printf '{}\n' >"${ISSUES_ROOT}/issue-10/executions/execution-1.json"
printf '# summary\n' >"${ISSUES_ROOT}/issue-10/summary.md"

# shellcheck source=../scripts/_dispatch_lib.sh
source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

target="agent:req_executor:subagent:child"

for state_json in \
  '{"kill_subagent_on_terminal":true}' \
  '{"kill_subagent_on_terminal":false}'; do
  for status in done blocked failed timeout; do
    cleanup="$(phase6_decide_cleanup "${state_json}" 10 "${status}" "${target}")"
    action="$(printf '%s' "${cleanup}" | jq -r '.action')"
    reason="$(printf '%s' "${cleanup}" | jq -r '.reason')"
    if [ "${action}" != "skip" ] || [ "${reason}" != "preserve_terminal_evidence" ]; then
      echo "${status} cleanup should preserve the child session for diagnosis" >&2
      printf '%s\n' "${cleanup}" >&2
      exit 1
    fi
  done
done

echo "ok phase6 cleanup preserves terminal sessions"
