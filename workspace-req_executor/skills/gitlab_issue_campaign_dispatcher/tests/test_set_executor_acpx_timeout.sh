#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SET_TIMEOUT="${SKILL_DIR}/scripts/set_executor_acpx_timeout.sh"
SCHEDULER_ENV="${SKILL_DIR}/scripts/scheduler_env.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-acpx-timeout.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_ACPX_TIMEOUT_SECONDS=3600
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF

initial_output="$(printf '/acpx-timeout 1h\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_TIMEOUT}")"
jq -e '
  . == {
    status:"success",acpx_timeout_seconds:3600,
    previous_acpx_timeout_seconds:3600,
    executor_agent_timeout_seconds:7200,
    exec_tool_timeout_seconds:7500,
    queue_launch_reclaim_seconds:7800,
    stuck_after_minutes:150,active_count:0,
    applies_to:"future_attempts"
  }
' <<<"${initial_output}" >/dev/null

increase_output="$(printf '/acpx-timeout 90m\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_TIMEOUT}")"
jq -e '
  .status == "success"
  and .acpx_timeout_seconds == 5400
  and .previous_acpx_timeout_seconds == 3600
  and .executor_agent_timeout_seconds == 9000
  and .exec_tool_timeout_seconds == 9300
  and .queue_launch_reclaim_seconds == 9600
  and .stuck_after_minutes == 180
  and .active_count == 0
  and .applies_to == "future_attempts"
' <<<"${increase_output}" >/dev/null
jq -e '.acpx_timeout_seconds == 5400' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '.acpx_timeout_seconds == 5400' <<<"$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_ACPX_TIMEOUT_SECONDS=3600 \
    bash "${SCHEDULER_ENV}"
)" >/dev/null

before_invalid="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
for invalid_command in \
  '/acpx-timeout 59' \
  '/acpx-timeout 0' \
  '/acpx-timeout 6h' \
  '/acpx-timeout 1H' \
  '/acpx-timeout 1h extra' \
  $'/acpx-timeout 1h\nextra'
do
  invalid_output="$(printf '%s\n' "${invalid_command}" \
    | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_TIMEOUT}")"
  jq -e '.status == "failed"' <<<"${invalid_output}" >/dev/null
done
[ "${before_invalid}" = "$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")" ] \
  || { echo 'invalid timeout command changed scheduler state' >&2; exit 1; }

jq -c '
  .active_jobs = {"job-1":{}}
  | .pending_transaction = {
      scheduler_state:{
        version:1,round_robin_cursor:null,active_jobs:{"job-1":{}},
        batch_order:[],acpx_timeout_seconds:.acpx_timeout_seconds
      }
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-transaction.json"
mv "${SCHEDULER_ROOT}/scheduler_state.with-transaction.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
transaction_output="$(printf '/acpx-timeout 3600s\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_TIMEOUT}")"
jq -e '.active_count == 1 and .acpx_timeout_seconds == 3600' \
  <<<"${transaction_output}" >/dev/null
jq -e '
  .acpx_timeout_seconds == 3600
  and .pending_transaction.scheduler_state.acpx_timeout_seconds == 3600
  and (.active_jobs | length) == 1
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

echo 'ok runtime acpx timeout control'
