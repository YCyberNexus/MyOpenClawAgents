#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
RECORD="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"
SET_REPO_SLOTS="${SKILL_DIR}/scripts/set_executor_repo_slots.sh"

TEST_PARENT="${TMPDIR:-/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TEST_PARENT}/req-executor-repository-configurable.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=1
EXECUTOR_MAX_ISSUES_PER_REPOSITORY=2
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF

CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

create_fixture() {
  local batch_id="$1"
  local project="$2"
  local iid="$3"
  local batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"

  mkdir -p "${batch_dir}"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg project "${project}" \
    --argjson iid "${iid}" '{
      version:1,batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:$project,selector:{type:"single",iid:$iid},
      force_rerun_pr:false,dispatcher_callback_target:"agent:req_dispatcher:main",
      branch:null
    }' >"${batch_dir}/request.json"
  jq -cnS --arg project "${project}" --argjson iid "${iid}" \
    '{version:1,project:$project,iids:[$iid]}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS --arg batch_id "${batch_id}" '{
    version:1,terminal_counts_version:1,batch_id:$batch_id,status:"queued",
    matched_count:1,terminal_count:0,done_count:0,failed_count:0,
    timeout_count:0,skipped_count:0,next_snapshot_index:0,
    request_digest:"fixture-request",snapshot_digest:"fixture-snapshot",
    memberships:{}
  }' >"${batch_dir}/state.json"
}

create_fixture A group/repo 1
create_fixture B group/repo 2
create_fixture C other/repo 3
jq '.batch_order = ["A","B","C"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

first="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .status == "ready"
  and .max_concurrency == 1
  and .max_issues_per_repository == 2
  and .active_count == 1
  and .available_slots == 0
  and [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"A",project:"group/repo",iid:1},
    {batch_id:"B",project:"group/repo",iid:2}
  ]
' <<<"${first}" >/dev/null
jq -e '
  [.active_jobs[].project] == ["group/repo","group/repo"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '.next_snapshot_index == 0 and .memberships == {}' \
  "${SCHEDULER_ROOT}/batches/C/state.json" >/dev/null

# The control command persists immediately but does not cancel or delete work.
shrink="$(printf '/repo-slot 1\n' \
  | CONFIG_DIR="${CONFIG_DIR}" bash "${SET_REPO_SLOTS}")"
jq -e '
  .per_repository_issue_limit == 1
  and .active_repository_count == 1
  and .active_issue_count == 2
  and .over_limit_repository_count == 1
  and .draining == true
' <<<"${shrink}" >/dev/null
jq -e '.active_jobs | length == 2' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

# The next scheduler pass keeps the oldest reservation and safely returns the
# excess tokenless reservation to pending under the new limit.
draining="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
a_job_id="$(jq -r '.grants[0].job_id' <<<"${draining}")"
jq -e '
  .max_issues_per_repository == 1
  and .active_count == 1
  and .available_slots == 0
  and [.grants[] | {batch_id,iid}] == [{batch_id:"A",iid:1}]
' <<<"${draining}" >/dev/null
jq -e --arg job_id "${a_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/B/state.json" >/dev/null

claim="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a_job_id}" STATUS=preparing \
  bash "${RECORD}")"
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done CLAIM_TOKEN="$(jq -r '.claim_token' <<<"${claim}")" \
  bash "${RECORD}" >/dev/null

next="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"C",project:"other/repo",iid:3}
  ]
' <<<"${next}" >/dev/null
c_job_id="$(jq -r '.grants[0].job_id' <<<"${next}")"
c_claim="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${c_job_id}" STATUS=preparing \
  bash "${RECORD}")"
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${c_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done CLAIM_TOKEN="$(jq -r '.claim_token' <<<"${c_claim}")" \
  bash "${RECORD}" >/dev/null

after_fair_turn="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"B",project:"group/repo",iid:2}
  ]
' <<<"${after_fair_turn}" >/dev/null

echo 'ok configurable per-repository Issue concurrency with serial default'
