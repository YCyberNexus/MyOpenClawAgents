#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SET_REPO_SLOTS="${SKILL_DIR}/scripts/set_executor_repo_slots.sh"
SCHEDULER_ENV="${SKILL_DIR}/scripts/scheduler_env.sh"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-repo-slots.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"

printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  'EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1' \
  'EXECUTOR_RUNNING_LEASE_SECONDS=21600' \
  'EXECUTOR_AGENT=req_executor' \
  'DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main' \
  'DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0' \
  >"${CONFIG_DIR}/campaign_defaults.env"

increase_output="$(printf '/repo-slot 3\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_REPO_SLOTS}")"
jq -e '
  . == {
    status:"success",per_repository_issue_limit:3,
    previous_per_repository_issue_limit:1,
    active_repository_count:0,active_issue_count:0,
    over_limit_repository_count:0,draining:false
  }
' <<<"${increase_output}" >/dev/null
jq -e '.max_issues_per_repository == 3' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

env_output="$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1 \
    bash "${SCHEDULER_ENV}"
)"
jq -e '.max_issues_per_repository == 3' <<<"${env_output}" >/dev/null

reserve_output="$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1 \
    bash "${RESERVE}"
)"
jq -e '
  .status == "idle"
  and .active_count == 0
  and .available_slots == 3
  and .max_concurrency == 3
  and .max_issues_per_repository == 3
' <<<"${reserve_output}" >/dev/null

# Shrinking below current repository occupancy is non-destructive for started
# work. The next reservation pass drains excess tokenless reservations while
# preserving preparing/running jobs.
jq -c '
  .active_jobs = reduce range(1;5) as $n ({};
    .["job-\($n)"] = {
      job_id:("job-" + ($n | tostring)),
      physical_key:("group/repo#" + ($n | tostring)),
      project:"group/repo",iid:$n,branch:null,entry_mode:"auto",
      force_rerun_pr:false,auto_merge:false,merge_target_branch:null,
      status:(if $n < 3 then "running" else "reserved" end),
      reservation_seq:$n,reserved_at:1,updated_at:1,
      claim_generation:(if $n < 3 then 1 else 0 end),
      claim_token:(if $n < 3 then ("token-" + ($n | tostring)) else null end),
      owner:{batch_id:("batch-" + ($n | tostring)),snapshot_index:0},
      memberships:[{batch_id:("batch-" + ($n | tostring)),snapshot_index:0}]
    })
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-active.json"
mv "${SCHEDULER_ROOT}/scheduler_state.with-active.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

shrink_output="$(printf '/repo-slot 1\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_REPO_SLOTS}")"
jq -e '
  .per_repository_issue_limit == 1
  and .previous_per_repository_issue_limit == 3
  and .active_repository_count == 1
  and .active_issue_count == 4
  and .over_limit_repository_count == 1
  and .draining == true
' <<<"${shrink_output}" >/dev/null
jq -e '
  .max_issues_per_repository == 1
  and (.active_jobs | length) == 4
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

before_invalid="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
for invalid_command in \
  '/repo-slot 0' '/repo-slot -1' '/repo-slot 2 extra' $'/repo-slot 2\nextra'
do
  invalid_output="$(printf '%s\n' "${invalid_command}" \
    | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_REPO_SLOTS}")"
  jq -e '.status == "failed" and (.reason | startswith("usage:"))' \
    <<<"${invalid_output}" >/dev/null
done
after_invalid="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
[ "${before_invalid}" = "${after_invalid}" ] \
  || { echo 'invalid /repo-slot command changed scheduler state' >&2; exit 1; }

# A runtime update must also patch the recoverable transaction image.
jq -c '
  .active_jobs = {}
  | .pending_transaction = {
      scheduler_state:{
        version:1,round_robin_cursor:null,active_jobs:{},batch_order:[],
        max_concurrency:.max_concurrency,
        max_issues_per_repository:.max_issues_per_repository
      }
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.with-transaction.json"
mv "${SCHEDULER_ROOT}/scheduler_state.with-transaction.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
printf '/repo-slot 4\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_REPO_SLOTS}" >/dev/null
jq -e '
  .max_issues_per_repository == 4
  and .pending_transaction.scheduler_state.max_issues_per_repository == 4
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

echo 'ok runtime per-repository Issue slot control'
