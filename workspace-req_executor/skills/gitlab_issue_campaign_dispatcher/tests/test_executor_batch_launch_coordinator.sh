#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECORD_SCRIPT="${SKILL_DIR}/scripts/record_executor_batch_spawn.sh"
TICK_SCRIPT="${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
PROJECT_RECORD_SCRIPT="${SKILL_DIR}/scripts/dispatch_record_spawn.sh"
SCHEDULER_RECORD_SCRIPT="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

fail() {
  echo "test_executor_batch_launch_coordinator.sh: $*" >&2
  exit 1
}

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-launch-coordinator.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_BIN="${TEST_ROOT}/fake-bin"
CALL_LOG="${TEST_ROOT}/calls.log"
mkdir -p "${CONFIG_DIR}" "${SCHEDULER_ROOT}" "${FAKE_BIN}" \
  "${TEST_ROOT}/repos/group/repo/.git"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=fixture-token
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF

cat >"${FAKE_BIN}/scheduler_env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}"
export EXECUTOR_MAX_CONCURRENCY=3
export EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1
export SCHEDULER_STATE_FILE="${SCHEDULER_ROOT}/scheduler_state.json"
export SCHEDULER_LOCK_FILE="${SCHEDULER_ROOT}/scheduler.lock"
export BATCHES_ROOT="${SCHEDULER_ROOT}/batches"
export CALLBACK_INBOX="${SCHEDULER_ROOT}/callback_inbox"
export CALLBACK_OUTBOX="${SCHEDULER_ROOT}/callback_outbox"
mkdir -p "${BATCHES_ROOT}" "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}"
jq -cn --arg root "${SCHEDULER_ROOT}" '{scheduler_root:$root,max_concurrency:3}'
EOF
cat >"${FAKE_BIN}/resolve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${TEST_ROOT}/repos/group/repo"
EOF
cat >"${FAKE_BIN}/project_record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${PROJECT_FAIL_ONCE:-0}" = 1 ] \
    && [ ! -e "${SCHEDULER_ROOT}/project-record-failed-once" ]; then
  : >"${SCHEDULER_ROOT}/project-record-failed-once"
  printf 'project-failed:%s:%s\n' "${STATUS}" "${JOB_ID_FOR_TEST:-unknown}" >>"${CALL_LOG}"
  exit 71
fi
printf 'project:%s:%s\n' "${STATUS}" "${JOB_ID_FOR_TEST:-unknown}" >>"${CALL_LOG}"
if [ "${STATUS}" = spawned ]; then
  jq -cn --argjson iid "${IID}" --argjson attempt "${EXECUTION_ID}" '{
    status:"spawned",iid:$iid,execution_id:$attempt,
    remaining_pending_count:1,chat_summary:"recorded"
  }'
else
  jq -cn --argjson iid "${IID}" --argjson attempt "${EXECUTION_ID}" '{
    status:"launch_failed_recorded",iid:$iid,execution_id:$attempt,
    final_status:"blocked",
    cleanup:{action:"skip",target:"",reason:"no_child_session_key"},
    remaining_pending_count:0,chat_summary:"recorded"
  }'
fi
EOF
cat >"${FAKE_BIN}/scheduler_record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${SCHEDULER_FAIL_ONCE:-0}" = 1 ] \
    && [ ! -e "${SCHEDULER_ROOT}/scheduler-record-failed-once" ]; then
  : >"${SCHEDULER_ROOT}/scheduler-record-failed-once"
  printf 'scheduler-failed:%s:%s\n' "${ACTION}" "${JOB_ID}" >>"${CALL_LOG}"
  exit 72
fi
printf 'scheduler:%s:%s\n' "${ACTION}" "${JOB_ID}" >>"${CALL_LOG}"
job_status=running
[ "${ACTION}" = launch_failed ] && job_status=launch_failed
[ "${ACTION}" = recovered_launch_failed ] && job_status=launch_failed
jq -cn --arg job_id "${JOB_ID}" --arg job_status "${job_status}" '{
  status:"recorded",job_id:$job_id,job_status:$job_status,active_count:1,
  should_spawn:false,claim_generation:null,claim_token:null
}'
EOF
cat >"${FAKE_BIN}/drain_intents.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn '{status:"drained",intent_count:0,results:[]}'
EOF
cat >"${FAKE_BIN}/drain_outbox.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn '{status:"drained",scanned:0,attempted:0,delivered:0,failed:0}'
EOF
cat >"${FAKE_BIN}/reserve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn '{status:"idle",grants:[],active_count:1,available_slots:2}'
EOF
cat >"${FAKE_BIN}/unused.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 99
EOF
cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth|api) exit 0 ;;
  *) exit 91 ;;
esac
EOF
cat >"${FAKE_BIN}/real-project-record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash "${ACTUAL_PROJECT_RECORD:?}" "$@"
EOF
cat >"${FAKE_BIN}/real-scheduler-record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bash "${ACTUAL_SCHEDULER_RECORD:?}" "$@" \
  2>>"${REAL_SCHEDULER_ERR_LOG:?}"
