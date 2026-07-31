#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TICK_SCRIPT="${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
RECORD_RESULT_SCRIPT="${SKILL_DIR}/scripts/record_executor_batch_spawn.sh"

fail() {
  echo "test_executor_batch_tick.sh: $*" >&2
  exit 1
}

test_sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

test_file_mode() {
  local path="$1"
  stat -f '%Lp' "${path}" 2>/dev/null \
    || stat -c '%a' "${path}" 2>/dev/null
}

write_attempt_finalized_marker() {
  local log_dir="$1" iid="$2" execution_id="$3" work_branch="$4"
  local commit_sha="$5" completed_at_epoch="$6" result_sha256
  result_sha256="$(test_sha256_file "${log_dir}/worker_result.json")"
  jq -cnS \
    --argjson iid "${iid}" \
    --argjson execution_id "${execution_id}" \
    --arg work_branch "${work_branch}" \
    --arg commit_sha "${commit_sha}" \
    --arg worker_result_sha256 "${result_sha256}" \
    --argjson completed_at_epoch "${completed_at_epoch}" '{
      version:1,iid:$iid,execution_id:$execution_id,
      work_branch:$work_branch,commit_sha:$commit_sha,
      worker_result_sha256:$worker_result_sha256,
      completed_at_epoch:$completed_at_epoch
    }' >"${log_dir}/attempt_finalized.json"
  chmod 600 "${log_dir}/attempt_finalized.json"
}

[ -x "${TICK_SCRIPT}" ] || fail "run_executor_batch_tick.sh is missing or not executable"
[ -x "${RECORD_RESULT_SCRIPT}" ] || fail "record_executor_batch_spawn.sh is missing or not executable"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-batch-tick.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_BIN="${TEST_ROOT}/fake-bin"
REAL_GIT_BIN="$(command -v git)"
ORDER_LOG="${TEST_ROOT}/order.log"
SPAWN_SENTINEL="${TEST_ROOT}/sessions-spawn-called"
RESERVE_COUNT_FILE="${TEST_ROOT}/reserve-count"
mkdir -p "${CONFIG_DIR}" "${SCHEDULER_ROOT}/batches/A" "${FAKE_BIN}" \
  "${TEST_ROOT}/repos/group/repo/.git"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=tick-fixture-secret
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":["A"]}
EOF
cat >"${SCHEDULER_ROOT}/batches/A/request.json" <<'EOF'
{"version":1,"batch_id":"A","project":"group/repo","dispatcher_callback_target":"agent:req_dispatcher:main"}
EOF

# Cold batch directories are retained for direct idempotent lookup but must not
# participate in each tick's project scan. Invalid sentinels make this a
# deterministic scale regression: a historical-directory glob would fail.
for historical_index in $(seq 1 256); do
  historical_dir="${SCHEDULER_ROOT}/batches/HIST-${historical_index}"
  mkdir -p "${historical_dir}"
  printf '%s\n' '{"historical":true}' >"${historical_dir}/request.json"
done

write_fake() {
  local name="$1"
  shift
  cat >"${FAKE_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$*
EOF
  chmod +x "${FAKE_BIN}/${name}"
}

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${ARCHIVE_RECOVERY_TEST:-0}" = 1 ]; then
  for git_arg in "$@"; do
    if [ "${git_arg}" = ls-remote ]; then
      printf '%s\trefs/heads/%s\n' \
        "${ARCHIVE_RECOVERY_REMOTE_SHA:?}" \
        "${ARCHIVE_RECOVERY_WORK_BRANCH:?}"
      exit 0
    fi
  done
fi
exec "${REAL_GIT_BIN:?}" "$@"
EOF
chmod +x "${FAKE_BIN}/git"

write_fake scheduler_env.sh '
printf "%s\n" scheduler_env >>"${ORDER_LOG}"
export EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}"
export EXECUTOR_MAX_CONCURRENCY=3
export EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1
export SCHEDULER_STATE_FILE="${SCHEDULER_ROOT}/scheduler_state.json"
export SCHEDULER_LOCK_FILE="${SCHEDULER_ROOT}/scheduler.lock"
export BATCHES_ROOT="${SCHEDULER_ROOT}/batches"
export CALLBACK_INBOX="${SCHEDULER_ROOT}/callback_inbox"
export CALLBACK_OUTBOX="${SCHEDULER_ROOT}/callback_outbox"
mkdir -p "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}"
jq -cn --arg root "${SCHEDULER_ROOT}" "{scheduler_root:\$root,max_concurrency:3}"
'

write_fake resolve_driven_repo_path.sh '
printf "%s\n" "${TEST_ROOT}/repos/group/repo"
'

write_fake drain_driven_handoff_intents.sh '
printf "intent:%s/%s\n" "${GROUP}" "${PROJECT}" >>"${ORDER_LOG}"
jq -cn "{status:\"drained\",intent_count:0,results:[]}"
'

write_fake drain_driven_outbox.sh '
printf "%s\n" outbox >>"${ORDER_LOG}"
jq -cn "{status:\"drained\",scanned:0,attempted:0,delivered:0,failed:0}"
'

write_fake reconcile_driven_terminal_counts.sh '
printf "%s\n" reconcile >>"${ORDER_LOG}"
case "${RECONCILE_TEST_MODE:-ok}" in
  ok) jq -cn "{status:\"reconciled\",scanned:0,repaired:0,unresolved:0}" ;;
  partial) jq -cn "{status:\"partial\",scanned:1,repaired:0,unresolved:1}" ;;
  invalid_reconciled) jq -cn "{status:\"reconciled\",scanned:1,repaired:0,unresolved:1}" ;;
  invalid_partial) jq -cn "{status:\"partial\",scanned:0,repaired:0,unresolved:0}" ;;
  failed) exit 91 ;;
  *) exit 92 ;;
esac
'

write_fake reap_driven_orphan_placeholders.sh '
request="$(cat)"
printf "reap:%s\n" "$(jq -r ".protected_job_ids | join(\",\")" <<<"${request}")" >>"${ORDER_LOG}"
jq -cn "{status:\"reaped\",reaped_entries:[],protected_entries:[],unresolved_iids:[]}"
'

write_fake reserve_driven_batch_items.sh '
if [ "${SERIAL_GATE_RESERVE_SENTINEL:-0}" = 1 ]; then
  printf "%s\n" reserve-unexpected >>"${ORDER_LOG}"
  exit 98
fi
if [ "${FINALIZATION_GATE_TEST:-0}" = 1 ]; then
  printf "%s\n" reserve-finalization-gate >>"${ORDER_LOG}"
  jq -cn "{status:\"idle\",grants:[],active_count:1,available_slots:2}"
  exit 0
fi
count=0
[ ! -s "${RESERVE_COUNT_FILE}" ] || count="$(cat "${RESERVE_COUNT_FILE}")"
count=$((count + 1))
printf "%s" "${count}" >"${RESERVE_COUNT_FILE}"
printf "reserve:%s\n" "${count}" >>"${ORDER_LOG}"
if [ "${REFILL_BUDGET_TEST:-0}" = 1 ]; then
  snapshot_index=$((count - 1))
  iid=$((100 + count))
  jq -cn --arg count "${count}" \
    --argjson snapshot_index "${snapshot_index}" \
    --argjson iid "${iid}" "{
      status:\"ready\",
      grants:[{
        job_id:(\"B:snapshot-\" + \$count),batch_id:\"B\",
        snapshot_index:\$snapshot_index,project:\"group/repo\",iid:\$iid,
        branch:null,entry_mode:\"auto\",force_rerun_pr:false
      }],
      active_count:1,available_slots:1
    }"
  exit 0
fi
case "${count}" in
  1)
    jq -cn "{
      status:\"ready\",
      grants:[
        {job_id:\"A:snapshot-0\",batch_id:\"A\",snapshot_index:0,project:\"group/repo\",iid:42,branch:null,entry_mode:\"auto\",force_rerun_pr:false},
        {job_id:\"A:snapshot-1\",batch_id:\"A\",snapshot_index:1,project:\"group/repo\",iid:43,branch:null,entry_mode:\"auto\",force_rerun_pr:false}
      ],
      active_count:2,
      available_slots:1
    }"
    ;;
  2)
    jq -cn "{
      status:\"ready\",
      grants:[
        {job_id:\"A:snapshot-2\",batch_id:\"A\",snapshot_index:2,project:\"group/repo\",iid:44,branch:null,entry_mode:\"auto\",force_rerun_pr:false}
      ],
      active_count:2,
      available_slots:1
    }"
    ;;
  *) jq -cn "{status:\"idle\",grants:[],active_count:2,available_slots:1}" ;;
esac
'

write_fake dispatch_driven_topup.sh '
request="$(cat)"
jobs="$(jq -r ".grants | map(.job_id) | join(\",\")" <<<"${request}")"
sha42="$(printf "%064d" 42)"
sha44="$(printf "%064d" 44)"
printf "topup:%s\n" "${jobs}" >>"${ORDER_LOG}"
if [ "${REFILL_BUDGET_TEST:-0}" = 1 ]; then
  jq -cn --argjson grant "$(jq -c '.grants[0]' <<<"${request}")" "{
    status:\"no_eligible_iids\",dispatch_entries:[],pending_iids:[],
    skipped_entries:[(\$grant | {
      job_id,batch_id,snapshot_index,project,iid,
      status:\"skipped\",reason:\"closed\"
    })]
  }"
  exit 0
fi
case "${jobs}" in
  A:snapshot-0,A:snapshot-1)
    jq -cn "{
      status:\"ready\",
      dispatch_entries:[{
        iid:42,execution_id:1,child_label:\"#42-att-001\",
        payload_path:\"${TEST_ROOT}/payload-42.txt\",
        expected_task_sha256:\"${sha42}\",expected_task_bytes:42,
        job_id:\"A:snapshot-0\",batch_id:\"A\",snapshot_index:0,
        memberships_source:\"scheduler_active_job\"
      }],
      pending_iids:[],
      skipped_entries:[{
        job_id:\"A:snapshot-1\",batch_id:\"A\",snapshot_index:1,
        project:\"group/repo\",iid:43,status:\"skipped\",
        reason:\"${FAKE_SKIP_REASON:-dependency_cycle}\"
      }]
    }"
    ;;
  A:snapshot-2)
    jq -cn "{
      status:\"ready\",
      dispatch_entries:[{
        iid:44,execution_id:1,child_label:\"#44-att-001\",
        payload_path:\"${TEST_ROOT}/payload-44.txt\",
        expected_task_sha256:\"${sha44}\",expected_task_bytes:44,
        job_id:\"A:snapshot-2\",batch_id:\"A\",snapshot_index:2,
        memberships_source:\"scheduler_active_job\"
      }],
      skipped_entries:[]
    }"
    ;;
  *) exit 96 ;;
esac
'

write_fake import_driven_skipped.sh '
entry="$(cat)"
printf "skip:%s:%s\n" "$(jq -r .job_id <<<"${entry}")" \
  "$(jq -r .reason <<<"${entry}")" >>"${ORDER_LOG}"
jq -cn --arg job_id "$(jq -r .job_id <<<"${entry}")" "{status:\"imported\",job_id:\$job_id}"
'

write_fake record_driven_batch_launch.sh '
printf "record:%s:%s\n" "${ACTION:-${STATUS:-}}" "${JOB_ID}" >>"${ORDER_LOG}"
case "${ACTION:-${STATUS:-}}:${JOB_ID}" in
  preparing:A:snapshot-0)
    jq -cn "{status:\"recorded\",job_id:\"A:snapshot-0\",job_status:\"preparing\",active_count:1,should_spawn:true,claim_generation:1,claim_token:\"private-claim-token\"}"
    ;;
  preparing:A:snapshot-2)
    jq -cn "{status:\"recorded\",job_id:\"A:snapshot-2\",job_status:\"preparing\",active_count:2,should_spawn:true,claim_generation:1,claim_token:\"private-claim-token-44\"}"
    ;;
  *) exit 97 ;;
esac
'

write_fake bind_driven_claim.sh '
printf "bind:%s:%s:%s\n" "${JOB_ID}" "${CLAIM_GENERATION}" "${CLAIM_TOKEN}" >>"${ORDER_LOG}"
jq -cn --arg job_id "${JOB_ID}" --argjson generation "${CLAIM_GENERATION}" \
  "{status:\"bound\",iid:42,job_id:\$job_id,claim_generation:\$generation}"
'

