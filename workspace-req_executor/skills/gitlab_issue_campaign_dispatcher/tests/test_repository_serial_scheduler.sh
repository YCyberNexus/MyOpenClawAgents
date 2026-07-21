#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
RECORD="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

TEST_PARENT="${TMPDIR:-/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TEST_PARENT}/req-executor-repository-serial.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"

# Omit EXECUTOR_MAX_CONCURRENCY so this also verifies the tracked default of
# ten parallel repositories.
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF

env_json="$(CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh")"
jq -e '.max_concurrency == 10' <<<"${env_json}" >/dev/null

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
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:$project,
      selector:{type:"single",iid:$iid},
      force_rerun_pr:false,
      dispatcher_callback_target:"agent:req_dispatcher:main",
      branch:null
    }' >"${batch_dir}/request.json"
  jq -cnS --arg project "${project}" --argjson iid "${iid}" \
    '{version:1,project:$project,iids:[$iid]}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS --arg batch_id "${batch_id}" '{
    version:1,
    terminal_counts_version:1,
    batch_id:$batch_id,
    status:"queued",
    matched_count:1,
    terminal_count:0,
    done_count:0,
    failed_count:0,
    timeout_count:0,
    skipped_count:0,
    next_snapshot_index:0,
    request_digest:"fixture-request",
    snapshot_digest:"fixture-snapshot",
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
  and .max_concurrency == 10
  and .active_count == 2
  and .available_slots == 8
  and [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"A",project:"group/repo",iid:1},
    {batch_id:"C",project:"other/repo",iid:3}
  ]
' <<<"${first}" >/dev/null

a_job_id="$(jq -r '.grants[] | select(.batch_id == "A") | .job_id' <<<"${first}")"
jq -e --arg job_id "${a_job_id}" '
  .memberships["0"].status == "pending"
  and .memberships["0"].blocked_by_job_id == $job_id
' "${SCHEDULER_ROOT}/batches/B/state.json" >/dev/null
jq -e '
  [.active_jobs[].project] | sort == ["group/repo","other/repo"]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

declare -A claim_tokens=()
while IFS= read -r job_id; do
  claim="$(CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${job_id}" STATUS=preparing \
    bash "${RECORD}")"
  claim_tokens["${job_id}"]="$(jq -r '.claim_token' <<<"${claim}")"
done < <(jq -r '.grants[].job_id' <<<"${first}")
a_claim_token="${claim_tokens[${a_job_id}]}"
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a_job_id}" STATUS=terminal \
  TERMINAL_STATUS=done CLAIM_TOKEN="${a_claim_token}" \
  bash "${RECORD}" >/dev/null

second="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .active_count == 2
  and .available_slots == 8
  and [.grants[] | {batch_id,project,iid}] == [
    {batch_id:"B",project:"group/repo",iid:2}
  ]
' <<<"${second}" >/dev/null
jq -e '
  .memberships["0"].status == "reserved"
  and (.memberships["0"] | has("blocked_by_job_id") | not)
' "${SCHEDULER_ROOT}/batches/B/state.json" >/dev/null

echo 'ok repository-serial issue scheduler with cross-repository parallelism'
