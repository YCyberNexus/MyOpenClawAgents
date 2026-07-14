#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SET_SLOTS="${SKILL_DIR}/scripts/set_executor_slots.sh"
SCHEDULER_ENV="${SKILL_DIR}/scripts/scheduler_env.sh"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-slots.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF

increase_output="$(printf '/slot 5\n' | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_SLOTS}")"
jq -e '
  . == {
    status:"success",slot_count:5,previous_slot_count:3,
    active_count:0,available_slots:5,draining:false
  }
' <<<"${increase_output}" >/dev/null
jq -e '.max_concurrency == 5' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

# Runtime state wins across later sessions even when their process environment
# still contains the deployment initialization value.
env_output="$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_CONCURRENCY=3 \
    bash "${SCHEDULER_ENV}"
)"
jq -e '.max_concurrency == 5' <<<"${env_output}" >/dev/null

reserve_output="$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_CONCURRENCY=3 \
    bash "${RESERVE}"
)"
jq -e '
  .status == "idle"
  and .active_count == 0
  and .available_slots == 5
  and .max_concurrency == 5
' <<<"${reserve_output}" >/dev/null

# Shrinking below active work is non-destructive: persist the new ceiling,
# report draining, and expose no free slots.
jq -c '
  .active_jobs = reduce range(1;5) as $n ({};
    .["job-\($n)"] = {
      job_id:"job-\($n)",physical_key:("group/repo#" + ($n | tostring)),
      project:"group/repo",iid:$n,branch:null,entry_mode:"auto",
      force_rerun_pr:false,status:"running",reservation_seq:$n,
      reserved_at:1,updated_at:1,claim_generation:1,
      claim_token:("token-" + ($n | tostring)),
      owner:{batch_id:("batch-" + ($n | tostring)),snapshot_index:0},
      memberships:[{batch_id:("batch-" + ($n | tostring)),snapshot_index:0}]
    })
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-active.json"
mv "${SCHEDULER_ROOT}/scheduler_state.with-active.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
shrink_output="$(printf '/slot 2\n' | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_SLOTS}")"
jq -e '
  .slot_count == 2
  and .previous_slot_count == 5
  and .active_count == 4
  and .available_slots == 0
  and .draining == true
' <<<"${shrink_output}" >/dev/null
jq -e '.max_concurrency == 2 and (.active_jobs | length) == 4' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
draining_reserve_output="$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_CONCURRENCY=99 \
    bash "${RESERVE}"
)"
jq -e '
  .status == "at_capacity"
  and .grants == []
  and .active_count == 4
  and .available_slots == 0
  and .max_concurrency == 2
' <<<"${draining_reserve_output}" >/dev/null

before_invalid="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
for invalid_command in '/slot 0' '/slot -1' '/slot 2 extra' $'/slot 2\nextra'; do
  invalid_output="$(printf '%s\n' "${invalid_command}" \
    | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_SLOTS}")"
  jq -e '.status == "failed" and (.reason | startswith("usage:"))' \
    <<<"${invalid_output}" >/dev/null
done
after_invalid="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
[ "${before_invalid}" = "${after_invalid}" ] \
  || { echo 'invalid /slot command changed scheduler state' >&2; exit 1; }

# A slot update racing a recoverable scheduler transaction must update both
# the visible state and the transaction's final scheduler state.
jq -c '
  .active_jobs = {}
  | .pending_transaction = {
      scheduler_state:{
        version:1,round_robin_cursor:null,active_jobs:{},batch_order:[],
        max_concurrency:.max_concurrency
      }
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-transaction.json"
mv "${SCHEDULER_ROOT}/scheduler_state.with-transaction.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
printf '/slot 4\n' | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_SLOTS}" >/dev/null
jq -e '
  .max_concurrency == 4
  and .pending_transaction.scheduler_state.max_concurrency == 4
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

echo 'ok runtime slot control'