write_fake dispatch_record_spawn.sh '
printf "project-record:%s:%s\n" "${STATUS}" "${IID}" >>"${ORDER_LOG}"
[[ "${EXPECTED_TASK_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || exit 95
[[ "${EXPECTED_TASK_BYTES:-}" =~ ^[1-9][0-9]*$ ]] || exit 95
if [ "${STATUS}" = spawned ]; then
  jq -cn --argjson iid "${IID}" --argjson attempt "${EXECUTION_ID}" \
    "{status:\"spawned\",iid:\$iid,execution_id:\$attempt,remaining_pending_count:1,chat_summary:\"recorded\"}"
else
  jq -cn --argjson iid "${IID}" --argjson attempt "${EXECUTION_ID}" \
    "{status:\"launch_failed_recorded\",iid:\$iid,execution_id:\$attempt,final_status:\"blocked\",cleanup:{action:\"skip\",target:\"\",reason:\"no_child_session_key\"},remaining_pending_count:0,chat_summary:\"recorded\"}"
fi
'

write_fake sessions_spawn '
: >"${SPAWN_SENTINEL}"
exit 99
'

write_fake expire_running.sh '
if [ "${DRIVEN_RESULT_RECONCILE:-0}" = 1 ]; then
  worker_result="$(cat)"
  printf "result:%s:%s:%s\n" \
    "${DRIVEN_RECONCILE_JOB_ID}" "${DRIVEN_RECONCILE_CLAIM_GENERATION}" \
    "${DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256}" >>"${ORDER_LOG}"
  if [ "${RESULT_TEST_SHARED_MR_PENDING:-0}" = 1 ]; then
    jq -e --argjson iid "${IID}" \
      ".iid == \$iid and .status == \"blocked\"" \
      <<<"${worker_result}" >/dev/null
    jq -cn --argjson iid "${IID}" \
      "{
        callback_status:\"handled\",iid:\$iid,execution_id:6,
        terminal_status:\"blocked\",merge_request_url:\"\",
        block_reason:\"shared MR marker is pending\",
        cleanup:{action:\"skip\",target:\"\",reason:\"claim retained for shared MR recovery\"},
        remaining_pending_iids:[\$iid],campaign_status:\"running\",
        chat_summary:\"shared MR finalization retained\"
      }"
    exit 0
  fi
  jq -e --argjson iid "${IID}" \
    ".iid == \$iid and .status == \"done\"" <<<"${worker_result}" >/dev/null
  if [ "${RACE_TEST_DURABLE_IMPORT:-0}" = 1 ]; then
    race_claim_token="$(jq -r --arg job_id "${DRIVEN_RECONCILE_JOB_ID}" \
      ".active_jobs[\$job_id].claim_token" \
      "${SCHEDULER_ROOT}/scheduler_state.json")"
    race_mr_url="$(jq -r .merge_request_url <<<"${worker_result}")"
    race_handoff_dir="${SCHEDULER_ROOT}/race-handoffs"
    race_handoff_file="${race_handoff_dir}/${DRIVEN_RECONCILE_JOB_ID}:claim-${DRIVEN_RECONCILE_CLAIM_GENERATION}:terminal-1.json"
    mkdir -p "${race_handoff_dir}"
    jq -cnS \
      --arg event_id "${DRIVEN_RECONCILE_JOB_ID}:claim-${DRIVEN_RECONCILE_CLAIM_GENERATION}:terminal-1" \
      --arg job_id "${DRIVEN_RECONCILE_JOB_ID}" \
      --argjson claim_generation "${DRIVEN_RECONCILE_CLAIM_GENERATION}" \
      --arg claim_token "${race_claim_token}" \
      --arg project "${RACE_PROJECT:?}" \
      --argjson iid "${IID}" \
      --arg mr_url "${race_mr_url}" \
      "{
        version:1,event_id:\$event_id,job_id:\$job_id,memberships:[],
        memberships_source:\"scheduler_active_job\",
        claim_generation:\$claim_generation,claim_token:\$claim_token,
        project:\$project,iid:\$iid,status:\"done\",mr_url:\$mr_url,reason:null
      }" >"${race_handoff_file}"
    CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${race_handoff_file}" \
      NOW_EPOCH="${RACE_IMPORT_NOW_EPOCH:-2000000001}" \
      bash "${RACE_REAL_IMPORT_HANDOFF_CMD:?}" >/dev/null
  elif [ "${RESULT_TEST_RELEASE:-0}" = 1 ]; then
    jq --arg job_id "${DRIVEN_RECONCILE_JOB_ID}" \
      "del(.active_jobs[\$job_id])" "${SCHEDULER_ROOT}/scheduler_state.json" \
      >"${SCHEDULER_ROOT}/scheduler_state.result.json"
    mv "${SCHEDULER_ROOT}/scheduler_state.result.json" \
      "${SCHEDULER_ROOT}/scheduler_state.json"
  fi
  jq -cn --argjson iid "${IID}" \
    "{callback_status:\"handled\",iid:\$iid,terminal_status:\"done\",cleanup:{action:\"kill\",target:\"agent:req_executor:subagent:42\",reason:\"durable_worker_result_recovered\"}}"
  exit 0
fi
if [ "${DRIVEN_MARKER_RECONCILE:-0}" = 1 ]; then
  printf "marker:%s:%s:%s\n" \
    "${DRIVEN_RECONCILE_JOB_ID}" "${DRIVEN_RECONCILE_CLAIM_GENERATION}" \
    "${DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256}" >>"${ORDER_LOG}"
  case "${MARKER_TEST_STATUS:-marker_not_ready}" in
    marker_not_ready)
      jq -cn --argjson iid "${IID}" \
        "{callback_status:\"marker_not_ready\",iid:\$iid}"
      ;;
    blocked)
      jq -cn --argjson iid "${IID}" \
        "{callback_status:\"handled\",iid:\$iid,terminal_status:\"blocked\"}"
      ;;
    done)
      if [ "${MARKER_TEST_RELEASE:-0}" = 1 ]; then
        jq --arg job_id "${DRIVEN_RECONCILE_JOB_ID}" \
          "del(.active_jobs[\$job_id])" "${SCHEDULER_ROOT}/scheduler_state.json" \
          >"${SCHEDULER_ROOT}/scheduler_state.marker.json"
        mv "${SCHEDULER_ROOT}/scheduler_state.marker.json" \
          "${SCHEDULER_ROOT}/scheduler_state.json"
      fi
      jq -cn --argjson iid "${IID}" \
        "{callback_status:\"handled\",iid:\$iid,terminal_status:\"done\"}"
      ;;
    *) exit 94 ;;
  esac
  exit 0
fi
if [ "${DRIVEN_COMPLETED_RECONCILE:-0}" = 1 ]; then
  printf "completed:%s:%s:%s\n" \
    "${DRIVEN_RECONCILE_JOB_ID}" "${DRIVEN_RECONCILE_CLAIM_GENERATION}" \
    "${DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256}" >>"${ORDER_LOG}"
  if [ "${RACE_TEST_DURABLE_IMPORT:-0}" = 1 ]; then
    race_skip_entry="$(jq -cnS \
      --arg job_id "${DRIVEN_RECONCILE_JOB_ID}" \
      --arg batch_id "${RACE_BATCH_ID:?}" \
      --argjson snapshot_index "${RACE_SNAPSHOT_INDEX:-0}" \
      --arg project "${RACE_PROJECT:?}" \
      --argjson iid "${IID}" \
      "{
        job_id:\$job_id,batch_id:\$batch_id,snapshot_index:\$snapshot_index,
        project:\$project,iid:\$iid,status:\"skipped\",reason:\"pr\"
      }")"
    printf "%s" "${race_skip_entry}" | CONFIG_DIR="${CONFIG_DIR}" \
      bash "${RACE_REAL_IMPORT_SKIP_CMD:?}" >/dev/null
    jq -cn --argjson iid "${IID}" \
      "{callback_status:\"handled\",iid:\$iid,terminal_status:\"skipped\"}"
  elif [ "${COMPLETION_TEST_RELEASE:-0}" = 1 ]; then
    jq --arg job_id "${DRIVEN_RECONCILE_JOB_ID}" \
      "del(.active_jobs[\$job_id])" "${SCHEDULER_ROOT}/scheduler_state.json" \
      >"${SCHEDULER_ROOT}/scheduler_state.completed.json"
    mv "${SCHEDULER_ROOT}/scheduler_state.completed.json" \
      "${SCHEDULER_ROOT}/scheduler_state.json"
    jq -cn --argjson iid "${IID}" \
      "{callback_status:\"handled\",iid:\$iid,terminal_status:\"skipped\"}"
  else
    jq -cn --argjson iid "${IID}" \
      "{callback_status:\"not_completed\",iid:\$iid}"
  fi
  exit 0
fi
printf "timeout:%s:%s:%s\n" \
  "${DRIVEN_TIMEOUT_JOB_ID}" "${DRIVEN_TIMEOUT_CLAIM_GENERATION}" \
  "${DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256}" >>"${ORDER_LOG}"
if [ "${TIMEOUT_TEST_RELEASE:-0}" = 1 ]; then
  jq --arg job_id "${DRIVEN_TIMEOUT_JOB_ID}" \
    "del(.active_jobs[\$job_id])" "${SCHEDULER_ROOT}/scheduler_state.json" \
    >"${SCHEDULER_ROOT}/scheduler_state.timeout.json"
  mv "${SCHEDULER_ROOT}/scheduler_state.timeout.json" \
    "${SCHEDULER_ROOT}/scheduler_state.json"
fi
jq -cn --argjson iid "${IID}" \
  "{callback_status:\"handled\",iid:\$iid,terminal_status:\"timeout\"}"
'

write_fake recover_shared_mr_finalization.sh '
printf "shared-mr-recovery:%s:%s:%s:%s:%s\n" \
  "${PROJECT}" "${GROUP}" "${ISSUE_IID}" "${EXECUTION_ID}" \
  "${WORK_BRANCH}" >>"${ORDER_LOG}"
issue_state="${REPO_PARENT_PATH}/${PROJECT}/.req_executor/issues/issue-${ISSUE_IID}/state.json"
commit_sha="$(jq -r ".mr_finalization.commit_sha" "${issue_state}")"
intent_id="$(jq -r ".mr_finalization.intent_id" "${issue_state}")"
target_branch="$(jq -r ".mr_finalization.target_branch" "${issue_state}")"
shared_role="$(jq -r ".mr_finalization.shared_branch_role" "${issue_state}")"
dependency_base_sha="$(jq -r ".dependency_base_sha // \"\"" "${issue_state}")"
mr_action=created
[ "${shared_role}" != tail ] || mr_action=reused
marker_dir="${REPO_PARENT_PATH}/${PROJECT}/.req_executor/.worktrees/issue-${ISSUE_IID}/.req_executor/issue-${ISSUE_IID}/log/execution-${EXECUTION_ID}"
mkdir -p "${marker_dir}"
jq -n \
  --argjson issue_iid "${ISSUE_IID}" \
  --argjson execution_id "${EXECUTION_ID}" \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${target_branch}" \
  --arg dependency_base_sha "${dependency_base_sha}" \
  --arg sha "${commit_sha}" \
  --arg intent_id "${intent_id}" \
  --arg mr_action "${mr_action}" "{
    version:1,iid:17,
    web_url:\"https://gitlab.example.test/group/repo/-/merge_requests/17\",
    source_branch:\$source_branch,target_branch:\$target_branch,
    dependency_base_sha:\$dependency_base_sha,sha:\$sha,
    shared_mr_intent_id:\$intent_id,
    observed_state:\"opened\",outcome:\"opened\",verified:true,
    mr_action:\$mr_action,issue_iid:\$issue_iid,
    execution_id:\$execution_id,auto_merge:false,
    merge_attempted:false,merge_api_succeeded:false,
    reason:\"shared MR verified open\"
  }" >"${marker_dir}/mr_result.json"
chmod 600 "${marker_dir}/mr_result.json"
jq -cn \
  --argjson iid "${ISSUE_IID}" \
  --argjson execution_id "${EXECUTION_ID}" \
  --arg commit_sha "${commit_sha}" \
  --arg intent_id "${intent_id}" \
  --arg mr_action "${mr_action}" "{
    status:\"verified_open\",iid:\$iid,execution_id:\$execution_id,
    commit_sha:\$commit_sha,intent_id:\$intent_id,
    merge_request_url:\"https://gitlab.example.test/group/repo/-/merge_requests/17\",
    mr_action:\$mr_action
  }"
'