EOF
cat >"${FAKE_BIN}/malformed-project-record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn \
  --argjson iid "${IID}" \
  --argjson attempt "${EXECUTION_ID}" '{
  status:"launch_failed_recorded",
  iid:$iid,
  execution_id:$attempt,
  final_status:"unknown",
  cleanup:{},
  remaining_pending_count:0,
  chat_summary:"forged project result"
}'
EOF
chmod +x "${FAKE_BIN}"/*.sh "${FAKE_BIN}/glab"
REAL_PROJECT_RECORD_CMD="${FAKE_BIN}/real-project-record.sh"
REAL_SCHEDULER_RECORD_CMD="${FAKE_BIN}/real-scheduler-record.sh"
REAL_SCHEDULER_ERR_LOG="${TEST_ROOT}/real-scheduler.err"
: >"${REAL_SCHEDULER_ERR_LOG}"

write_minimal_batch_request() {
  mkdir -p "${SCHEDULER_ROOT}/batches/A"
  jq -cnS '{
    version:1,batch_id:"A",project:"group/repo",
    dispatcher_callback_target:"agent:req_dispatcher:main"
  }' >"${SCHEDULER_ROOT}/batches/A/request.json"
}

write_scheduler_job() {
  local job_id="$1" generation="$2" token="$3"
  write_minimal_batch_request
  jq -cn \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --arg token "${token}" '{
    version:1,
    round_robin_cursor:null,
    batch_order:["A"],
    active_jobs:{($job_id):{
      job_id:$job_id,project:"group/repo",iid:42,status:"preparing",
      claim_generation:$generation,claim_token:$token
    }}
  }' >"${SCHEDULER_ROOT}/scheduler_state.json"
}

write_fenced_scheduler_job() {
  local job_id="$1" generation="$2"
  write_minimal_batch_request
  jq -cn \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" '{
    version:1,
    round_robin_cursor:null,
    batch_order:["A"],
    active_jobs:{($job_id):{
      job_id:$job_id,project:"group/repo",iid:42,status:"reserved",
      claim_generation:$generation,claim_token:null
    }}
  }' >"${SCHEDULER_ROOT}/scheduler_state.json"
}

write_emitted_action() {
  local job_id="$1" generation="$2" token="$3" attempt="$4" digest action_file
  digest="$(printf '%s' "${job_id}" | shasum -a 256 | awk '{print $1}')"
  mkdir -p "${SCHEDULER_ROOT}/launch_actions"
  action_file="${SCHEDULER_ROOT}/launch_actions/${digest}.json"
  jq -cnS \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --arg token "${token}" \
    --argjson attempt "${attempt}" '{
    version:1,job_id:$job_id,project:"group/repo",iid:42,
    batch_id:"A",snapshot_index:0,execution_id:$attempt,
    child_label:"#42-att-001",payload_path:"/private/payload",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    claim_generation:$generation,claim_token:$token,
    stage:"action_emitted",outcome:null,ack:null,
    created_at:1,updated_at:1
  }' >"${action_file}"
  chmod 600 "${action_file}"
}

write_legacy_emitted_action() {
  local job_id="$1" generation="$2" token="$3" legacy_number="$4"
  local digest action_file
  digest="$(printf '%s' "${job_id}" | shasum -a 256 | awk '{print $1}')"
  mkdir -p "${SCHEDULER_ROOT}/launch_actions"
  action_file="${SCHEDULER_ROOT}/launch_actions/${digest}.json"
  jq -cnS \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --arg token "${token}" \
    --argjson legacy_number "${legacy_number}" '{
    version:1,job_id:$job_id,project:"group/repo",iid:42,
    batch_id:"A",snapshot_index:0,attempt_number:$legacy_number,
    child_label:"#42-att-legacy",payload_path:"/private/payload",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    claim_generation:$generation,claim_token:$token,
    stage:"action_emitted",outcome:null,ack:null,
    created_at:1,updated_at:1
  }' >"${action_file}"
  chmod 600 "${action_file}"
}

cold_launch_failed_receipt() {
  local root="$1" job_id="$2" digest
  digest="$(printf '%s' "${job_id}" | shasum -a 256 | awk '{print $1}')"
  printf '%s/launch_failed_receipts/%s.json\n' "${root}" "${digest}"
}

spawn_input() {
  local job_id="$1" generation="$2" attempt="$3"
  jq -cn \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --argjson attempt "${attempt}" '{
    job_id:$job_id,
    claim_generation:$generation,
    project:"group/repo",
    iid:42,
    execution_id:$attempt,
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    status:"spawned",
    run_id:("run-" + ($attempt|tostring)),
    child_session_key:("agent:req_executor:subagent:" + ($attempt|tostring))
  }'
}

launch_failed_input() {
  local job_id="$1" generation="$2" attempt="$3"
  jq -cn \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --argjson attempt "${attempt}" '{
    job_id:$job_id,
    claim_generation:$generation,
    project:"group/repo",
    iid:42,
    execution_id:$attempt,
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:42,
    status:"launch_failed",
    launch_attempts:3,
    launch_error:("transport-failed-" + ($attempt|tostring))
  }'
}

record_result() {
  local input="$1" fault="${2:-}"
  local project_record_cmd="${3:-${FAKE_BIN}/project_record.sh}"
  local scheduler_record_cmd="${4:-${FAKE_BIN}/scheduler_record.sh}"
  printf '%s' "${input}" | \
    PATH="${FAKE_BIN}:${PATH}" GLAB_BIN="${FAKE_BIN}/glab" \
    ACTUAL_PROJECT_RECORD="${PROJECT_RECORD_SCRIPT}" \
    ACTUAL_SCHEDULER_RECORD="${SCHEDULER_RECORD_SCRIPT}" \
    REAL_SCHEDULER_ERR_LOG="${REAL_SCHEDULER_ERR_LOG}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    TEST_ROOT="${TEST_ROOT}" \
    CALL_LOG="${CALL_LOG}" \
    JOB_ID_FOR_TEST="$(jq -r '.job_id' <<<"${input}")" \
    SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
    RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
    PROJECT_RECORD_CMD="${project_record_cmd}" \
    RECORD_LAUNCH_CMD="${scheduler_record_cmd}" \
    DRIVEN_COORDINATOR_FAULT="${fault}" \
    bash "${RECORD_SCRIPT}"
}

run_recovery_tick() {
  local project_fail_once="${1:-0}" scheduler_fail_once="${2:-0}"
  local project_record_cmd="${3:-${FAKE_BIN}/project_record.sh}"
  local scheduler_record_cmd="${4:-${FAKE_BIN}/scheduler_record.sh}"
  local job_id_for_test="unknown"
  if find "${SCHEDULER_ROOT}/launch_actions" -maxdepth 1 -type f \
      -name '*.json' -print -quit 2>/dev/null | grep -q .; then
    job_id_for_test="$(find "${SCHEDULER_ROOT}/launch_actions" -maxdepth 1 \
      -type f -name '*.json' -print -quit | xargs jq -r '.job_id')"
  fi
  CONFIG_DIR="${CONFIG_DIR}" SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" GLAB_BIN="${FAKE_BIN}/glab" \
    ACTUAL_PROJECT_RECORD="${PROJECT_RECORD_SCRIPT}" \
    ACTUAL_SCHEDULER_RECORD="${SCHEDULER_RECORD_SCRIPT}" \
    REAL_SCHEDULER_ERR_LOG="${REAL_SCHEDULER_ERR_LOG}" \
    TEST_ROOT="${TEST_ROOT}" CALL_LOG="${CALL_LOG}" \
    JOB_ID_FOR_TEST="${job_id_for_test}" \
    PROJECT_FAIL_ONCE="${project_fail_once}" \
    SCHEDULER_FAIL_ONCE="${scheduler_fail_once}" \
    SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
    RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
    DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_intents.sh" \
    DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_outbox.sh" \
    RESERVE_CMD="${FAKE_BIN}/reserve.sh" \
    TOPUP_CMD="${FAKE_BIN}/unused.sh" \
    IMPORT_SKIP_CMD="${FAKE_BIN}/unused.sh" \
    RECORD_LAUNCH_CMD="${scheduler_record_cmd}" \
    BIND_CLAIM_CMD="${FAKE_BIN}/unused.sh" \
    RESUME_SPAWN_CMD="${RECORD_SCRIPT}" \
    PROJECT_RECORD_CMD="${project_record_cmd}" \
      bash "${TICK_SCRIPT}"
}

assert_one_action_file() {
  local expected_stage="$1"
  mapfile -t action_files < <(find "${SCHEDULER_ROOT}/launch_actions" \
    -maxdepth 1 -type f -name '*.json' -print)
  [ "${#action_files[@]}" -eq 1 ] \
    || fail "expected one durable launch action, got ${#action_files[@]}"
  [ "$(stat -f '%Lp' "${action_files[0]}" 2>/dev/null || stat -c '%a' "${action_files[0]}")" = 600 ] \
    || fail "launch action containing a private claim is not mode 600"
  jq -e --arg stage "${expected_stage}" '
    .stage == $stage
    and (.claim_token | type == "string" and length > 0)
    and ((.outcome == "spawned"
        and (.ack.run_id | type == "string" and length > 0)
        and (.ack.child_session_key | type == "string" and length > 0))
      or (.outcome == "launch_failed"
        and (.ack.launch_attempts | type == "number" and . > 0)
        and (.ack.launch_error | type == "string" and length > 0)))
  ' "${action_files[0]}" >/dev/null \
    || fail "launch action is not durably at stage ${expected_stage}"
}

PROJECT_CAMPAIGN_STATE="${TEST_ROOT}/repos/group/repo/.req_executor/_dispatcher/campaign_state.json"

write_project_pending() {
  local job_id="$1" generation="$2" token="$3" attempt="$4" quota="${5:-0}"
  mkdir -p "$(dirname "${PROJECT_CAMPAIGN_STATE}")"
  jq -cnS \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --arg token "${token}" \
    --argjson attempt "${attempt}" \
    --argjson quota "${quota}" '{
    project:"repo",
    blocked_retry_limit:3,
    pending_subagents:{
      "42":{
        execution_id:$attempt,
        job_id:$job_id,
        batch_id:"A",
        snapshot_index:0,
        memberships_source:"scheduler_active_job",
        expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
        expected_task_bytes:42,
        claim_generation:$generation,
        claim_token:$token,
        placeholder:true
      }
    },
    active_issue_iids:[42],
    active_issue_sessions:["issue-repo-42"],
    blocked_at_tick_by_iid:{},
    unfinished_iids:[],
    completed_iids:[],
    blocked_iids:[],
    failed_iids:[],
    timeout_iids:[],
    campaign_status:"running",
    quota_launched_this_tick:$quota,
    updated_at:"2026-07-11T00:00:00Z"
  }' >"${PROJECT_CAMPAIGN_STATE}"
}

run_project_record_direct() {
  local job_id="$1" generation="$2" token="$3" attempt="$4" status="$5"
  local run_id="${6:-}" child_session_key="${7:-}"
  local launch_error="${8:-transport-failed}"
  PATH="${FAKE_BIN}:${PATH}" GLAB_BIN="${FAKE_BIN}/glab" \
  PROJECT=repo GROUP=group GITLAB_TOKEN=fixture-token \
  REPO_PARENT_PATH="${TEST_ROOT}/repos/group" \
  IID=42 EXECUTION_ID="${attempt}" STATUS="${status}" \
  DRIVEN_JOB_ID="${job_id}" \
  DRIVEN_CLAIM_GENERATION="${generation}" \
  DRIVEN_CLAIM_TOKEN="${token}" \
  EXPECTED_TASK_SHA256=0000000000000000000000000000000000000000000000000000000000000042 \
  EXPECTED_TASK_BYTES=42 \
  RUN_ID="${run_id}" CHILD_SESSION_KEY="${child_session_key}" \
  LAUNCH_ATTEMPTS=3 LAUNCH_ERROR="${launch_error}" \
    bash "${PROJECT_RECORD_SCRIPT}"
}

write_real_scheduler_job() {
  local job_id="$1" generation="$2" token="$3" now
  now="$(date +%s)"
  mkdir -p "${SCHEDULER_ROOT}/batches/A"
  jq -cnS '{
    version:1,batch_id:"A",correlation_id:"correlation-A",
    project:"group/repo",selector:{type:"single",iid:42},
    force_rerun_pr:false,auto_merge:false,merge_target_branch:null,
    dispatcher_callback_target:"agent:req_dispatcher:main",branch:null
  }' >"${SCHEDULER_ROOT}/batches/A/request.json"
  jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
    >"${SCHEDULER_ROOT}/batches/A/snapshot.json"
  jq -cnS --arg job_id "${job_id}" '{
    version:1,batch_id:"A",status:"running",matched_count:1,
    terminal_count:0,done_count:0,failed_count:0,timeout_count:0,
    skipped_count:0,next_snapshot_index:1,
    request_digest:"fixture-request",snapshot_digest:"fixture-snapshot",
    memberships:{
      "0":{snapshot_index:0,iid:42,status:"preparing",job_id:$job_id}
    }
  }' >"${SCHEDULER_ROOT}/batches/A/state.json"
  jq -cnS \
    --arg job_id "${job_id}" \
    --argjson generation "${generation}" \
    --arg token "${token}" \
    --argjson now "${now}" '{
    version:1,round_robin_cursor:null,batch_order:["A"],
    active_jobs:{($job_id):{
      job_id:$job_id,physical_key:"group/repo#42",project:"group/repo",iid:42,
      branch:null,entry_mode:"auto",force_rerun_pr:false,
      auto_merge:false,merge_target_branch:null,status:"preparing",
      reservation_seq:1,claim_generation:$generation,claim_token:$token,
      reserved_at:$now,updated_at:$now,
      owner:{batch_id:"A",snapshot_index:0},
      memberships:[{batch_id:"A",snapshot_index:0}]
    }}
  }' >"${SCHEDULER_ROOT}/scheduler_state.json"
}

run_scheduler_launch_failed_direct() {
  local job_id="$1" generation="$2" token="$3"
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${job_id}" ACTION=launch_failed \
  EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
  CLAIM_GENERATION="${generation}" CLAIM_TOKEN="${token}" \
    bash "${SCHEDULER_RECORD_SCRIPT}"
}

# A hot action written by the old schema is an explicit rolling-upgrade gate.
# The global tick must keep the file byte-stable and return a bounded envelope
# instead of aborting all scheduler recovery as corrupt state.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-legacy-schema"
mkdir -p "${SCHEDULER_ROOT}"
write_scheduler_job 'A:legacy-schema' 1 'private-legacy-claim'
write_legacy_emitted_action 'A:legacy-schema' 1 'private-legacy-claim' 7
legacy_action_file="$(find "${SCHEDULER_ROOT}/launch_actions" -maxdepth 1 \
  -type f -name '*.json' -print -quit)"
cp "${legacy_action_file}" "${TEST_ROOT}/legacy-action.before.json"
legacy_gate_output="$(run_recovery_tick)" \
  || fail "legacy execution-schema gate crashed the global tick"
jq -e '
  .status == "tick_failed"
  and .spawn_grants == []
  and ([.operation_results[] | select(
    .operation == "launch_coordinator"
    and .status == "legacy_execution_schema"
    and .action == "drain_required"
  )] | length) == 1
' <<<"${legacy_gate_output}" >/dev/null \
  || fail "legacy execution schema was not isolated behind a drain gate"
cmp -s "${legacy_action_file}" "${TEST_ROOT}/legacy-action.before.json" \
  || fail "new tick rewrote the old coordinator identity"

SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${SCHEDULER_ROOT}"

# Crash after ack persistence: no project/scheduler record happened. A later
# tick alone must retain a temporary project failure, then resume project and
# scheduler without the original caller resubmitting its ack.
write_scheduler_job 'A:snapshot-0' 1 'private-claim-1'
: >"${CALL_LOG}"
set +e
record_result "$(spawn_input 'A:snapshot-0' 1 1)" after_ack_persist >/dev/null
ack_fault_rc=$?
set -e
[ "${ack_fault_rc}" -eq 86 ] \
  || fail "after_ack_persist fault did not stop at exit 86 (got ${ack_fault_rc})"
[ ! -s "${CALL_LOG}" ] || fail "ack-persist crash called a downstream recorder"
assert_one_action_file ack_received
ack_pending="$(run_recovery_tick 1 0)" \
  || fail "tick could not retain a temporary project record failure"
jq -e '
  .status == "tick_failed"
  and ([.operation_results[] | select(.operation == "launch_resume"
    and .status == "project_record_pending")] | length) == 1
  and .spawn_grants == []
' <<<"${ack_pending}" >/dev/null \
  || fail "tick did not report the durable project pending stage"
assert_one_action_file ack_received
ack_replay="$(run_recovery_tick 1 0)" \
  || fail "tick did not resume the durable runtime ack"
[ "$(cat "${CALL_LOG}")" = $'project-failed:spawned:A:snapshot-0\nproject:spawned:A:snapshot-0\nscheduler:spawned:A:snapshot-0' ] \
  || fail "tick did not resume project then scheduler exactly once"
jq -e '
  .status == "idle"
  and ([.operation_results[] | select(.operation == "launch_resume"
    and .status == "spawned_recorded")] | length) == 1
' <<<"${ack_replay}" >/dev/null || fail "ack tick replay returned an unsafe envelope"
assert_one_action_file completed

# Exact project crash window for spawned: project campaign state is already
# committed, but the coordinator still says ack_received. Tick-only replay must
# consume the exact project receipt without refreshing spawned_at, increasing
# quota again, or changing campaign_state.json bytes.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-project-spawned-fault"
mkdir -p "${SCHEDULER_ROOT}"
write_scheduler_job 'A:snapshot-1' 1 'private-claim-2'
write_project_pending 'A:snapshot-1' 1 'private-claim-2' 2 5
: >"${CALL_LOG}"
set +e
record_result "$(spawn_input 'A:snapshot-1' 1 2)" after_project_record \
  "${REAL_PROJECT_RECORD_CMD}" "${FAKE_BIN}/scheduler_record.sh" >/dev/null
project_fault_rc=$?
set -e
[ "${project_fault_rc}" -eq 87 ] \
  || fail "after_project_record fault did not stop at exit 87 (got ${project_fault_rc})"
[ ! -s "${CALL_LOG}" ] || fail "project-side crash crossed the scheduler boundary"
assert_one_action_file ack_received
jq -e '
  .quota_launched_this_tick == 6
  and (.pending_subagents["42"].spawned_at | type == "string" and length > 0)
  and (.driven_launch_receipts["A:snapshot-1"]
    | .version == 1
      and .job_id == "A:snapshot-1"
      and .claim_generation == 1
      and (.claim_token_sha256 | test("^[0-9a-f]{64}$"))
      and .outcome == "spawned"
      and .ack.run_id == "run-2"
      and .ack.child_session_key == "agent:req_executor:subagent:2"
      and (tostring | contains("private-claim-2") | not))
' "${PROJECT_CAMPAIGN_STATE}" >/dev/null \
  || fail "spawned project mutation and exact receipt were not committed together"
cp "${PROJECT_CAMPAIGN_STATE}" "${TEST_ROOT}/project-spawned-after-crash.json"
spawned_at_before="$(jq -r '.pending_subagents["42"].spawned_at' \
  "${PROJECT_CAMPAIGN_STATE}")"
spawned_replay="$(run_recovery_tick 0 0 \
  "${REAL_PROJECT_RECORD_CMD}" "${FAKE_BIN}/scheduler_record.sh")" \
  || fail "tick did not replay the spawned project receipt"
jq -e '.status == "idle" and .spawn_grants == []' \
  <<<"${spawned_replay}" >/dev/null \
  || fail "spawned project receipt replay returned an unsafe tick envelope"
cmp -s "${PROJECT_CAMPAIGN_STATE}" \
  "${TEST_ROOT}/project-spawned-after-crash.json" \
  || fail "spawned project receipt replay changed campaign state bytes"
[ "$(jq -r '.quota_launched_this_tick' "${PROJECT_CAMPAIGN_STATE}")" -eq 6 ] \
  && [ "$(jq -r '.pending_subagents["42"].spawned_at' \
    "${PROJECT_CAMPAIGN_STATE}")" = "${spawned_at_before}" ] \
  || fail "spawned project receipt replay changed quota or spawned_at"
assert_one_action_file completed

for conflict_spec in \
  'spawned changed-run agent:req_executor:subagent:2 ignored' \
  'spawned run-2 agent:req_executor:subagent:changed ignored' \
  'launch_failed empty empty changed-outcome'
do
  read -r conflict_status conflict_run conflict_session conflict_error \
    <<<"${conflict_spec}"
  if run_project_record_direct 'A:snapshot-1' 1 'private-claim-2' 2 \
      "${conflict_status}" "${conflict_run}" "${conflict_session}" \
      "${conflict_error}" >"${TEST_ROOT}/project-conflict.out" \
      2>"${TEST_ROOT}/project-conflict.err"; then
    fail "project receipt accepted conflicting ${conflict_status} outcome"
  fi
  cmp -s "${PROJECT_CAMPAIGN_STATE}" \
    "${TEST_ROOT}/project-spawned-after-crash.json" \
    || fail "conflicting project receipt replay mutated campaign state"
done

# launch_failed removes pending_subagents. Its exact project receipt must still
# authorize tick-only replay from ack_received without rebuilding Phase 6.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-project-launch-failed-fault"
mkdir -p "${SCHEDULER_ROOT}"
write_scheduler_job 'A:snapshot-2' 1 'private-claim-3'
write_project_pending 'A:snapshot-2' 1 'private-claim-3' 3 9
: >"${CALL_LOG}"
set +e
record_result "$(launch_failed_input 'A:snapshot-2' 1 3)" \
  after_project_record "${REAL_PROJECT_RECORD_CMD}" \
  "${FAKE_BIN}/scheduler_record.sh" >/dev/null
launch_project_fault_rc=$?
set -e
[ "${launch_project_fault_rc}" -eq 87 ] \
  || fail "launch_failed project fault did not stop at exit 87"
assert_one_action_file ack_received
jq -e '
  (.pending_subagents | has("42") | not)
  and (.driven_launch_receipts["A:snapshot-2"]
    | .outcome == "launch_failed"
      and .ack.launch_attempts == 3
      and .ack.launch_error == "transport-failed-3"
      and .result.status == "launch_failed_recorded")
  and (tostring | contains("private-claim-3") | not)
' "${PROJECT_CAMPAIGN_STATE}" >/dev/null \
  || fail "launch_failed project receipt was not committed with pending drain"
cp "${PROJECT_CAMPAIGN_STATE}" "${TEST_ROOT}/project-launch-failed-after-crash.json"
launch_project_action_file="$(find "${SCHEDULER_ROOT}/launch_actions" \
  -maxdepth 1 -type f -name '*.json' -print -quit)"
cp "${launch_project_action_file}" \
  "${TEST_ROOT}/launch-project-action-ack-received.json"

# A durable receipt is an execution authorization, so every result field must
# fail closed when corrupted. Recovery must leave the coordinator at
# ack_received instead of advancing from a superficially matching status/IID.
for receipt_mutation in \
  final_status_number \
  final_status_unknown \
  cleanup_empty \
  cleanup_extra \
  cleanup_missing \
  remaining_type \
  chat_type
do
  cp "${TEST_ROOT}/project-launch-failed-after-crash.json" \
    "${PROJECT_CAMPAIGN_STATE}"
  cp "${TEST_ROOT}/launch-project-action-ack-received.json" \
    "${launch_project_action_file}"
  case "${receipt_mutation}" in
    final_status_number)
      receipt_filter='.driven_launch_receipts["A:snapshot-2"].result.final_status = 7'
      ;;
    final_status_unknown)
      receipt_filter='.driven_launch_receipts["A:snapshot-2"].result.final_status = "unknown"'
      ;;
    cleanup_empty)
      receipt_filter='.driven_launch_receipts["A:snapshot-2"].result.cleanup = {}'
      ;;
    cleanup_extra)
      receipt_filter='.driven_launch_receipts["A:snapshot-2"].result.cleanup.extra = true'
      ;;
    cleanup_missing)
      receipt_filter='del(.driven_launch_receipts["A:snapshot-2"].result.cleanup.reason)'
      ;;
    remaining_type)
      receipt_filter='.driven_launch_receipts["A:snapshot-2"].result.remaining_pending_count = "0"'
      ;;
    chat_type)
      receipt_filter='.driven_launch_receipts["A:snapshot-2"].result.chat_summary = 42'
      ;;
  esac
  jq -cS "${receipt_filter}" "${PROJECT_CAMPAIGN_STATE}" \
    >"${PROJECT_CAMPAIGN_STATE}.mutated"
  mv "${PROJECT_CAMPAIGN_STATE}.mutated" "${PROJECT_CAMPAIGN_STATE}"
  cp "${PROJECT_CAMPAIGN_STATE}" \
    "${TEST_ROOT}/receipt-${receipt_mutation}.before.json"

  mutated_replay="$(run_recovery_tick 0 0 \
    "${REAL_PROJECT_RECORD_CMD}" "${FAKE_BIN}/scheduler_record.sh")" \
    || fail "tick crashed while rejecting ${receipt_mutation} receipt"
  jq -e '
    .status == "tick_failed"
    and ([.operation_results[] | select(.operation == "launch_resume"
      and .status == "project_record_pending")] | length) == 1
    and .spawn_grants == []
  ' <<<"${mutated_replay}" >/dev/null \
    || fail "tick advanced from corrupted ${receipt_mutation} receipt"
  cmp -s "${PROJECT_CAMPAIGN_STATE}" \
    "${TEST_ROOT}/receipt-${receipt_mutation}.before.json" \
    || fail "rejecting ${receipt_mutation} receipt changed campaign bytes"
  assert_one_action_file ack_received
done

# Independently verify the coordinator's project-result boundary. Even when a
# recorder exits zero, a forged partial result must not acknowledge project
# durability or allow scheduler recording.
cp "${TEST_ROOT}/project-launch-failed-after-crash.json" \
  "${PROJECT_CAMPAIGN_STATE}"
cp "${TEST_ROOT}/launch-project-action-ack-received.json" \
  "${launch_project_action_file}"
malformed_project_replay="$(run_recovery_tick 0 0 \
  "${FAKE_BIN}/malformed-project-record.sh" \
  "${FAKE_BIN}/scheduler_record.sh")" \
  || fail "tick crashed while rejecting malformed project output"
jq -e '
  .status == "tick_failed"
  and ([.operation_results[] | select(.operation == "launch_resume"
    and .status == "project_record_pending")] | length) == 1
  and .spawn_grants == []
' <<<"${malformed_project_replay}" >/dev/null \
  || fail "coordinator accepted malformed project output"
assert_one_action_file ack_received

# Restore the exact valid receipt/action pair before proving byte-stable replay.
cp "${TEST_ROOT}/project-launch-failed-after-crash.json" \
  "${PROJECT_CAMPAIGN_STATE}"
cp "${TEST_ROOT}/launch-project-action-ack-received.json" \
  "${launch_project_action_file}"
launch_project_replay="$(run_recovery_tick 0 0 \
  "${REAL_PROJECT_RECORD_CMD}" "${FAKE_BIN}/scheduler_record.sh")" \
  || fail "tick could not replay launch_failed after pending was removed"
jq -e '.status == "idle" and .spawn_grants == []' \
  <<<"${launch_project_replay}" >/dev/null \
  || fail "launch_failed project receipt replay did not complete"
cmp -s "${PROJECT_CAMPAIGN_STATE}" \
  "${TEST_ROOT}/project-launch-failed-after-crash.json" \
  || fail "launch_failed project receipt replay changed campaign bytes"
assert_one_action_file completed
if run_project_record_direct 'A:snapshot-2' 1 'private-claim-3' 3 \
    launch_failed '' '' changed-error >"${TEST_ROOT}/launch-conflict.out" \
    2>"${TEST_ROOT}/launch-conflict.err"; then
  fail "launch_failed project receipt accepted a conflicting error"
fi
cmp -s "${PROJECT_CAMPAIGN_STATE}" \
  "${TEST_ROOT}/project-launch-failed-after-crash.json" \
  || fail "conflicting launch_failed receipt replay changed campaign bytes"

# Exact scheduler crash window for launch_failed: the real scheduler has
# deleted active_jobs[job] and committed its tombstone, while the coordinator
# remains project_recorded. The next tick must validate the tombstone and
# complete without repeating project work or changing scheduler bytes.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-launch-failed-final-fault"
mkdir -p "${SCHEDULER_ROOT}"
write_real_scheduler_job 'A:snapshot-3' 1 'private-claim-4'
: >"${CALL_LOG}"
set +e
record_result "$(launch_failed_input 'A:snapshot-3' 1 4)" \
  after_scheduler_record "${FAKE_BIN}/project_record.sh" \
  "${REAL_SCHEDULER_RECORD_CMD}" >/dev/null
scheduler_fault_rc=$?
set -e
[ "${scheduler_fault_rc}" -eq 88 ] \
  || fail "after_scheduler_record fault did not stop at exit 88 (got ${scheduler_fault_rc})"
[ "$(grep -c '^project:' "${CALL_LOG}")" -eq 1 ] \
  || fail "scheduler fault did not record project exactly once"
assert_one_action_file project_recorded
SCHEDULER_RECEIPT_3="$(cold_launch_failed_receipt "${SCHEDULER_ROOT}" 'A:snapshot-3')"
jq -e '
  (.active_jobs | has("A:snapshot-3") | not)
  and (has("launch_failed_receipts") | not)
  and (tostring | contains("private-claim-4") | not)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "scheduler launch_failed delete polluted hot scheduler state"
jq -e '
  .version == 1
  and .job_id == "A:snapshot-3"
  and .claim_generation == 1
  and (.claim_token_sha256 | test("^[0-9a-f]{64}$"))
  and .action == "launch_failed"
  and (tostring | contains("private-claim-4") | not)
' "${SCHEDULER_RECEIPT_3}" >/dev/null \
  || fail "scheduler launch_failed cold tombstone was not durable"
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-launch-failed-after-crash.json"
scheduler_replay="$(run_recovery_tick 0 0 \
  "${FAKE_BIN}/project_record.sh" "${REAL_SCHEDULER_RECORD_CMD}")" \
  || fail "tick did not replay the scheduler launch_failed tombstone"
jq -e '.status == "idle" and .spawn_grants == []' \
  <<<"${scheduler_replay}" >/dev/null \
  || fail "scheduler tombstone replay returned an unsafe tick envelope"
[ "$(grep -c '^project:' "${CALL_LOG}")" -eq 1 ] \
  || fail "scheduler tombstone recovery repeated project recording"
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-launch-failed-after-crash.json" \
  || fail "scheduler tombstone replay changed scheduler state bytes"
assert_one_action_file completed

for scheduler_conflict in '2 private-claim-4' '1 wrong-private-claim'; do
  read -r conflict_generation conflict_token <<<"${scheduler_conflict}"
  if run_scheduler_launch_failed_direct 'A:snapshot-3' \
      "${conflict_generation}" "${conflict_token}" \
      >"${TEST_ROOT}/scheduler-conflict.out" \
      2>"${TEST_ROOT}/scheduler-conflict.err"; then
    fail "scheduler tombstone accepted a conflicting claim"
  fi
  cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
    "${TEST_ROOT}/scheduler-launch-failed-after-crash.json" \
    || fail "conflicting scheduler tombstone replay mutated state"
done

# Reusing the same physical job and numeric generation with a new private token
# must prioritize the current active claim over the old tombstone. The new
# failure overwrites the tombstone; the old token remains rejected afterward.
old_scheduler_receipt="$(jq -c . "${SCHEDULER_RECEIPT_3}")"
write_real_scheduler_job 'A:snapshot-3' 1 'new-private-claim-4'
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-new-claim-before-old-replay.json"
if run_scheduler_launch_failed_direct 'A:snapshot-3' 1 'private-claim-4' \
    >"${TEST_ROOT}/old-receipt-active.out" \
    2>"${TEST_ROOT}/old-receipt-active.err"; then
  fail "old tombstone bypassed a current same-generation claim"
fi
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-new-claim-before-old-replay.json" \
  || fail "rejected old tombstone replay mutated the current claim"
new_claim_result="$(run_scheduler_launch_failed_direct \
  'A:snapshot-3' 1 'new-private-claim-4')" \
  || fail "current same-generation claim could not record launch_failed"
jq -e '.status == "recorded" and .job_status == "launch_failed"' \
  <<<"${new_claim_result}" >/dev/null \
  || fail "current claim returned an invalid scheduler result"
jq -e --argjson old "${old_scheduler_receipt}" '
  .claim_generation == 1
  and .claim_token_sha256 != $old.claim_token_sha256
  and (tostring | contains("new-private-claim-4") | not)
' "${SCHEDULER_RECEIPT_3}" >/dev/null \
  || fail "new claim did not replace the old token-bound tombstone"
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-new-claim-after-record.json"
if run_scheduler_launch_failed_direct 'A:snapshot-3' 1 'private-claim-4' \
    >"${TEST_ROOT}/old-receipt-after-replace.out" \
    2>"${TEST_ROOT}/old-receipt-after-replace.err"; then
  fail "replaced old tombstone remained valid"
fi
if CONFIG_DIR="${CONFIG_DIR}" \
    EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    JOB_ID='A:snapshot-3' ACTION=spawned \
    CLAIM_GENERATION=1 CLAIM_TOKEN='new-private-claim-4' \
    bash "${SCHEDULER_RECORD_SCRIPT}" \
    >"${TEST_ROOT}/wrong-action.out" 2>"${TEST_ROOT}/wrong-action.err"; then
  fail "launch_failed tombstone authorized a different scheduler action"
fi
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-new-claim-after-record.json" \
  || fail "conflicting old receipt or action changed scheduler bytes"

cp "${SCHEDULER_RECEIPT_3}" "${TEST_ROOT}/scheduler-before-malformed-receipt.json"
jq '.claim_token_sha256 = "bad"' "${SCHEDULER_RECEIPT_3}" \
  >"${SCHEDULER_RECEIPT_3}.malformed"
mv "${SCHEDULER_RECEIPT_3}.malformed" "${SCHEDULER_RECEIPT_3}"
cp "${SCHEDULER_RECEIPT_3}" "${TEST_ROOT}/scheduler-malformed-receipt.json"
if run_scheduler_launch_failed_direct 'A:snapshot-3' 1 'new-private-claim-4' \
    >"${TEST_ROOT}/malformed-receipt.out" \
    2>"${TEST_ROOT}/malformed-receipt.err"; then
  fail "malformed scheduler tombstone did not fail closed"
fi
cmp -s "${SCHEDULER_RECEIPT_3}" \
  "${TEST_ROOT}/scheduler-malformed-receipt.json" \
  || fail "malformed scheduler tombstone was mutated during rejection"
cp "${TEST_ROOT}/scheduler-before-malformed-receipt.json" \
  "${SCHEDULER_RECEIPT_3}"

# The transaction marker itself contains the tombstone. If final scheduler
# publication fails, the next exact ACTION must recover the marker and return
# idempotent success with the tombstone intact.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-launch-failed-transaction"
mkdir -p "${SCHEDULER_ROOT}"
write_real_scheduler_job 'A:snapshot-4' 1 'private-claim-5'
RECORD_CRASH_BIN="${TEST_ROOT}/record-crash-bin"
mkdir -p "${RECORD_CRASH_BIN}"
cat >"${RECORD_CRASH_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${*: -1}"
if [ "${destination}" = "${FAIL_SCHEDULER_DEST:?}" ]; then
  count=0
  [ ! -f "${MV_COUNT_FILE:?}" ] || count="$(<"${MV_COUNT_FILE}")"
  count=$((count + 1))
  printf '%s' "${count}" >"${MV_COUNT_FILE}"
  [ "${count}" -ne 2 ] || exit 97
fi
exec /bin/mv "$@"
EOF
chmod +x "${RECORD_CRASH_BIN}/mv"
set +e
PATH="${RECORD_CRASH_BIN}:${PATH}" \
FAIL_SCHEDULER_DEST="${SCHEDULER_ROOT}/scheduler_state.json" \
MV_COUNT_FILE="${TEST_ROOT}/launch-failed-record-mv-count" \
  run_scheduler_launch_failed_direct 'A:snapshot-4' 1 'private-claim-5' \
  >"${TEST_ROOT}/transaction-crash.out" 2>"${TEST_ROOT}/transaction-crash.err"
transaction_fault_rc=$?
set -e
[ "${transaction_fault_rc}" -eq 97 ] \
  || fail "scheduler final publish fault did not stop at exit 97"
jq -e '
  .pending_transaction.scheduler_state
  | (.active_jobs | has("A:snapshot-4") | not)
    and (has("launch_failed_receipts") | not)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "pending transaction retained launch_failed history in hot state"
SCHEDULER_RECEIPT_4="$(cold_launch_failed_receipt "${SCHEDULER_ROOT}" 'A:snapshot-4')"
jq -e '.claim_generation == 1 and .action == "launch_failed"' \
  "${SCHEDULER_RECEIPT_4}" >/dev/null \
  || fail "pending transaction crash lost the cold launch_failed tombstone"
transaction_replay="$(run_scheduler_launch_failed_direct \
  'A:snapshot-4' 1 'private-claim-5')" \
  || fail "exact ACTION did not recover the pending transaction tombstone"
jq -e '
  .status == "recorded"
  and .job_id == "A:snapshot-4"
  and .job_status == "launch_failed"
' <<<"${transaction_replay}" >/dev/null \
  || fail "pending transaction tombstone replay returned an invalid response"
jq -e '
  (has("pending_transaction") | not)
  and (.active_jobs | has("A:snapshot-4") | not)
  and (has("launch_failed_receipts") | not)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "pending transaction recovery repopulated hot tombstone history"
jq -e '.claim_generation == 1 and .action == "launch_failed"' \
  "${SCHEDULER_RECEIPT_4}" >/dev/null \
  || fail "pending transaction recovery did not preserve the cold tombstone"

# If reserve already fenced an unacknowledged emitted action back to reserved,
# recovered runtime evidence must restore the same generation after recording
# the project. It must never use the ordinary preparing-only spawned action.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-fenced-runtime-found"
mkdir -p "${SCHEDULER_ROOT}"
write_fenced_scheduler_job 'A:snapshot-3' 1
write_emitted_action 'A:snapshot-3' 1 'private-claim-4' 4
: >"${CALL_LOG}"
fenced_found="$(record_result "$(spawn_input 'A:snapshot-3' 1 4)")" \
  || fail "fenced runtime match was rejected"
[ "$(cat "${CALL_LOG}")" = $'project:spawned:A:snapshot-3\nscheduler:recovered_spawned:A:snapshot-3' ] \
  || fail "fenced runtime match did not restore the same scheduler generation project-first"
jq -e '
  .status == "spawned_recorded"
  and .claim_generation == 1
  and (tostring | contains("private-claim") | not)
' <<<"${fenced_found}" >/dev/null || fail "fenced runtime match returned an unsafe envelope"

# A launch failure acknowledgement can be durable longer than the preparing
# lease. Once reserve fences that exact generation back to reserved/token-null,
# recovery must use an explicit action instead of the ordinary current-claim
# transition; otherwise the project receipt and scheduler slot are stranded.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-fenced-launch-failed"
mkdir -p "${SCHEDULER_ROOT}"
write_fenced_scheduler_job 'A:snapshot-5' 1
write_emitted_action 'A:snapshot-5' 1 'private-claim-6' 6
: >"${CALL_LOG}"
fenced_launch_failed="$(record_result "$(launch_failed_input 'A:snapshot-5' 1 6)")" \
  || fail "fenced launch_failed acknowledgement was rejected"
[ "$(cat "${CALL_LOG}")" = $'project:launch_failed:A:snapshot-5\nscheduler:recovered_launch_failed:A:snapshot-5' ] \
  || fail "fenced launch_failed did not use its explicit recovery action"
jq -e '
  .status == "launch_failed_recorded"
  and .claim_generation == 1
  and (tostring | contains("private-claim") | not)
' <<<"${fenced_launch_failed}" >/dev/null \
  || fail "fenced launch_failed returned an unsafe envelope"

# The real scheduler recorder independently verifies the fixed durable action,
# its project-receipt digest, old private token, and same fenced generation.
SCHEDULER_ROOT="${TEST_ROOT}/scheduler-real-fenced-launch-failed"
mkdir -p "${SCHEDULER_ROOT}"
write_real_scheduler_job 'A:snapshot-6' 1 'private-claim-7'
jq '
  .active_jobs["A:snapshot-6"].status = "reserved"
  | .active_jobs["A:snapshot-6"].claim_token = null
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.fenced.json"
mv "${SCHEDULER_ROOT}/scheduler_state.fenced.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
jq '.memberships["0"].status = "reserved"' \
  "${SCHEDULER_ROOT}/batches/A/state.json" \
  >"${SCHEDULER_ROOT}/batches/A/state.fenced.json"
mv "${SCHEDULER_ROOT}/batches/A/state.fenced.json" \
  "${SCHEDULER_ROOT}/batches/A/state.json"
write_emitted_action 'A:snapshot-6' 1 'private-claim-7' 7
real_recovery_action="$(find "${SCHEDULER_ROOT}/launch_actions" \
  -maxdepth 1 -type f -name '*.json' -print -quit)"
jq '
  .stage = "project_recorded"
  | .outcome = "launch_failed"
  | .ack = {launch_attempts:3,launch_error:"transport-failed-7"}
  | .project_receipt_sha256 = ("a" * 64)
' "${real_recovery_action}" >"${real_recovery_action}.updated"
mv "${real_recovery_action}.updated" "${real_recovery_action}"
real_recovered_out="$(
  CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
  JOB_ID='A:snapshot-6' ACTION=recovered_launch_failed \
  CLAIM_GENERATION=1 CLAIM_TOKEN='private-claim-7' \
    bash "${SCHEDULER_RECORD_SCRIPT}"
)" || fail "real scheduler rejected a valid recovered_launch_failed action"
jq -e '.status == "recorded" and .job_status == "launch_failed"' \
  <<<"${real_recovered_out}" >/dev/null \
  || fail "real recovered_launch_failed returned an invalid acknowledgement"
jq -e '
  (.active_jobs | has("A:snapshot-6") | not)
  and (has("launch_failed_receipts") | not)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "real recovered_launch_failed did not release without hot tombstone history"
SCHEDULER_RECEIPT_6="$(cold_launch_failed_receipt "${SCHEDULER_ROOT}" 'A:snapshot-6')"
jq -e '
  .claim_generation == 1
  and .action == "launch_failed"
  and (.claim_token_sha256 | test("^[0-9a-f]{64}$"))
  and (tostring | contains("private-claim-7") | not)
' "${SCHEDULER_RECEIPT_6}" >/dev/null \
  || fail "real recovered_launch_failed did not persist its cold tombstone"

# A pre-upgrade coordinator may create the old hot lock after the new library's
# migration scan. During the compatibility window, dlc_open must also wait for
# that late old-path lock before entering the action critical section.
ROLLING_LAUNCH_ROOT="${TEST_ROOT}/scheduler-launch-lock-rolling"
ROLLING_LAUNCH_JOB='rolling-lock:snapshot-0'
ROLLING_LAUNCH_DIGEST="$(printf '%s' "${ROLLING_LAUNCH_JOB}" | shasum -a 256 | awk '{print $1}')"
ROLLING_LAUNCH_SCAN="${TEST_ROOT}/rolling-launch-scan"
ROLLING_LAUNCH_OLD_READY="${TEST_ROOT}/rolling-launch-old-ready"
ROLLING_LAUNCH_RELEASE="${TEST_ROOT}/rolling-launch-release"
ROLLING_LAUNCH_ACQUIRED="${TEST_ROOT}/rolling-launch-acquired"
mkdir -p "${ROLLING_LAUNCH_ROOT}/launch_actions"
(
  for _wait in $(seq 1 200); do
    [ -e "${ROLLING_LAUNCH_SCAN}" ] && break
    sleep 0.01
  done
  [ -e "${ROLLING_LAUNCH_SCAN}" ]
  exec 8>"${ROLLING_LAUNCH_ROOT}/launch_actions/.${ROLLING_LAUNCH_DIGEST}.lock"
  flock -x 8
  : >"${ROLLING_LAUNCH_OLD_READY}"
  for _wait in $(seq 1 300); do
    [ -e "${ROLLING_LAUNCH_RELEASE}" ] && break
    sleep 0.01
  done
  [ -e "${ROLLING_LAUNCH_RELEASE}" ]
  flock -u 8
) &
ROLLING_LAUNCH_OLD_PID=$!
EXECUTOR_SCHEDULER_ROOT="${ROLLING_LAUNCH_ROOT}" \
LEGACY_LOCK_COMPAT_ACTIVE=true \
ROLLING_LAUNCH_JOB="${ROLLING_LAUNCH_JOB}" \
ROLLING_LAUNCH_SCAN="${ROLLING_LAUNCH_SCAN}" \
ROLLING_LAUNCH_OLD_READY="${ROLLING_LAUNCH_OLD_READY}" \
ROLLING_LAUNCH_ACQUIRED="${ROLLING_LAUNCH_ACQUIRED}" \
bash -c '
  source "$1"
  : >"${ROLLING_LAUNCH_SCAN}"
  for _wait in $(seq 1 200); do
    [ -e "${ROLLING_LAUNCH_OLD_READY}" ] && break
    sleep 0.01
  done
  dlc_open "${ROLLING_LAUNCH_JOB}"
  : >"${ROLLING_LAUNCH_ACQUIRED}"
  dlc_close
' _ "${SKILL_DIR}/scripts/_driven_launch_coordinator.sh" &
ROLLING_LAUNCH_NEW_PID=$!
for _wait in $(seq 1 300); do
  [ -e "${ROLLING_LAUNCH_OLD_READY}" ] && break
  sleep 0.01
done
[ -e "${ROLLING_LAUNCH_OLD_READY}" ] \
  || fail "rolling launch old lock was not established"
sleep 0.2
if [ -e "${ROLLING_LAUNCH_ACQUIRED}" ]; then
  : >"${ROLLING_LAUNCH_RELEASE}"
  wait "${ROLLING_LAUNCH_OLD_PID}" || true
  wait "${ROLLING_LAUNCH_NEW_PID}" || true
  fail "new launch coordinator bypassed a late old-path rolling-upgrade lock"
fi
: >"${ROLLING_LAUNCH_RELEASE}"
wait "${ROLLING_LAUNCH_OLD_PID}"
wait "${ROLLING_LAUNCH_NEW_PID}"
[ -e "${ROLLING_LAUNCH_ACQUIRED}" ] \
  || fail "rolling launch coordinator did not resume after old lock release"

# Window-close migration itself can be sourced concurrently by multiple new
# processes. Both may snapshot the same old lock before either moves it; a
# dedicated layout lock must serialize the entire glob/open/move pass.
MIGRATOR_ROOT="${TEST_ROOT}/scheduler-launch-lock-concurrent-migration"
MIGRATOR_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
mkdir -p "${MIGRATOR_ROOT}/launch_actions"
exec 9>"${MIGRATOR_ROOT}/launch_actions/.${MIGRATOR_DIGEST}.lock"
flock -x 9
EXECUTOR_SCHEDULER_ROOT="${MIGRATOR_ROOT}" LEGACY_LOCK_COMPAT_ACTIVE=false \
  bash -c 'source "$1"' _ "${SKILL_DIR}/scripts/_driven_launch_coordinator.sh" &
MIGRATOR_PID_A=$!
EXECUTOR_SCHEDULER_ROOT="${MIGRATOR_ROOT}" LEGACY_LOCK_COMPAT_ACTIVE=false \
  bash -c 'source "$1"' _ "${SKILL_DIR}/scripts/_driven_launch_coordinator.sh" &
MIGRATOR_PID_B=$!
sleep 0.2
flock -u 9
exec 9>&-
set +e
wait "${MIGRATOR_PID_A}"
MIGRATOR_RC_A=$?
wait "${MIGRATOR_PID_B}"
MIGRATOR_RC_B=$?
set -e
[ "${MIGRATOR_RC_A}" -eq 0 ] && [ "${MIGRATOR_RC_B}" -eq 0 ] \
  || fail "concurrent launch lock-layout migrators raced the same old inode"
if find "${MIGRATOR_ROOT}/launch_actions" -maxdepth 1 -type f -name '*.lock' \
    -print -quit | grep -q .; then
  fail "concurrent launch migration left the old lock in hot storage"
fi

# Stable launch-action locks belong in their own directly addressable 0700
# directory; years of completed job locks must not enlarge the hot action scan.
LAUNCH_LOCK_ROOT="${TEST_ROOT}/scheduler-launch-lock-history"
mkdir -p "${LAUNCH_LOCK_ROOT}/launch_actions"
for launch_lock_index in $(seq 0 104); do
  : >"${LAUNCH_LOCK_ROOT}/launch_actions/.history-${launch_lock_index}.lock"
done
EXECUTOR_SCHEDULER_ROOT="${LAUNCH_LOCK_ROOT}" \
  bash -c 'source "$1"' _ "${SKILL_DIR}/scripts/_driven_launch_coordinator.sh"
if find "${LAUNCH_LOCK_ROOT}/launch_actions" -maxdepth 1 -type f -name '*.lock' \
    -print -quit | grep -q .; then
  fail "historical launch locks remained in the hot action directory"
fi
[ "$(find "${LAUNCH_LOCK_ROOT}/launch_action_locks" -maxdepth 1 -type f -name '*.lock' | wc -l | tr -d ' ')" -ge 105 ] \
  || fail "historical launch locks were not migrated to the independent lock directory"
[ "$(find "${LAUNCH_LOCK_ROOT}/launch_actions" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')" = 0 ] \
  || fail "launch lock migration polluted the hot JSON scan"

echo "ok launch coordinator recovers ack, project, and scheduler crash windows"