# Deployment artifact copies can preserve readable shell content while losing
# executable mode bits. Every helper below is sourced or passed explicitly to
# Bash, so the heartbeat and post-spawn recorder must accept this safe shape.
chmod a-x "${FAKE_BIN}"/*.sh

printf '%s' 'secret-free spawn bootstrap for issue 42' >"${TEST_ROOT}/payload-42.txt"
printf '%s' 'secret-free spawn bootstrap for issue 44' >"${TEST_ROOT}/payload-44.txt"

run_tick() {
  : >"${ORDER_LOG}"
  : >"${RESERVE_COUNT_FILE}"
  CONFIG_DIR="${CONFIG_DIR}" \
  ORDER_LOG="${ORDER_LOG}" \
  TEST_ROOT="${TEST_ROOT}" \
  SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
  RESERVE_COUNT_FILE="${RESERVE_COUNT_FILE}" \
  REFILL_BUDGET_TEST="${REFILL_BUDGET_TEST:-0}" \
  ARCHIVE_RECOVERY_TEST="${ARCHIVE_RECOVERY_TEST:-0}" \
  ARCHIVE_RECOVERY_REMOTE_SHA="${ARCHIVE_RECOVERY_REMOTE_SHA:-}" \
  ARCHIVE_RECOVERY_WORK_BRANCH="${ARCHIVE_RECOVERY_WORK_BRANCH:-}" \
  REAL_GIT_BIN="${REAL_GIT_BIN}" \
  EXECUTOR_REFILL_ROUND_LIMIT="${EXECUTOR_REFILL_ROUND_LIMIT:-32}" \
  EXECUTOR_TOPUP_PHASE_SECONDS="${EXECUTOR_TOPUP_PHASE_SECONDS:-90}" \
  PATH="${FAKE_BIN}:${PATH}" \
  SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve_driven_repo_path.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_driven_handoff_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_driven_outbox.sh" \
  RECONCILE_COUNTS_CMD="${FAKE_BIN}/reconcile_driven_terminal_counts.sh" \
  REAP_PLACEHOLDERS_CMD="${FAKE_BIN}/reap_driven_orphan_placeholders.sh" \
  EXPIRE_RUNNING_CMD="${FAKE_BIN}/expire_running.sh" \
  RECOVER_SHARED_MR_CMD="${TEST_RECOVER_SHARED_MR_CMD:-${FAKE_BIN}/recover_shared_mr_finalization.sh}" \
  RESERVE_CMD="${TEST_RESERVE_CMD:-${FAKE_BIN}/reserve_driven_batch_items.sh}" \
  TOPUP_CMD="${FAKE_BIN}/dispatch_driven_topup.sh" \
  IMPORT_SKIP_CMD="${FAKE_BIN}/import_driven_skipped.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/record_driven_batch_launch.sh" \
  BIND_CLAIM_CMD="${FAKE_BIN}/bind_driven_claim.sh" \
    bash "${TICK_SCRIPT}"
}

set +e
invalid_recovery_command_output="$(
  TEST_RECOVER_SHARED_MR_CMD=relative/recover-shared-mr run_tick 2>&1
)"
invalid_recovery_command_rc=$?
set -e
[ "${invalid_recovery_command_rc}" -eq 2 ] \
  && grep -q 'RECOVER_SHARED_MR_CMD must be absolute' \
    <<<"${invalid_recovery_command_output}" \
  || fail "relative shared MR recovery command was not rejected"

archive_launch_actions() {
  local label="$1"
  if [ -d "${SCHEDULER_ROOT}/launch_actions" ]; then
    mv "${SCHEDULER_ROOT}/launch_actions" \
      "${SCHEDULER_ROOT}/launch_actions-${label}"
  fi
}

# Every child process started while holding the agent-wide tick lock is
# bounded by the remaining phase deadline. A hung reserve process must be
# killed, report a retryable tick failure, and release the lock for the next
# invocation.
write_fake hanging_reserve.sh '
sleep 30
'
hanging_started_at="$(date +%s)"
hanging_reserve_output="$(
  EXECUTOR_TOPUP_PHASE_SECONDS=1 \
  TEST_RESERVE_CMD="${FAKE_BIN}/hanging_reserve.sh" run_tick
)" || fail "hung reserve boundary tick crashed"
hanging_elapsed=$(( $(date +%s) - hanging_started_at ))
[ "${hanging_elapsed}" -le 5 ] \
  || fail "hung reserve held the global tick lock for ${hanging_elapsed}s"
jq -e '
  .status == "tick_failed"
  and .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "reservation" and .status == "timeout")] | length) == 1
  and ([.operation_results[] | select(
    .operation == "topup_budget" and .reason == "child_timeout")] | length) == 1
' <<<"${hanging_reserve_output}" >/dev/null \
  || fail "hung reserve did not fail safely within the outer deadline"

# A stream of distinct skip jobs must not drain an arbitrarily large batch
# while the agent-wide topup lock is held. Two refill rounds means exactly
# three reservations including the initial one; the following normal tick also
# proves that the bounded tick released its lock for retry.
refill_budget_output="$(
  REFILL_BUDGET_TEST=1 EXECUTOR_REFILL_ROUND_LIMIT=2 run_tick
)" || fail "bounded skip-refill tick failed"
[ "$(cat "${RESERVE_COUNT_FILE}")" = 3 ] \
  || fail "skip-refill round limit did not bound reserve calls"
[ "$(grep -c '^topup:B:snapshot-' "${ORDER_LOG}")" -eq 3 ] \
  && [ "$(grep -c '^skip:B:snapshot-' "${ORDER_LOG}")" -eq 3 ] \
  || fail "bounded skip-refill tick did not process exactly three jobs"
jq -e '
  .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "topup_budget"
    and .status == "partial"
    and .reason == "refill_round_limit"
    and .refill_round_limit == 2
    and .refill_rounds == 2
    and .items_processed == 3)] | length) == 1
' <<<"${refill_budget_output}" >/dev/null \
  || fail "skip-refill budget was not reported as bounded partial work"

tick_output="$(run_tick)" || fail "fixed executor batch tick failed"

expected_order='scheduler_env
reconcile
intent:group/repo
outbox
reap:
reserve:1
topup:A:snapshot-0,A:snapshot-1
skip:A:snapshot-1:dependency_cycle
reserve:2
topup:A:snapshot-2
record:preparing:A:snapshot-0
bind:A:snapshot-0:1:private-claim-token'
[ "$(cat "${ORDER_LOG}")" = "${expected_order}" ] \
  || fail "tick order violated recovery/outbox/reserve/topup/claim contract: $(cat "${ORDER_LOG}")"
[ ! -e "${SPAWN_SENTINEL}" ] || fail "shell tick wrapper called sessions_spawn"

jq -e '
  (keys | sort) == [
    "backoff_seconds","chat_summary","cleanup_actions",
    "max_launch_retries","operation_results","reconcile_actions",
    "spawn_grants","status"
  ]
  and .status == "ready"
  and .max_launch_retries == 3
  and .backoff_seconds == 2
  and .reconcile_actions == []
  and .cleanup_actions == []
  and (.spawn_grants | length) == 1
  and (.spawn_grants[0] | del(.child_label)) == {
    job_id:"A:snapshot-0",claim_generation:1,project:"group/repo",iid:42,
    execution_id:1,
    payload_path:"'"${TEST_ROOT}"'/payload-42.txt",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42
  }
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen1-[0-9a-f]{40}$"))
  and ([.operation_results[] | select(.operation == "synthetic_skip" and .job_id == "A:snapshot-1" and .status == "imported")] | length) == 1
  and ([.operation_results[] | select(.operation == "preparing" and .job_id == "A:snapshot-0" and .status == "ready")] | length) == 1
  and (tostring | contains("private-claim-token") | not)
  and (tostring | contains("secret-free spawn bootstrap") | not)
' <<<"${tick_output}" >/dev/null \
  || fail "tick did not return the strict claim-token-free spawn grant envelope: ${tick_output}"
jq -e '
  .stage == "topup_prepared"
  and .job_id == "A:snapshot-2"
  and .expected_task_sha256 == "0000000000000000000000000000000000000000000000000000000000000044"
  and .expected_task_bytes == 44
' "${SCHEDULER_ROOT}/launch_actions/$(printf '%s' 'A:snapshot-2' | shasum -a 256 | awk '{print $1}').json" >/dev/null \
  || fail "second coordinator action was not held before preparing"

partial_reconcile_output="$(
  RECONCILE_TEST_MODE=partial SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "partial terminal-count reconciliation did not return a fail-closed envelope"
jq -e '
  .status == "tick_failed"
  and .spawn_grants == []
  and .reconcile_actions == []
  and ([.operation_results[] | select(
    .operation == "terminal_count_reconcile"
    and .status == "partial"
    and .unresolved == 1)] | length) == 1
' <<<"${partial_reconcile_output}" >/dev/null \
  || fail "partial terminal-count reconciliation did not stop reservation"
[ "$(cat "${ORDER_LOG}")" = $'scheduler_env\nreconcile' ] \
  || fail "partial reconciliation continued into scheduler operations: $(cat "${ORDER_LOG}")"

for invalid_reconcile_mode in invalid_reconciled invalid_partial; do
  invalid_reconcile_output="$(
    RECONCILE_TEST_MODE="${invalid_reconcile_mode}" \
    SERIAL_GATE_RESERVE_SENTINEL=1 \
    run_tick
  )" || fail "contradictory reconciliation envelope crashed the tick"
  jq -e '
    .status == "tick_failed"
    and .spawn_grants == []
    and ([.operation_results[] | select(
      .operation == "terminal_count_reconcile"
      and .status == "failed")] | length) == 1
  ' <<<"${invalid_reconcile_output}" >/dev/null \
    || fail "contradictory reconciliation envelope was accepted: ${invalid_reconcile_mode}"
  [ "$(cat "${ORDER_LOG}")" = $'scheduler_env\nreconcile' ] \
    || fail "contradictory reconciliation reached scheduler operations: ${invalid_reconcile_mode}"
done

failed_reconcile_output="$(
  RECONCILE_TEST_MODE=failed SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "failed terminal-count reconciliation did not return a fail-closed envelope"
jq -e '
  .status == "tick_failed"
  and .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "terminal_count_reconcile"
    and .status == "failed")] | length) == 1
' <<<"${failed_reconcile_output}" >/dev/null \
  || fail "failed terminal-count reconciliation did not stop reservation"
[ "$(cat "${ORDER_LOG}")" = $'scheduler_env\nreconcile' ] \
  || fail "failed reconciliation continued into scheduler operations: $(cat "${ORDER_LOG}")"

serial_gate_output="$(SERIAL_GATE_RESERVE_SENTINEL=1 run_tick)" \
  || fail "durable emitted-action serial gate failed"
jq -e '
  .status == "idle"
  and .spawn_grants == []
  and .reconcile_actions == []
  and ([.operation_results[] | select(
    .operation == "spawn_ack"
    and .job_id == "A:snapshot-0"
    and .status == "pending")] | length) == 1
' <<<"${serial_gate_output}" >/dev/null \
  || fail "a prior unacknowledged spawn did not close the global launch gate"
if grep -q '^reserve' "${ORDER_LOG}"; then
  fail "global launch gate reached reservation before recording the prior spawn"
fi

deferred_callback_output="$(
  DEFER_DRIVEN_CALLBACK_DELIVERY=1 SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "callback-deferred intake tick failed"
if grep -q '^outbox$' "${ORDER_LOG}"; then
  fail "callback-deferred intake tick invoked the synchronous outbox transport"
fi
jq -e '
  ([.operation_results[] | select(
    .operation == "outbox_drain"
    and .status == "deferred"
    and .scanned == 0
    and .attempted == 0
    and .delivered == 0
    and .failed == 0)] | length) == 1
' <<<"${deferred_callback_output}" >/dev/null \
  || fail "callback-deferred intake tick did not expose its deferred operation"
archive_launch_actions initial

# A duplicate preparing observer must never bind or return a spawn grant.
cat >"${FAKE_BIN}/record_driven_batch_launch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "record:%s:%s\n" "${ACTION:-${STATUS:-}}" "${JOB_ID}" >>"${ORDER_LOG}"
jq -cn --arg job_id "${JOB_ID}" '{
  status:"recorded",job_id:$job_id,job_status:"preparing",active_count:1,
  should_spawn:false,claim_generation:null,claim_token:null
}'
EOF
chmod +x "${FAKE_BIN}/record_driven_batch_launch.sh"

suppressed_output="$(run_tick)" || fail "duplicate preparing tick failed"
jq -e '
  .status == "idle"
  and .spawn_grants == []
  and ([.operation_results[] | select(.operation == "preparing" and .job_id == "A:snapshot-0" and .status == "suppressed")] | length) == 1
' <<<"${suppressed_output}" >/dev/null \
  || fail "should_spawn=false was not strictly suppressed: ${suppressed_output}"
if grep -q '^bind:' "${ORDER_LOG}"; then
  fail "should_spawn=false still called bind_driven_claim.sh"
fi
archive_launch_actions suppressed

# A running physical job is a continuation candidate even with no fresh
# reservation. It must be driven by project campaign state without consuming a
# second scheduler slot or synthesizing a duplicate physical job.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","project":"group/repo","iid":42,
    "branch":null,"entry_mode":"auto","force_rerun_pr":false,
    "status":"running","owner":{"batch_id":"A","snapshot_index":0},
    "finalization":null
  }
}}
EOF
cat >"${FAKE_BIN}/reserve_driven_batch_items.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" reserve >>"${ORDER_LOG}"
jq -cn '{status:"at_capacity",grants:[],active_count:1,available_slots:2}'
EOF
chmod +x "${FAKE_BIN}/reserve_driven_batch_items.sh"
cat >"${FAKE_BIN}/dispatch_driven_topup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
request="\$(cat)"
printf "topup:%s\n" "\$(jq -r '.grants | map(.job_id) | join(",")' <<<"\${request}")" >>"\${ORDER_LOG}"
jq -cn '{
  status:"ready",
  dispatch_entries:[{
    iid:42,execution_id:2,child_label:"#42-att-002",
    payload_path:"${TEST_ROOT}/payload-42.txt",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    job_id:"A:snapshot-0",batch_id:"A",snapshot_index:0,
    memberships_source:"scheduler_active_job"
  }],
  skipped_entries:[]
}'
EOF
chmod +x "${FAKE_BIN}/dispatch_driven_topup.sh"
cat >"${FAKE_BIN}/record_driven_batch_launch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "record:%s:%s\n" "${ACTION:-${STATUS:-}}" "${JOB_ID}" >>"${ORDER_LOG}"
jq -cn --arg job_id "${JOB_ID}" '{
  status:"recorded",job_id:$job_id,job_status:"preparing",active_count:1,
  should_spawn:true,claim_generation:2,claim_token:"continuation-private-claim"
}'
EOF
chmod +x "${FAKE_BIN}/record_driven_batch_launch.sh"

continuation_output="$(run_tick)" || fail "running continuation tick failed"
jq -e '
  .status == "ready"
  and (.spawn_grants | length) == 1
  and .spawn_grants[0].job_id == "A:snapshot-0"
  and .spawn_grants[0].claim_generation == 2
  and .spawn_grants[0].execution_id == 2
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen2-[0-9a-f]{40}$"))
  and (tostring | contains("continuation-private-claim") | not)
' <<<"${continuation_output}" >/dev/null \
  || fail "running job was not continued without a fresh reservation: ${continuation_output}"
grep -q '^topup:A:snapshot-0$' "${ORDER_LOG}" \
  || fail "running job was not sent back through the project campaign"
archive_launch_actions continuation

# A live preflight may report that a continuation now looks closed/pr-labeled
# because the same still-running attempt just wrote its MR. While the exact
# project pending entry remains, the tick must preserve the current claim for
# the native callback or durable-result recovery instead of synthesizing skip.
: >"${ORDER_LOG}"
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","project":"group/repo","iid":42,
    "branch":null,"entry_mode":"auto","force_rerun_pr":false,
    "status":"running","owner":{"batch_id":"A","snapshot_index":0},
    "finalization":null,"claim_generation":2,
    "claim_token":"continuation-private-claim"
  }
}}
EOF
cat >"${FAKE_BIN}/dispatch_driven_topup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$(cat)"
printf "topup:%s\n" "$(jq -r '.grants | map(.job_id) | join(",")' <<<"${request}")" >>"${ORDER_LOG}"
jq -cn '{
  status:"ready",dispatch_entries:[],
  pending_iids:[42],
  skipped_entries:[{
    job_id:"A:snapshot-0",batch_id:"A",snapshot_index:0,
    project:"group/repo",iid:42,status:"skipped",reason:"pr"
  }]
}'
EOF
chmod +x "${FAKE_BIN}/dispatch_driven_topup.sh"
running_skip_output="$(COMPLETION_TEST_RELEASE=1 run_tick)" \
  || fail "running preflight-skip tick failed"
grep -q '^reap:A:snapshot-0$' "${ORDER_LOG}" \
  || fail "orphan reaper did not protect the current scheduler active job"
if grep -q '^completed:' "${ORDER_LOG}"; then
  fail "active pending continuation entered generic completion reconciliation"
fi
if grep -q 'continuation-private-claim' "${ORDER_LOG}" \
    || grep -q 'continuation-private-claim' <<<"${running_skip_output}"; then
  fail "suppressed running preflight exposed the private claim token"
fi
jq -e '
  .spawn_grants == []
  and ([.operation_results[]
    | select(.operation == "running_preflight_skip"
      and .job_id == "A:snapshot-0"
      and .project == "group/repo"
      and .iid == 42
      and .status == "suppressed_active_pending")]
    | length) == 1
  and ([.operation_results[]
    | select(.operation == "synthetic_skip" and .job_id == "A:snapshot-0")]
    | length) == 0
' <<<"${running_skip_output}" >/dev/null \
  || fail "running continuation preflight was not explicitly suppressed"
jq -e '
  .active_jobs["A:snapshot-0"].status == "running"
  and .active_jobs["A:snapshot-0"].claim_generation == 2
  and .active_jobs["A:snapshot-0"].claim_token == "continuation-private-claim"
  and (.active_jobs["A:snapshot-0"].finalization // null) == null
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "suppressed running preflight did not preserve the active claim"

# Deterministically reproduce the heartbeat race: the initial durable-result
# scan sees no worker result, then project topup publishes that result while
# also observing its freshly-created MR as a live-preflight skip. The first
# tick must retain the claim; the next durable-result pass imports done through
# the real scheduler handoff path, preserving its MR URL and terminal counters.
RACE_BATCH_ID=A
RACE_JOB_ID='A:snapshot-0'
RACE_PROJECT='group/repo'
RACE_CLAIM_TOKEN='race-private-claim'
RACE_MR_URL='https://gitlab.example.test/group/repo/-/merge_requests/42'
RACE_RESULT_LOG_DIR="${TEST_ROOT}/repos/group/repo/.req_executor/.worktrees/issue-42/.req_executor/issue-42/log/execution-7"
RACE_CAMPAIGN_DIR="${TEST_ROOT}/repos/group/repo/.req_executor/_dispatcher"
mkdir -p "${SCHEDULER_ROOT}/batches/${RACE_BATCH_ID}" \
  "${RACE_CAMPAIGN_DIR}" "${RACE_RESULT_LOG_DIR}"
jq -cnS \
  --arg batch_id "${RACE_BATCH_ID}" \
  --arg project "${RACE_PROJECT}" '{
  version:1,batch_id:$batch_id,correlation_id:"race-correlation",
  project:$project,selector:{type:"single",iid:42},force_rerun_pr:false,
  auto_merge:false,dispatcher_callback_target:"agent:req_dispatcher:main",
  executor_agent:"req_executor",callback_nonce:("d" * 64),branch:null,
  merge_target_branch:null
}' >"${SCHEDULER_ROOT}/batches/${RACE_BATCH_ID}/request.json"
jq -cnS --arg project "${RACE_PROJECT}" \
  '{version:1,project:$project,iids:[42]}' \
  >"${SCHEDULER_ROOT}/batches/${RACE_BATCH_ID}/snapshot.json"
jq -cnS \
  --arg batch_id "${RACE_BATCH_ID}" \
  --arg job_id "${RACE_JOB_ID}" '{
  version:1,terminal_counts_version:1,batch_id:$batch_id,status:"running",
  matched_count:1,terminal_count:0,done_count:0,failed_count:0,
  timeout_count:0,skipped_count:0,next_snapshot_index:1,
  request_digest:"race-request",snapshot_digest:"race-snapshot",
  memberships:{"0":{
    snapshot_index:0,iid:42,status:"running",job_id:$job_id
  }}
}' >"${SCHEDULER_ROOT}/batches/${RACE_BATCH_ID}/state.json"
jq -cnS \
  --arg batch_id "${RACE_BATCH_ID}" \
  --arg job_id "${RACE_JOB_ID}" \
  --arg project "${RACE_PROJECT}" \
  --arg claim_token "${RACE_CLAIM_TOKEN}" '{
  version:1,round_robin_cursor:$batch_id,batch_order:[$batch_id],
  active_jobs:{($job_id):{
    job_id:$job_id,physical_key:($project + "#42"),project:$project,iid:42,
    branch:null,entry_mode:"auto",force_rerun_pr:false,auto_merge:false,
    merge_target_branch:null,status:"running",reservation_seq:1,
    reserved_at:1,updated_at:2000000000,claim_generation:7,
    claim_token:$claim_token,finalization:null,
    owner:{batch_id:$batch_id,snapshot_index:0},
    memberships:[{batch_id:$batch_id,snapshot_index:0}]
  }}
}' >"${SCHEDULER_ROOT}/scheduler_state.json"
jq -cnS \
  --arg job_id "${RACE_JOB_ID}" \
  --arg batch_id "${RACE_BATCH_ID}" \
  --arg claim_token "${RACE_CLAIM_TOKEN}" '{
  project:"repo",repo_path:"unused",blocked_retry_limit:3,tick_seq:1,
  result_note_enabled:false,kill_subagent_on_terminal:false,
  pending_subagents:{"42":{
    execution_id:7,run_id:"race-run-42",
    child_session_key:"agent:req_executor:subagent:race-42",
    child_label:"#42-att-007",spawned_at:"2026-07-21T00:00:00Z",
    placeholder:false,acpx_timeout_seconds:18000,
    job_id:$job_id,batch_id:$batch_id,snapshot_index:0,
    branch:null,work_branch:"issue/42",entry_mode:"auto",
    force_rerun_pr:false,memberships_source:"scheduler_active_job",
    claim_generation:7,claim_token:$claim_token,
    bound_at:"2026-07-21T00:00:01Z"
  }},
  active_issue_iids:[42],active_issue_sessions:["issue-repo-42"],
  blocked_at_tick_by_iid:{},unfinished_iids:[],completed_iids:[],
  blocked_iids:[],failed_iids:[],timeout_iids:[],
  campaign_status:"waiting_for_callbacks"
}' >"${RACE_CAMPAIGN_DIR}/campaign_state.json"
cat >"${FAKE_BIN}/dispatch_driven_topup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
request="\$(cat)"
jq -e '
  [.grants[] | {job_id,project,iid}]
    == [{job_id:"${RACE_JOB_ID}",project:"${RACE_PROJECT}",iid:42}]
' <<<"\${request}" >/dev/null
printf "topup:%s\n" "\$(jq -r '.grants | map(.job_id) | join(",")' <<<"\${request}")" >>"\${ORDER_LOG}"
jq -cnS --arg log_dir "${RACE_RESULT_LOG_DIR}" --arg mr_url "${RACE_MR_URL}" '{
  iid:42,execution_id:7,status:"done",mode_actual:"fresh",
  work_branch:"issue/42",local_branch:"issue/42",
  commit_sha:"0123456789abcdef",merge_request_url:\$mr_url,
  mr_action:"created",wiki_url:"",labels_added:["pr"],
  labels_removed:["doing","done"],summary_posted:true,
  block_reason:"",log_dir:\$log_dir
}' >"${RACE_RESULT_LOG_DIR}/worker_result.json"
jq -cnS '{
  version:1,iid:42,execution_id:7,exit_code:0,completed_at_epoch:2000000000
}' >"${RACE_RESULT_LOG_DIR}/acpx_terminal.json"
if command -v sha256sum >/dev/null 2>&1; then
  result_sha256="\$(sha256sum "${RACE_RESULT_LOG_DIR}/worker_result.json" | awk '{print \$1}')"
else
  result_sha256="\$(shasum -a 256 "${RACE_RESULT_LOG_DIR}/worker_result.json" | awk '{print \$1}')"
fi
jq -cnS --arg result_sha256 "\${result_sha256}" '{
  version:1,iid:42,execution_id:7,work_branch:"issue/42",
  commit_sha:"0123456789abcdef",
  worker_result_sha256:\$result_sha256,
  completed_at_epoch:2000000000
}' >"${RACE_RESULT_LOG_DIR}/attempt_finalized.json"
chmod 600 "${RACE_RESULT_LOG_DIR}/attempt_finalized.json"
printf "%s\n" race-result-published >>"\${ORDER_LOG}"
jq -cn '{
  status:"ready",dispatch_entries:[],pending_iids:[42],
  skipped_entries:[{
    job_id:"${RACE_JOB_ID}",batch_id:"${RACE_BATCH_ID}",snapshot_index:0,
    project:"${RACE_PROJECT}",iid:42,status:"skipped",reason:"pr"
  }]
}'
EOF
chmod +x "${FAKE_BIN}/dispatch_driven_topup.sh"

race_preflight_output="$(
  RACE_TEST_DURABLE_IMPORT=1 \
  RACE_BATCH_ID="${RACE_BATCH_ID}" RACE_SNAPSHOT_INDEX=0 \
  RACE_PROJECT="${RACE_PROJECT}" \
  RACE_REAL_IMPORT_SKIP_CMD="${SKILL_DIR}/scripts/import_driven_skipped.sh" \
  RACE_REAL_IMPORT_HANDOFF_CMD="${SKILL_DIR}/scripts/import_driven_handoff.sh" \
  run_tick
)" || fail "deterministic active-result preflight race tick failed"
grep -qx 'race-result-published' "${ORDER_LOG}" \
  || fail "race fixture did not publish the durable result during topup"
if grep -q '^result:' "${ORDER_LOG}"; then
  fail "initial race tick saw a result that was published after its scan"
fi
if grep -q '^completed:' "${ORDER_LOG}"; then
  fail "initial race tick terminalized its own in-flight MR preflight"
fi
jq -e '
  .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "running_preflight_skip"
    and .job_id == "A:snapshot-0"
    and .status == "suppressed_active_pending")] | length) == 1
' <<<"${race_preflight_output}" >/dev/null \
  || fail "race tick did not suppress the active pending preflight skip"
jq -e --arg token "${RACE_CLAIM_TOKEN}" '
  .active_jobs["A:snapshot-0"].status == "running"
  and .active_jobs["A:snapshot-0"].claim_generation == 7
  and .active_jobs["A:snapshot-0"].claim_token == $token
  and (.active_jobs["A:snapshot-0"].finalization // null) == null
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "race tick did not retain the exact callback claim"
jq -e '
  .terminal_count == 0 and .done_count == 0 and .skipped_count == 0
' "${SCHEDULER_ROOT}/batches/${RACE_BATCH_ID}/state.json" >/dev/null \
  || fail "race preflight mutated terminal counters before result recovery"

race_recovery_output="$(
  RACE_TEST_DURABLE_IMPORT=1 \
  RACE_BATCH_ID="${RACE_BATCH_ID}" RACE_SNAPSHOT_INDEX=0 \
  RACE_PROJECT="${RACE_PROJECT}" \
  RACE_REAL_IMPORT_SKIP_CMD="${SKILL_DIR}/scripts/import_driven_skipped.sh" \
  RACE_REAL_IMPORT_HANDOFF_CMD="${SKILL_DIR}/scripts/import_driven_handoff.sh" \
  SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "retained race result recovery tick failed"
grep -Eq '^result:A:snapshot-0:7:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "retained durable result did not use the exact claim fence"
if grep -q '^completed:' "${ORDER_LOG}"; then
  fail "durable result recovery re-entered generic completion reconciliation"
fi
jq -e '
  .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "handled")] | length) == 1
' <<<"${race_recovery_output}" >/dev/null \
  || fail "retained race result did not complete through durable recovery"
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' "${SCHEDULER_ROOT}/batches/${RACE_BATCH_ID}/state.json" >/dev/null \
  || fail "race result was not counted exactly once as done"
jq -e --arg mr_url "${RACE_MR_URL}" '
  .body.status == "done"
  and .body.mr_url == $mr_url
' "${SCHEDULER_ROOT}/callback_outbox/${RACE_BATCH_ID}:snapshot-0:terminal-1.json" \
  >/dev/null || fail "race result callback did not preserve its MR URL"
jq -e '.active_jobs["A:snapshot-0"] == null' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "durable race result did not release the scheduler claim"

# A scheduler running job may outlive its project pending entry after a
# blocked attempt was imported. If the next live preflight observes closed/pr,
# the absence of that exact project pending IID is authoritative: terminalize
# the physical job instead of suppressing the skip forever and leaking a slot.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","project":"group/repo","iid":42,
    "branch":null,"entry_mode":"auto","force_rerun_pr":false,
    "status":"running","owner":{"batch_id":"A","snapshot_index":0},
    "finalization":null,"claim_generation":2,
    "claim_token":"continuation-private-claim"
  }
}}
EOF
cat >"${FAKE_BIN}/dispatch_driven_topup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$(cat)"
printf "topup:%s\n" "$(jq -r '.grants | map(.job_id) | join(",")' <<<"${request}")" >>"${ORDER_LOG}"
jq -cn '{
  status:"no_eligible_iids",dispatch_entries:[],pending_iids:[],
  skipped_entries:[{
    job_id:"A:snapshot-0",batch_id:"A",snapshot_index:0,
    project:"group/repo",iid:42,status:"skipped",reason:"closed"
  }]
}'
EOF
chmod +x "${FAKE_BIN}/dispatch_driven_topup.sh"
running_without_pending_output="$(run_tick)" \
  || fail "running job without project pending tick failed"
grep -q '^skip:A:snapshot-0:closed$' "${ORDER_LOG}" \
  || fail "running job without an exact project pending entry leaked its scheduler slot"
jq -e '
  .spawn_grants == []
  and ([.operation_results[]
    | select(.operation == "synthetic_skip"
      and .job_id == "A:snapshot-0" and .status == "imported")]
    | length) == 1
  and ([.operation_results[]
    | select(.operation == "running_preflight_skip"
      and .job_id == "A:snapshot-0")]
    | length) == 0
' <<<"${running_without_pending_output}" >/dev/null \
  || fail "missing project pending entry did not release the running physical job"

# An expired positive-generation running job is reconciled before handoff
# draining/reservation. The timeout worker receives only a SHA-256 fence, and a
# successful claim-bound terminal frees the slot in the same tick.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"branch":null,"entry_mode":"auto",
    "force_rerun_pr":false,"status":"running","reservation_seq":1,
    "reserved_at":1,"updated_at":1,"claim_generation":2,
    "claim_token":"running-private-claim",
    "owner":{"batch_id":"A","snapshot_index":0},
    "memberships":[{"batch_id":"A","snapshot_index":0}]
  }
}}
EOF
timeout_output="$(NOW_EPOCH=50000 EXECUTOR_RUNNING_LEASE_SECONDS=10 \
  TIMEOUT_TEST_RELEASE=1 run_tick)" || fail "expired running recovery tick failed"
grep -Eq '^timeout:A:snapshot-0:2:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "expired running job did not receive an exact hashed claim fence"
if grep -q 'running-private-claim' "${ORDER_LOG}" \
    || grep -q 'running-private-claim' <<<"${timeout_output}"; then
  fail "running timeout recovery exposed the private claim token"
fi
jq -e '
  ([.operation_results[] | select(
    .operation == "running_timeout_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "handled")] | length) == 1
' <<<"${timeout_output}" >/dev/null \
  || fail "expired running recovery was not reported"

# Completed launch coordinators are cold evidence. A later tick archives them
# by deterministic job hash, so the recovery scan remains bounded by unfinished
# launch actions while direct duplicate acknowledgement can still locate them.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"batch_order":["A"],"active_jobs":{}}
EOF
archive_job_id='archive-test:snapshot-0'
archive_digest="$(printf '%s' "${archive_job_id}" | shasum -a 256 | awk '{print $1}')"
mkdir -p "${SCHEDULER_ROOT}/launch_actions"
jq -cnS --arg job_id "${archive_job_id}" '{
  version:1,job_id:$job_id,project:"group/repo",iid:42,
  batch_id:"A",snapshot_index:0,execution_id:1,
  child_label:"reqx-iid42-gen1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  payload_path:"/private/payload",runtime_label_version:1,
  expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
  expected_task_bytes:42,
  claim_generation:1,claim_token:"archive-private-claim",
  stage:"completed",outcome:"spawned",
  ack:{run_id:"run-archive",child_session_key:"agent:req_executor:archive"},
  created_at:1,updated_at:2
}' >"${SCHEDULER_ROOT}/launch_actions/${archive_digest}.json"
archive_tick_out="$(run_tick)" || fail "completed launch-action archive tick failed"
[ ! -e "${SCHEDULER_ROOT}/launch_actions/${archive_digest}.json" ] \
  || fail "completed launch action remained in the hot recovery directory"
[ -f "${SCHEDULER_ROOT}/launch_action_archive/${archive_digest}.json" ] \
  || fail "completed launch action was not retained in cold archive"
if grep -q 'archive-private-claim' <<<"${archive_tick_out}"; then
  fail "launch-action archive exposed a private claim"
fi

# The post-spawn fixed wrapper must recover the exact private claim internally,
# update project pending first, and record the same claim in the scheduler.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","project":"group/repo","iid":42,
    "status":"preparing","claim_generation":2,"claim_token":"record-private-claim"
  }
}}
EOF
: >"${ORDER_LOG}"
cat >"${FAKE_BIN}/record_driven_batch_launch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "record:%s:%s\n" "${ACTION:-${STATUS:-}}" "${JOB_ID}" >>"${ORDER_LOG}"
case "${ACTION:-${STATUS:-}}" in
  spawned)
    jq -cn --arg job_id "${JOB_ID}" '{
      status:"recorded",job_id:$job_id,job_status:"running",active_count:1,
      should_spawn:false,claim_generation:null,claim_token:null
    }'
    ;;
  launch_failed)
    jq -cn --arg job_id "${JOB_ID}" '{
      status:"recorded",job_id:$job_id,job_status:"launch_failed",active_count:0,
      should_spawn:false,claim_generation:null,claim_token:null
    }'
    ;;
  *) exit 97 ;;
esac
EOF
chmod +x "${FAKE_BIN}/record_driven_batch_launch.sh"
record_output="$({
  jq -cn '{
    job_id:"A:snapshot-0",claim_generation:2,project:"group/repo",iid:42,
    execution_id:2,status:"spawned",run_id:"run-42",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    child_session_key:"agent:req_executor:subagent:42"
  }'
} | CONFIG_DIR="${CONFIG_DIR}" \
    ORDER_LOG="${ORDER_LOG}" TEST_ROOT="${TEST_ROOT}" SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
    RESOLVE_REPO_CMD="${FAKE_BIN}/resolve_driven_repo_path.sh" \
    PROJECT_RECORD_CMD="${FAKE_BIN}/dispatch_record_spawn.sh" \
    RECORD_LAUNCH_CMD="${FAKE_BIN}/record_driven_batch_launch.sh" \
    bash "${RECORD_RESULT_SCRIPT}")" || fail "fixed spawned result wrapper failed"

expected_record_order='scheduler_env
project-record:spawned:42
record:spawned:A:snapshot-0'
[ "$(cat "${ORDER_LOG}")" = "${expected_record_order}" ] \
  || fail "spawn result was not recorded project-first with the same claim: $(cat "${ORDER_LOG}"); output=${record_output}"
jq -e '
  (keys | sort) == ["chat_summary","claim_generation","job_id","status"]
  and .status == "spawned_recorded"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 2
  and (tostring | contains("record-private-claim") | not)
' <<<"${record_output}" >/dev/null \
  || fail "spawn result wrapper leaked its private claim or returned a loose envelope: ${record_output}"
archive_launch_actions post_record

# Project grouping may change wrapper call order, but it must never change the
# scheduler's persisted grant order consumed by serial sessions_spawn + record.
# Two projects may legitimately run the same IID/attempt concurrently, so their
# runtime labels must also remain globally distinguishable for reconciliation.
mkdir -p "${SCHEDULER_ROOT}/batches/B" \
  "${TEST_ROOT}/repos/g1/repo/.git" "${TEST_ROOT}/repos/g2/repo/.git"
cat >"${SCHEDULER_ROOT}/batches/A/request.json" <<'EOF'
{"version":1,"batch_id":"A","project":"g1/repo","dispatcher_callback_target":"agent:req_dispatcher:main"}
EOF
cat >"${SCHEDULER_ROOT}/batches/B/request.json" <<'EOF'
{"version":1,"batch_id":"B","project":"g2/repo","dispatcher_callback_target":"agent:req_dispatcher:main"}
EOF
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":["A","B"]}
EOF
cat >"${FAKE_BIN}/reserve_driven_batch_items.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" reserve-order >>"${ORDER_LOG}"
jq -cn '{
  status:"ready",active_count:3,available_slots:0,
  grants:[
    {job_id:"A:snapshot-0",batch_id:"A",snapshot_index:0,project:"g1/repo",iid:42,branch:null,entry_mode:"auto",force_rerun_pr:false},
    {job_id:"B:snapshot-0",batch_id:"B",snapshot_index:0,project:"g2/repo",iid:42,branch:null,entry_mode:"auto",force_rerun_pr:false},
    {job_id:"A:snapshot-2",batch_id:"A",snapshot_index:2,project:"g1/repo",iid:43,branch:null,entry_mode:"auto",force_rerun_pr:false}
  ]
}'
EOF
chmod +x "${FAKE_BIN}/reserve_driven_batch_items.sh"
cat >"${FAKE_BIN}/resolve_driven_repo_path.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s/%s\n' "${TEST_ROOT}/repos" "${PROJECT_FULL}"
EOF
chmod +x "${FAKE_BIN}/resolve_driven_repo_path.sh"
cat >"${FAKE_BIN}/dispatch_driven_topup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
request="\$(cat)"
printf "topup-order:%s\n" "\$(jq -r '.grants | map(.job_id) | join(",")' <<<"\${request}")" >>"\${ORDER_LOG}"
jq -c --arg root "${TEST_ROOT}" '
  {
    status:"ready",
    dispatch_entries:[.grants[] | {
      iid,execution_id:1,
      child_label:("#" + (.iid|tostring) + "-att-001"),
      payload_path:(\$root + "/payload-" + (.iid|tostring) + ".txt"),
      expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
      expected_task_bytes:42,
      job_id,batch_id,snapshot_index,
      memberships_source:"scheduler_active_job"
    }],
    skipped_entries:[]
  }
' <<<"\${request}"
EOF
chmod +x "${FAKE_BIN}/dispatch_driven_topup.sh"
cat >"${FAKE_BIN}/record_driven_batch_launch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "record-order:%s\n" "${JOB_ID}" >>"${ORDER_LOG}"
jq -cn --arg job_id "${JOB_ID}" '{
  status:"recorded",job_id:$job_id,job_status:"preparing",active_count:3,
  should_spawn:true,claim_generation:1,claim_token:("private-" + $job_id)
}'
EOF
chmod +x "${FAKE_BIN}/record_driven_batch_launch.sh"

order_output="$(run_tick)" || fail "cross-project order tick failed"
jq -e '
  [.spawn_grants[].job_id] == ["A:snapshot-0"]
  and (.spawn_grants | all(.claim_generation == 1))
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen1-[0-9a-f]{40}$"))
  and (tostring | contains("private-") | not)
' <<<"${order_output}" >/dev/null \
  || fail "project grouping did not preserve the first serial grant: ${order_output}"
actual_record_order="$(grep '^record-order:' "${ORDER_LOG}" | sed 's/^record-order://')"
expected_record_order='A:snapshot-0'
[ "${actual_record_order}" = "${expected_record_order}" ] \
  || fail "serial preparing/bind did not preserve the first scheduler grant: ${actual_record_order}"

# The all-in-one executor wrapper persists worker_result.json before its Bash
# tool call returns. If OpenClaw never schedules the outer model's final turn,
# the next heartbeat must process that exact result under the scheduler claim
# fence and request cleanup of the still-live native subagent.
cat >"${SCHEDULER_ROOT}/batches/A/request.json" <<'EOF'
{"version":1,"batch_id":"A","project":"group/repo","dispatcher_callback_target":"agent:req_dispatcher:main"}
EOF
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"status":"running",
    "reservation_seq":1,"updated_at":100,"claim_generation":3,
    "claim_token":"durable-result-private-claim","finalization":null,
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
PROJECT_RUNTIME="${TEST_ROOT}/repos/group/repo/.req_executor"
CAMPAIGN_DIR="${PROJECT_RUNTIME}/_dispatcher"
RESULT_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/execution-3"
mkdir -p "${CAMPAIGN_DIR}" "${RESULT_LOG_DIR}"
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<'EOF'
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":3,"execution_id":3,
  "run_id":"run-42-result","child_session_key":"agent:req_executor:subagent:42"
}}}
EOF
cat >"${RESULT_LOG_DIR}/worker_result.json" <<EOF
{"iid":42,"execution_id":3,"status":"done","mode_actual":"fresh","work_branch":"issue/42","local_branch":"issue/42","commit_sha":"0123456789abcdef","merge_request_url":"https://gitlab.example.test/group/repo/-/merge_requests/1","mr_action":"created","wiki_url":"","labels_added":["pr"],"labels_removed":["doing","done"],"summary_posted":true,"block_reason":"","log_dir":"${RESULT_LOG_DIR}"}
EOF
cat >"${RESULT_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"execution_id":3,"exit_code":0,"completed_at_epoch":100}
EOF

# worker_result.json is intentionally visible before the producer completes
# archive/state finalization. Missing, non-private, or hash-mismatched latches
# must neither consume that result nor enter the post-acpx MR/kill path.
: >"${ORDER_LOG}"
unfinalized_result_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
    FINALIZATION_GATE_TEST=1 run_tick
)" || fail "missing finalization-latch tick failed"
if grep -Eq '^(result|marker|shared-mr-recovery):' "${ORDER_LOG}"; then
  fail "worker result without finalization latch entered terminal recovery"
fi
jq -e '
  .status == "idle"
  and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    or .operation == "post_acpx_shared_mr_recovery"
    or .operation == "post_acpx_marker_reconcile"
    or .operation == "post_acpx_watchdog")] | length) == 0
' <<<"${unfinalized_result_output}" >/dev/null \
  || fail "worker result without finalization latch escaped the safe gate"

write_attempt_finalized_marker \
  "${RESULT_LOG_DIR}" 42 3 "issue/42" "0123456789abcdef" 100
chmod 644 "${RESULT_LOG_DIR}/attempt_finalized.json"
: >"${ORDER_LOG}"
public_latch_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
    FINALIZATION_GATE_TEST=1 run_tick
)" || fail "non-private finalization-latch tick failed"
if grep -Eq '^(result|marker|shared-mr-recovery):' "${ORDER_LOG}"; then
  fail "non-private finalization latch authorized terminal recovery"
fi
jq -e '
  .status == "idle" and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    or .operation == "post_acpx_watchdog")] | length) == 0
' <<<"${public_latch_output}" >/dev/null \
  || fail "non-private finalization latch escaped the safe gate"

chmod 600 "${RESULT_LOG_DIR}/attempt_finalized.json"
jq -c '.worker_result_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "${RESULT_LOG_DIR}/attempt_finalized.json" \
  >"${RESULT_LOG_DIR}/attempt_finalized.invalid.json"
mv "${RESULT_LOG_DIR}/attempt_finalized.invalid.json" \
  "${RESULT_LOG_DIR}/attempt_finalized.json"
chmod 600 "${RESULT_LOG_DIR}/attempt_finalized.json"
: >"${ORDER_LOG}"
wrong_hash_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
    FINALIZATION_GATE_TEST=1 run_tick
)" || fail "hash-mismatched finalization-latch tick failed"
if grep -Eq '^(result|marker|shared-mr-recovery):' "${ORDER_LOG}"; then
  fail "hash-mismatched finalization latch authorized terminal recovery"
fi
jq -e '
  .status == "idle" and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    or .operation == "post_acpx_watchdog")] | length) == 0
' <<<"${wrong_hash_output}" >/dev/null \
  || fail "hash-mismatched finalization latch escaped the safe gate"

write_attempt_finalized_marker \
  "${RESULT_LOG_DIR}" 42 3 "issue/42" "0123456789abcdef" 100
: >"${ORDER_LOG}"
durable_result_output="$(
  RESULT_TEST_RELEASE=1 SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "durable worker-result recovery tick failed"
grep -Eq '^result:A:snapshot-0:3:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "durable worker result did not receive the exact hashed claim fence"
if grep -q 'durable-result-private-claim' "${ORDER_LOG}" \
    || grep -q 'durable-result-private-claim' <<<"${durable_result_output}"; then
  fail "durable worker-result recovery exposed the private claim token"
fi
jq -e '
  .status == "cleanup_required"
  and .spawn_grants == []
  and .reconcile_actions == []
  and (.cleanup_actions | length) == 1
  and .cleanup_actions[0].action == "kill"
  and .cleanup_actions[0].target == "agent:req_executor:subagent:42"
  and .cleanup_actions[0].reason == "durable_worker_result_recovered"
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    and .job_id == "A:snapshot-0" and .status == "handled")] | length) == 1
' <<<"${durable_result_output}" >/dev/null \
  || fail "durable worker result did not return one strict cleanup action"

# A producer can crash in the narrower window after archive_execution_logs.sh
# pushed the logs-only child L but before it persisted work_branch_sha=L and
# published attempt_finalized.json. The heartbeat may recover only an exact
# private single-Issue B -> L state, then must consume the synthesized latch in
# the same tick without exposing the GitLab credential.
RECOVERY_REPO="${TEST_ROOT}/repos/group/repo"
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" init -q
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" config user.name 'Batch Recovery Test'
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" config user.email 'batch-recovery@example.test'
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" remote add origin \
  'https://oauth2:tick-fixture-secret@gitlab.example.test/group/repo.git'
printf '%s\n' 'reviewed business tree' >"${RECOVERY_REPO}/business.txt"
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" add business.txt
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" commit -q -m 'business B'
ARCHIVE_BUSINESS_SHA="$("${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" rev-parse HEAD)"
ARCHIVE_TREE_DIR="${RECOVERY_REPO}/.req_executor/issue-42/log/execution-503"
mkdir -p "${ARCHIVE_TREE_DIR}"
printf '%s\n' 'archived execution log' >"${ARCHIVE_TREE_DIR}/wrapper.log"
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" add -f \
  '.req_executor/issue-42/log/execution-503/wrapper.log'
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" commit -q -m 'archive logs L'
ARCHIVE_LOG_SHA="$("${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" rev-parse HEAD)"

cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"status":"running",
    "reservation_seq":1,"updated_at":100,"claim_generation":5,
    "claim_token":"archive-recovery-private-claim","finalization":null,
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<'EOF'
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":5,"execution_id":503,
  "run_id":"run-42-archive","child_session_key":"agent:req_executor:subagent:42",
  "work_branch":"issue/42","branch_members":[42],"shared_branch_role":null
}}}
EOF
ARCHIVE_RESULT_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/execution-503"
ARCHIVE_ISSUE_DIR="${PROJECT_RUNTIME}/issues/issue-42"
mkdir -p "${ARCHIVE_RESULT_LOG_DIR}" "${ARCHIVE_ISSUE_DIR}"
cat >"${ARCHIVE_RESULT_LOG_DIR}/worker_result.json" <<EOF
{"iid":42,"execution_id":503,"status":"done","mode_actual":"fresh","work_branch":"issue/42","local_branch":"issue/42","commit_sha":"${ARCHIVE_BUSINESS_SHA}","merge_request_url":"https://gitlab.example.test/group/repo/-/merge_requests/503","mr_action":"created","wiki_url":"","labels_added":["pr"],"labels_removed":["doing","done"],"summary_posted":true,"block_reason":"","log_dir":"${ARCHIVE_RESULT_LOG_DIR}"}
EOF
cat >"${ARCHIVE_RESULT_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"execution_id":503,"exit_code":0,"completed_at_epoch":100}
EOF
cat >"${ARCHIVE_ISSUE_DIR}/state.json" <<EOF
{
  "iid":42,"dependency_pinned_execution_id":503,
  "work_branch":"issue/42","branch_members":[42],"shared_branch_role":null,
  "commit_sha":"${ARCHIVE_BUSINESS_SHA}",
  "work_branch_sha":"${ARCHIVE_BUSINESS_SHA}",
  "dependency_history_verified":true,
  "dependency_history_updated_at":"2026-01-01T00:00:00Z",
  "unchanged_probe":"must-survive-cas"
}
EOF
chmod 600 "${ARCHIVE_RESULT_LOG_DIR}/worker_result.json" \
  "${ARCHIVE_ISSUE_DIR}/state.json"
ARCHIVE_STATE_BEFORE="$(jq -cS . "${ARCHIVE_ISSUE_DIR}/state.json")"
archive_recovery_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  ARCHIVE_RECOVERY_TEST=1 \
  ARCHIVE_RECOVERY_REMOTE_SHA="${ARCHIVE_LOG_SHA}" \
  ARCHIVE_RECOVERY_WORK_BRANCH='issue/42' \
  RESULT_TEST_RELEASE=1 SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "logs-only archive crash recovery tick failed"
ARCHIVE_STATE_AFTER="$(jq -cS . "${ARCHIVE_ISSUE_DIR}/state.json")"
[ "$(test_sha256_file "${ARCHIVE_RESULT_LOG_DIR}/worker_result.json")" = \
    "$(jq -r '.worker_result_sha256' \
      "${ARCHIVE_RESULT_LOG_DIR}/attempt_finalized.json")" ] \
  || fail "archive crash recovery latch did not bind the final worker result"
[ "$(test_file_mode \
    "${ARCHIVE_RESULT_LOG_DIR}/attempt_finalized.json")" = 600 ] \
  || fail "archive crash recovery latch was not private"
jq -nce \
  --argjson before "${ARCHIVE_STATE_BEFORE}" \
  --argjson after "${ARCHIVE_STATE_AFTER}" \
  --arg business_sha "${ARCHIVE_BUSINESS_SHA}" \
  --arg log_sha "${ARCHIVE_LOG_SHA}" '
  (($before | del(.work_branch_sha,.dependency_history_updated_at))
    == ($after | del(.work_branch_sha,.dependency_history_updated_at)))
  and $after.commit_sha == $business_sha
  and $after.work_branch_sha == $log_sha
  and ($after.dependency_history_updated_at
    | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
' >/dev/null \
  || fail "archive crash recovery changed fields beyond the logs-only CAS"
if grep -q 'tick-fixture-secret' "${ORDER_LOG}" \
    || grep -q 'tick-fixture-secret' <<<"${archive_recovery_output}"; then
  fail "archive crash recovery exposed the GitLab credential"
fi
jq -e '
  .status == "cleanup_required"
  and (.cleanup_actions | length) == 1
  and .cleanup_actions[0].reason == "durable_worker_result_recovered"
  and ([.operation_results[] | select(
    .operation == "post_acpx_archive_finalize_recovery"
    and .job_id == "A:snapshot-0" and .status == "recovered")] | length) == 1
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    and .job_id == "A:snapshot-0" and .status == "handled")] | length) == 1
' <<<"${archive_recovery_output}" >/dev/null \
  || fail "archive crash recovery did not finalize and consume in one tick"

# A one-parent remote descendant with any non-log path is not an archive tail.
# Even after grace it must leave B/B unchanged, publish no latch, and never
# request native child cleanup.
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" checkout -q --detach \
  "${ARCHIVE_BUSINESS_SHA}"
printf '%s\n' 'not an execution log' >"${RECOVERY_REPO}/arbitrary.txt"
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" add arbitrary.txt
"${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" commit -q -m 'arbitrary child'
ARBITRARY_CHILD_SHA="$("${REAL_GIT_BIN}" -C "${RECOVERY_REPO}" rev-parse HEAD)"
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"status":"running",
    "reservation_seq":1,"updated_at":100,"claim_generation":7,
    "claim_token":"unsafe-archive-private-claim","finalization":null,
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<'EOF'
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":7,"execution_id":507,
  "run_id":"run-42-unsafe-archive",
  "child_session_key":"agent:req_executor:subagent:42",
  "work_branch":"issue/42","branch_members":[42],"shared_branch_role":null
}}}
EOF
UNSAFE_RESULT_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/execution-507"
mkdir -p "${UNSAFE_RESULT_LOG_DIR}"
cat >"${UNSAFE_RESULT_LOG_DIR}/worker_result.json" <<EOF
{"iid":42,"execution_id":507,"status":"done","mode_actual":"fresh","work_branch":"issue/42","local_branch":"issue/42","commit_sha":"${ARCHIVE_BUSINESS_SHA}","merge_request_url":"https://gitlab.example.test/group/repo/-/merge_requests/507","mr_action":"created","wiki_url":"","labels_added":["pr"],"labels_removed":["doing","done"],"summary_posted":true,"block_reason":"","log_dir":"${UNSAFE_RESULT_LOG_DIR}"}
EOF
cat >"${UNSAFE_RESULT_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"execution_id":507,"exit_code":0,"completed_at_epoch":100}
EOF
cat >"${ARCHIVE_ISSUE_DIR}/state.json" <<EOF
{
  "iid":42,"dependency_pinned_execution_id":507,
  "work_branch":"issue/42","branch_members":[42],"shared_branch_role":null,
  "commit_sha":"${ARCHIVE_BUSINESS_SHA}",
  "work_branch_sha":"${ARCHIVE_BUSINESS_SHA}",
  "dependency_history_verified":true,
  "dependency_history_updated_at":"2026-01-01T00:00:00Z"
}
EOF
chmod 600 "${UNSAFE_RESULT_LOG_DIR}/worker_result.json" \
  "${ARCHIVE_ISSUE_DIR}/state.json"
UNSAFE_STATE_BEFORE="$(jq -cS . "${ARCHIVE_ISSUE_DIR}/state.json")"
unchanged_remote_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  ARCHIVE_RECOVERY_TEST=1 \
  ARCHIVE_RECOVERY_REMOTE_SHA="${ARCHIVE_BUSINESS_SHA}" \
  ARCHIVE_RECOVERY_WORK_BRANCH='issue/42' \
  FINALIZATION_GATE_TEST=1 run_tick
)" || fail "unchanged remote archive recovery tick failed"
[ "$(jq -cS . "${ARCHIVE_ISSUE_DIR}/state.json")" = \
    "${UNSAFE_STATE_BEFORE}" ] \
  && [ ! -e "${UNSAFE_RESULT_LOG_DIR}/attempt_finalized.json" ] \
  || fail "remote B was incorrectly treated as a recovered archive child"
jq -e '
  .status == "idle"
  and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "post_acpx_archive_finalize_recovery"
    or .operation == "durable_worker_result_reconcile"
    or .operation == "post_acpx_watchdog")] | length) == 0
' <<<"${unchanged_remote_output}" >/dev/null \
  || fail "remote B escaped the no-recovery/no-kill gate"

unsafe_archive_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  ARCHIVE_RECOVERY_TEST=1 \
  ARCHIVE_RECOVERY_REMOTE_SHA="${ARBITRARY_CHILD_SHA}" \
  ARCHIVE_RECOVERY_WORK_BRANCH='issue/42' \
  FINALIZATION_GATE_TEST=1 run_tick
)" || fail "unsafe archive-child rejection tick failed"
[ "$(jq -cS . "${ARCHIVE_ISSUE_DIR}/state.json")" = \
    "${UNSAFE_STATE_BEFORE}" ] \
  || fail "unsafe archive child advanced the private issue state"
[ ! -e "${UNSAFE_RESULT_LOG_DIR}/attempt_finalized.json" ] \
  || fail "unsafe archive child published a finalization latch"
jq -e '
  .status == "idle"
  and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "post_acpx_archive_finalize_recovery"
    or .operation == "durable_worker_result_reconcile"
    or .operation == "post_acpx_watchdog")] | length) == 0
' <<<"${unsafe_archive_output}" >/dev/null \
  || fail "unsafe archive child escaped the no-recovery/no-kill gate"

# If the wrapper died after acpx_terminal.json but before worker_result.json,
# wait for a bounded grace period and then reclaim only the matching native
# child. The issue-local marker has an exact schema and execution identity,
# so an in-flight acpx process cannot be mistaken for this post-acpx state.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"status":"running",
    "reservation_seq":1,"updated_at":100,"claim_generation":4,
    "claim_token":"post-acpx-private-claim","finalization":null,
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<'EOF'
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":4,"execution_id":4,
  "run_id":"run-42-marker","child_session_key":"agent:req_executor:subagent:42"
}}}
EOF
MARKER_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/execution-4"
mkdir -p "${MARKER_LOG_DIR}"
cat >"${MARKER_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"execution_id":4,"exit_code":0,"completed_at_epoch":100}
EOF
post_acpx_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
    SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "post-acpx watchdog tick failed"
if grep -q '^shared-mr-recovery:' "${ORDER_LOG}"; then
  fail "ordinary post-acpx watchdog invoked shared MR-only recovery"
fi
jq -e '
  .status == "cleanup_required"
  and .spawn_grants == []
  and .reconcile_actions == []
  and (.cleanup_actions | length) == 1
  and .cleanup_actions[0].action == "kill"
  and .cleanup_actions[0].target == "agent:req_executor:subagent:42"
  and .cleanup_actions[0].reason == "post_acpx_finalization_grace_exceeded"
  and .cleanup_actions[0].execution_id == 4
  and .cleanup_actions[0].claim_generation == 4
  and ([.operation_results[] | select(
    .operation == "post_acpx_watchdog"
    and .job_id == "A:snapshot-0" and .status == "kill_required")] | length) == 1
  and (tostring | contains("post-acpx-private-claim") | not)
' <<<"${post_acpx_output}" >/dev/null \
  || fail "post-acpx marker did not return one exact cleanup action"

# A shared-branch wrapper can die after its exact push checkpoint but before
# create_mr.sh persists mr_result.json. The heartbeat must run only the fixed
# MR finalizer, then reconcile the marker under the existing scheduler claim.
# Once the verified marker exists, a later heartbeat skips the MR call and
# consumes that same marker directly.
SHARED_DEPENDENCY_SHA='9999999999999999999999999999999999999999'
SHARED_COMMIT_SHA='cccccccccccccccccccccccccccccccccccccccc'
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"status":"running",
    "reservation_seq":1,"updated_at":100,"claim_generation":6,
    "claim_token":"shared-mr-private-claim","finalization":null,
    "auto_merge":false,"merge_target_branch":"main",
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<EOF
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":6,"execution_id":6,
  "run_id":"run-42-shared-mr","child_session_key":"agent:req_executor:subagent:42",
  "auto_merge":false,"branch":"main","merge_target_branch":"main",
  "work_branch":"issue/9+42","branch_members":[9,42],
  "shared_branch_role":"tail","dependency_iid":9,
  "dependency_branch":"issue/9+42",
  "dependency_base_sha":"${SHARED_DEPENDENCY_SHA}"
}}}
EOF
SHARED_ISSUE_DIR="${PROJECT_RUNTIME}/issues/issue-42"
mkdir -p "${SHARED_ISSUE_DIR}/executions"
cat >"${SHARED_ISSUE_DIR}/executions/execution-6.json" <<EOF
{
  "iid":42,"execution_id":6,"issue_title":"共享分支尾节点",
  "mode_actual":"fresh","auto_merge":false,"merge_target_branch":"main",
  "work_branch":"issue/9+42","branch_members":[9,42],
  "shared_branch_role":"tail","dependency_iid":9,
  "dependency_branch":"issue/9+42",
  "dependency_base_sha":"${SHARED_DEPENDENCY_SHA}"
}
EOF
cat >"${SHARED_ISSUE_DIR}/state.json" <<EOF
{
  "iid":42,"work_branch":"issue/9+42","branch_members":[9,42],
  "shared_branch_role":"tail","dependency_iid":9,
  "dependency_branch":"issue/9+42",
  "dependency_base_sha":"${SHARED_DEPENDENCY_SHA}",
  "dependency_history_verified":true,
  "work_branch_sha":"${SHARED_COMMIT_SHA}",
  "mr_finalization":{
    "status":"pending","source_execution_id":6,
    "work_branch":"issue/9+42","branch_members":[9,42],
    "shared_branch_role":"tail","commit_sha":"${SHARED_COMMIT_SHA}",
    "intent_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "target_branch":"main"
  }
}
EOF
chmod 600 "${SHARED_ISSUE_DIR}/executions/execution-6.json" \
  "${SHARED_ISSUE_DIR}/state.json"
SHARED_MR_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/execution-6"
mkdir -p "${SHARED_MR_LOG_DIR}"
cat >"${SHARED_MR_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"execution_id":6,"exit_code":0,"completed_at_epoch":100}
EOF
cat >"${SHARED_MR_LOG_DIR}/worker_result.json" <<EOF
{
  "iid":42,"execution_id":6,"status":"blocked","mode_actual":"fresh",
  "work_branch":"issue/9+42","local_branch":"issue/42",
  "commit_sha":"${SHARED_COMMIT_SHA}","merge_request_url":"",
  "mr_action":"none","wiki_url":"","labels_added":[],
  "labels_removed":[],"summary_posted":false,
  "block_reason":"shared MR marker is pending",
  "log_dir":"${SHARED_MR_LOG_DIR}"
}
EOF
chmod 600 "${SHARED_MR_LOG_DIR}/worker_result.json"
shared_without_latch_out="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  FINALIZATION_GATE_TEST=1 run_tick
)" || fail "legacy shared archive-recovery rejection tick failed"
if grep -Eq '^(result|marker|shared-mr-recovery):' "${ORDER_LOG}"; then
  fail "legacy shared branch entered archive-tail recovery without a latch"
fi
jq -e '
  .status == "idle"
  and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "post_acpx_archive_finalize_recovery"
    or .operation == "durable_worker_result_reconcile"
    or .operation == "post_acpx_shared_mr_recovery"
    or .operation == "post_acpx_watchdog")] | length) == 0
' <<<"${shared_without_latch_out}" >/dev/null \
  || fail "legacy shared branch escaped the no-recovery/no-kill gate"
write_attempt_finalized_marker \
  "${SHARED_MR_LOG_DIR}" 42 6 "issue/9+42" "${SHARED_COMMIT_SHA}" 100
shared_mr_recovery_out="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  RESULT_TEST_SHARED_MR_PENDING=1 MARKER_TEST_STATUS=marker_not_ready \
  SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "shared MR-only recovery tick failed"
grep -Eq '^result:A:snapshot-0:6:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "shared durable worker result did not enter claim-fenced Phase 6"
grep -q '^shared-mr-recovery:repo:group:42:6:issue/9+42$' "${ORDER_LOG}" \
  || fail "retained shared durable result starved the exact MR-only recovery command"
shared_result_line="$(grep -n '^result:A:snapshot-0:6:' "${ORDER_LOG}" | cut -d: -f1)"
shared_recovery_line="$(grep -n '^shared-mr-recovery:' "${ORDER_LOG}" | cut -d: -f1)"
shared_marker_line="$(grep -n '^marker:A:snapshot-0:6:' "${ORDER_LOG}" | cut -d: -f1)"
[ "${shared_result_line}" -lt "${shared_recovery_line}" ] \
  && [ "${shared_recovery_line}" -lt "${shared_marker_line}" ] \
  || fail "retained durable result did not flow through MR-only recovery before marker reconciliation"
if grep -q 'shared-mr-private-claim' "${ORDER_LOG}" \
    || grep -q 'shared-mr-private-claim' <<<"${shared_mr_recovery_out}"; then
  fail "shared MR-only recovery exposed the private claim token"
fi
jq -e '
  .status == "cleanup_required"
  and ([.operation_results[] | select(
    .operation == "durable_worker_result_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "handled")] | length) == 1
  and ([.operation_results[] | select(
    .operation == "post_acpx_shared_mr_recovery"
    and .job_id == "A:snapshot-0"
    and .status == "verified_open")] | length) == 1
  and ([.operation_results[] | select(
    .operation == "post_acpx_marker_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "marker_not_ready")] | length) == 1
' <<<"${shared_mr_recovery_out}" >/dev/null \
  || fail "shared MR-only recovery did not retain the claim for marker retry"
mv "${SHARED_MR_LOG_DIR}/worker_result.json" \
  "${SHARED_MR_LOG_DIR}/worker_result.consumed.json"

shared_mr_marker_out="$(
  NOW_EPOCH=2001 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  MARKER_TEST_STATUS=done MARKER_TEST_RELEASE=1 \
  SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "shared verified-marker reconciliation tick failed"
if grep -q '^shared-mr-recovery:' "${ORDER_LOG}"; then
  fail "an already verified shared marker repeated the MR-only recovery call"
fi
grep -Eq '^marker:A:snapshot-0:6:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "verified shared marker did not enter ordinary claim-fenced reconciliation"
jq -e '
  .status == "cleanup_required"
  and ([.operation_results[] | select(
    .operation == "post_acpx_shared_mr_recovery")] | length) == 0
  and ([.operation_results[] | select(
    .operation == "post_acpx_marker_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "handled"
    and .terminal_status == "done")] | length) == 1
' <<<"${shared_mr_marker_out}" >/dev/null \
  || fail "verified shared marker was not consumed without another MR call"
jq -e '.active_jobs["A:snapshot-0"] == null' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "successful shared marker reconciliation did not release the scheduler job"

# Automatic-merge post-acpx stalls are reconciled from the exact MR marker
# before cleanup. A finish-label failure remains blocked/pending; the next tick
# retries the same claim and may then finish without relying on a killed-event
# callback or waiting for the long running lease.
cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":"A","batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","physical_key":"group/repo#42",
    "project":"group/repo","iid":42,"status":"running",
    "reservation_seq":1,"updated_at":100,"claim_generation":5,
    "claim_token":"marker-retry-private-claim","finalization":null,
    "auto_merge":true,"merge_target_branch":"release",
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<'EOF'
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":5,"execution_id":5,
  "run_id":"run-42-marker-retry","child_session_key":"agent:req_executor:subagent:42",
  "auto_merge":true,"branch":"main","merge_target_branch":"release"
}}}
EOF
MARKER_RETRY_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/execution-5"
mkdir -p "${MARKER_RETRY_LOG_DIR}"
cat >"${MARKER_RETRY_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"execution_id":5,"exit_code":0,"completed_at_epoch":100}
EOF
marker_retry_blocked_out="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  MARKER_TEST_STATUS=blocked SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "post-acpx marker blocked retry tick failed"
grep -Eq '^marker:A:snapshot-0:5:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "marker reconcile did not receive the exact hashed claim fence"
if grep -q 'marker-retry-private-claim' "${ORDER_LOG}" \
    || grep -q 'marker-retry-private-claim' <<<"${marker_retry_blocked_out}"; then
  fail "marker reconcile exposed the private claim token"
fi
jq -e '
  .status == "cleanup_required"
  and ([.operation_results[] | select(
    .operation == "post_acpx_marker_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "handled"
    and .terminal_status == "blocked")] | length) == 1
' <<<"${marker_retry_blocked_out}" >/dev/null \
  || fail "finish-label failure was not retained as marker retry pending"
jq -e '.active_jobs["A:snapshot-0"] != null' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "blocked marker retry released the scheduler job"

marker_retry_done_out="$(
  NOW_EPOCH=2001 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
  MARKER_TEST_STATUS=done MARKER_TEST_RELEASE=1 \
  SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "post-acpx marker successful retry tick failed"
jq -e '
  .status == "cleanup_required"
  and ([.operation_results[] | select(
    .operation == "post_acpx_marker_reconcile"
    and .job_id == "A:snapshot-0"
    and .status == "handled"
    and .terminal_status == "done")] | length) == 1
' <<<"${marker_retry_done_out}" >/dev/null \
  || fail "second marker tick did not finish the retained retry"
jq -e '.active_jobs["A:snapshot-0"] == null' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "successful marker retry did not release the scheduler job"

# A dependency-waiting grant must be returned to the scheduler without a spawn.
# Use the real reserve/record scripts at max concurrency 1 so the next direct
# reservation proves that deferred C no longer prevents ordinary A from running.
DEPENDENCY_TMP_PARENT="${TMPDIR:-/tmp}"
DEPENDENCY_TMP_PARENT="${DEPENDENCY_TMP_PARENT%/}"
DEPENDENCY_TEST_ROOT="$(mktemp -d \
  "${DEPENDENCY_TMP_PARENT}/req-executor-dependency-tick.XXXXXX")"
DEPENDENCY_CONFIG_DIR="${DEPENDENCY_TEST_ROOT}/dependency-tick-config"
DEPENDENCY_SCHEDULER_ROOT="${DEPENDENCY_TEST_ROOT}/dependency-tick-scheduler"
DEPENDENCY_ORDER_LOG="${DEPENDENCY_TEST_ROOT}/dependency-tick-order.log"
mkdir -p "${DEPENDENCY_CONFIG_DIR}" \
  "${DEPENDENCY_SCHEDULER_ROOT}/batches/C" \
  "${DEPENDENCY_SCHEDULER_ROOT}/batches/A" \
  "${DEPENDENCY_TEST_ROOT}/repos/group/repo/.git"
cat >"${DEPENDENCY_CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=tick-dependency-fixture-secret
EOF
cat >"${DEPENDENCY_CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${DEPENDENCY_TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${DEPENDENCY_SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=1
EOF
CONFIG_DIR="${DEPENDENCY_CONFIG_DIR}" \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

for dependency_batch_spec in 'C 30' 'A 10'; do
  dependency_batch_id="${dependency_batch_spec%% *}"
  dependency_iid="${dependency_batch_spec#* }"
  dependency_batch_dir="${DEPENDENCY_SCHEDULER_ROOT}/batches/${dependency_batch_id}"
  jq -cnS \
    --arg batch_id "${dependency_batch_id}" \
    --argjson iid "${dependency_iid}" '{
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:"group/repo",
      selector:{type:"single",iid:$iid},
      force_rerun_pr:false,
      auto_merge:false,
      dispatcher_callback_target:"agent:req_dispatcher:main",
      branch:null,
      merge_target_branch:null
    }' >"${dependency_batch_dir}/request.json"
  jq -cnS --argjson iid "${dependency_iid}" \
    '{version:1,project:"group/repo",iids:[$iid]}' \
    >"${dependency_batch_dir}/snapshot.json"
  jq -cnS --arg batch_id "${dependency_batch_id}" '{
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
  }' >"${dependency_batch_dir}/state.json"
done
jq '.batch_order = ["C","A"]' \
  "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json" \
  >"${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json"

write_fake dependency_deferred_topup.sh '
request="$(cat)"
jq -e "
  .owner_id == \"executor-agent-scheduler-v1\"
  and [.grants[] | {job_id,batch_id,snapshot_index,project,iid}]
    == [{job_id:\"C:snapshot-0\",batch_id:\"C\",snapshot_index:0,
         project:\"group/repo\",iid:30}]
" <<<"${request}" >/dev/null
printf "%s\n" dependency-topup:C:snapshot-0 >>"${DEPENDENCY_ORDER_LOG}"
active_status="$(jq -r ".active_jobs[\"C:snapshot-0\"].status // \"\"" \
  "${SCHEDULER_ROOT}/scheduler_state.json")"
if [ "${active_status}" = running ]; then
  jq -cn "{
    status:\"dependency_waiting\",
    dispatch_entries:[],
    skipped_entries:[],
    deferred_entries:[{
      status:\"deferred\",
      job_id:\"C:snapshot-0\",
      batch_id:\"C\",
      snapshot_index:0,
      project:\"group/repo\",
      iid:30,
      dependency_iid:null,
      dependency_branch:null,
      reason:\"dependency_graph_scope_incomplete\"
    }]
  }"
else
  jq -cn "{
    status:\"dependency_waiting\",
    dispatch_entries:[],
    skipped_entries:[],
    deferred_entries:[{
      status:\"deferred\",
      job_id:\"C:snapshot-0\",
      batch_id:\"C\",
      snapshot_index:0,
      project:\"group/repo\",
      iid:30,
      dependency_iid:9,
      dependency_branch:\"issue/9+30\",
      reason:\"dependency_not_completed\"
    }]
  }"
fi
'
write_fake dependency_record_wrapper.sh '
printf "dependency-record:%s:%s:%s:%s\n" \
  "${ACTION:-${STATUS:-}}" "${JOB_ID}" \
  "${CLAIM_GENERATION:-}" "${CLAIM_TOKEN:-}" \
  >>"${DEPENDENCY_ORDER_LOG}"
exec bash "${REAL_RECORD_CMD}"
'

run_dependency_fixture_tick() {
  CONFIG_DIR="${DEPENDENCY_CONFIG_DIR}" \
  TEST_ROOT="${DEPENDENCY_TEST_ROOT}" \
  SCHEDULER_ROOT="${DEPENDENCY_SCHEDULER_ROOT}" \
  ORDER_LOG="${DEPENDENCY_ORDER_LOG}" \
  DEPENDENCY_ORDER_LOG="${DEPENDENCY_ORDER_LOG}" \
  REAL_RECORD_CMD="${SKILL_DIR}/scripts/record_driven_batch_launch.sh" \
  DRIVEN_PREPARING_LEASE_SECONDS=1 \
  PATH="${FAKE_BIN}:${PATH}" \
  SCHEDULER_ENV_CMD="${SKILL_DIR}/scripts/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve_driven_repo_path.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_driven_handoff_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_driven_outbox.sh" \
  RECONCILE_COUNTS_CMD="${FAKE_BIN}/reconcile_driven_terminal_counts.sh" \
  REAP_PLACEHOLDERS_CMD="${FAKE_BIN}/reap_driven_orphan_placeholders.sh" \
  EXPIRE_RUNNING_CMD="${FAKE_BIN}/expire_running.sh" \
  RESERVE_CMD="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
  TOPUP_CMD="${FAKE_BIN}/dependency_deferred_topup.sh" \
  IMPORT_SKIP_CMD="${FAKE_BIN}/import_driven_skipped.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/dependency_record_wrapper.sh" \
  BIND_CLAIM_CMD="${FAKE_BIN}/bind_driven_claim.sh" \
    bash "${TICK_SCRIPT}"
}

# Exercise the lease-recovery shape: reserve C, create generation 1, then let
# that preparing claim expire. The tick's real reserve step must recover the
# job as tokenless reserved generation 1 before dependency deferral releases it.
dependency_initial_reserve="$(
  CONFIG_DIR="${DEPENDENCY_CONFIG_DIR}" NOW_EPOCH=1 \
    DRIVEN_PREPARING_LEASE_SECONDS=1 \
    bash "${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
)" || fail "dependency fixture initial reservation failed"
jq -e '.grants[0].job_id == "C:snapshot-0"' \
  <<<"${dependency_initial_reserve}" >/dev/null \
  || fail "dependency fixture did not reserve C first"

# A migrated legacy running job has no secret claim token. Dependency waiting
# must not weaken the claim fence to release it as retry_wait; report the
# recovery requirement and leave the exact legacy job untouched.
cp "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.before-legacy.json"
cp "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.before-legacy.json"
jq '
  .active_jobs["C:snapshot-0"].status = "running"
  | .active_jobs["C:snapshot-0"].claim_generation = 0
  | .active_jobs["C:snapshot-0"].claim_token = null
  | .active_jobs["C:snapshot-0"].legacy_running = true
' "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json" \
  >"${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.legacy.json"
mv "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.legacy.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json"
jq '
  .memberships["0"].status = "running"
  | .status = "running"
' "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.json" \
  >"${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.legacy.json"
mv "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.legacy.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.json"
: >"${DEPENDENCY_ORDER_LOG}"
legacy_dependency_output="$(run_dependency_fixture_tick)" \
  || fail "legacy dependency deferral tick crashed"
jq -e '
  .status == "tick_failed"
  and .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "dependency_defer"
    and .job_id == "C:snapshot-0"
    and .status == "legacy_running_recovery_required")] | length) == 1
' <<<"${legacy_dependency_output}" >/dev/null \
  || fail "legacy running dependency weakened the claim fence"
if grep -q '^dependency-record:' "${DEPENDENCY_ORDER_LOG}"; then
  fail "legacy running dependency called the ordinary deferral recorder"
fi
jq -e '
  .active_jobs["C:snapshot-0"].status == "running"
  and .active_jobs["C:snapshot-0"].legacy_running == true
  and .active_jobs["C:snapshot-0"].claim_generation == 0
  and .active_jobs["C:snapshot-0"].claim_token == null
' "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "legacy running dependency job was mutated without a claim fence"
cp "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.before-legacy.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json"
cp "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.before-legacy.json" \
  "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.json"
dependency_expiring_claim="$(
  CONFIG_DIR="${DEPENDENCY_CONFIG_DIR}" JOB_ID='C:snapshot-0' \
    STATUS=preparing NOW_EPOCH=2 DRIVEN_PREPARING_LEASE_SECONDS=1 \
    bash "${SKILL_DIR}/scripts/record_driven_batch_launch.sh"
)" || fail "dependency fixture preparing claim failed"
jq -e '
  .job_status == "preparing"
  and .claim_generation == 1
  and (.claim_token | type == "string" and length > 0)
' <<<"${dependency_expiring_claim}" >/dev/null \
  || fail "dependency fixture did not create generation-1 preparing claim"

: >"${DEPENDENCY_ORDER_LOG}"
dependency_tick_output="$(run_dependency_fixture_tick)" \
  || fail "dependency-deferred executor tick failed"
jq -e '
  .status == "idle"
  and .spawn_grants == []
  and .reconcile_actions == []
  and .cleanup_actions == []
  and ([.operation_results[] | select(
    .operation == "project_topup"
    and .project == "group/repo"
    and .deferred_count == 1)] | length) == 1
  and ([.operation_results[] | select(
    .operation == "dependency_defer"
    and .job_id == "C:snapshot-0"
    and .project == "group/repo"
    and .iid == 30
    and .dependency_iid == 9
    and .reason == "dependency_not_completed"
    and .status == "released")] | length) == 1
' <<<"${dependency_tick_output}" >/dev/null \
  || fail "dependency-deferred tick did not return one released no-spawn result: ${dependency_tick_output}"
[ "$(grep -c '^dependency-record:dependency_deferred:C:snapshot-0:1:$' \
    "${DEPENDENCY_ORDER_LOG}")" -eq 1 ] \
  || fail "tick did not fence the recovered reserved dependency generation"
if grep -q '^record:preparing:' "${DEPENDENCY_ORDER_LOG}"; then
  fail "dependency-deferred tick attempted a preparing claim"
fi
jq -e '
  (.active_jobs | has("C:snapshot-0") | not)
  and (.active_jobs | length) == 0
' "${DEPENDENCY_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "dependency-deferred tick retained the active C job"
jq -e '
  .status == "queued"
  and .terminal_count == 0
  and .done_count == 0
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "retry_wait"
  and .memberships["0"].defer_count == 1
  and (.memberships["0"] | has("job_id") | not)
' "${DEPENDENCY_SCHEDULER_ROOT}/batches/C/state.json" >/dev/null \
  || fail "dependency-deferred tick did not park C as non-terminal retry_wait"
[ ! -e "${SPAWN_SENTINEL}" ] \
  || fail "dependency-deferred tick called sessions_spawn"

dependency_after_tick_reserve="$(
  CONFIG_DIR="${DEPENDENCY_CONFIG_DIR}" NOW_EPOCH=3000 \
    bash "${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
)" || fail "post-deferral reservation failed"
jq -e '
  [.grants[] | {batch_id,iid,job_id}] == [
    {batch_id:"A",iid:10,job_id:"A:snapshot-0"}
  ]
  and .active_count == 1
  and .available_slots == 0
' <<<"${dependency_after_tick_reserve}" >/dev/null \
  || fail "deferred C still occupied the single slot: ${dependency_after_tick_reserve}"

echo "ok executor batch tick is recovery-first and returns strict spawn grants"
