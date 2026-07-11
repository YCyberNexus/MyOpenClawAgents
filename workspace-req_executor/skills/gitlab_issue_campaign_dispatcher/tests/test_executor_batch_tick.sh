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

[ -x "${TICK_SCRIPT}" ] || fail "run_executor_batch_tick.sh is missing or not executable"
[ -x "${RECORD_RESULT_SCRIPT}" ] || fail "record_executor_batch_spawn.sh is missing or not executable"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-batch-tick.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_BIN="${TEST_ROOT}/fake-bin"
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

write_fake scheduler_env.sh '
printf "%s\n" scheduler_env >>"${ORDER_LOG}"
export EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}"
export EXECUTOR_MAX_CONCURRENCY=3
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

write_fake reserve_driven_batch_items.sh '
count=0
[ ! -s "${RESERVE_COUNT_FILE}" ] || count="$(cat "${RESERVE_COUNT_FILE}")"
count=$((count + 1))
printf "%s" "${count}" >"${RESERVE_COUNT_FILE}"
printf "reserve:%s\n" "${count}" >>"${ORDER_LOG}"
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
printf "topup:%s\n" "${jobs}" >>"${ORDER_LOG}"
case "${jobs}" in
  A:snapshot-0,A:snapshot-1)
    jq -cn "{
      status:\"ready\",
      dispatch_entries:[{
        iid:42,attempt_number:1,child_label:\"#42-att-001\",
        payload_path:\"${TEST_ROOT}/payload-42.txt\",
        job_id:\"A:snapshot-0\",batch_id:\"A\",snapshot_index:0,
        memberships_source:\"scheduler_active_job\"
      }],
      skipped_entries:[{
        job_id:\"A:snapshot-1\",batch_id:\"A\",snapshot_index:1,
        project:\"group/repo\",iid:43,status:\"skipped\",reason:\"closed\"
      }]
    }"
    ;;
  A:snapshot-2)
    jq -cn "{
      status:\"ready\",
      dispatch_entries:[{
        iid:44,attempt_number:1,child_label:\"#44-att-001\",
        payload_path:\"${TEST_ROOT}/payload-44.txt\",
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
printf "skip:%s\n" "$(jq -r .job_id <<<"${entry}")" >>"${ORDER_LOG}"
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
if [ "${STATUS}" = spawned ]; then
  jq -cn --argjson iid "${IID}" --argjson attempt "${ATTEMPT_NUMBER}" \
    "{status:\"spawned\",iid:\$iid,attempt_number:\$attempt,remaining_pending_count:1,chat_summary:\"recorded\"}"
else
  jq -cn --argjson iid "${IID}" --argjson attempt "${ATTEMPT_NUMBER}" \
    "{status:\"launch_failed_recorded\",iid:\$iid,attempt_number:\$attempt,final_status:\"blocked\",cleanup:{action:\"skip\",target:\"\",reason:\"no_child_session_key\"},remaining_pending_count:0,chat_summary:\"recorded\"}"
fi
'

write_fake sessions_spawn '
: >"${SPAWN_SENTINEL}"
exit 99
'

printf '%s' 'payload contains a private runtime credential' >"${TEST_ROOT}/payload-42.txt"
printf '%s' 'second payload contains another private runtime credential' >"${TEST_ROOT}/payload-44.txt"

run_tick() {
  : >"${ORDER_LOG}"
  : >"${RESERVE_COUNT_FILE}"
  CONFIG_DIR="${CONFIG_DIR}" \
  ORDER_LOG="${ORDER_LOG}" \
  TEST_ROOT="${TEST_ROOT}" \
  SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
  RESERVE_COUNT_FILE="${RESERVE_COUNT_FILE}" \
  PATH="${FAKE_BIN}:${PATH}" \
  SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve_driven_repo_path.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_driven_handoff_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_driven_outbox.sh" \
  RESERVE_CMD="${FAKE_BIN}/reserve_driven_batch_items.sh" \
  TOPUP_CMD="${FAKE_BIN}/dispatch_driven_topup.sh" \
  IMPORT_SKIP_CMD="${FAKE_BIN}/import_driven_skipped.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/record_driven_batch_launch.sh" \
  BIND_CLAIM_CMD="${FAKE_BIN}/bind_driven_claim.sh" \
    bash "${TICK_SCRIPT}"
}

archive_launch_actions() {
  local label="$1"
  if [ -d "${SCHEDULER_ROOT}/launch_actions" ]; then
    mv "${SCHEDULER_ROOT}/launch_actions" \
      "${SCHEDULER_ROOT}/launch_actions-${label}"
  fi
}

tick_output="$(run_tick)" || fail "fixed executor batch tick failed"

expected_order='scheduler_env
intent:group/repo
outbox
reserve:1
topup:A:snapshot-0,A:snapshot-1
skip:A:snapshot-1
reserve:2
topup:A:snapshot-2
record:preparing:A:snapshot-0
bind:A:snapshot-0:1:private-claim-token
record:preparing:A:snapshot-2
bind:A:snapshot-2:1:private-claim-token-44'
[ "$(cat "${ORDER_LOG}")" = "${expected_order}" ] \
  || fail "tick order violated recovery/outbox/reserve/topup/claim contract: $(cat "${ORDER_LOG}")"
[ ! -e "${SPAWN_SENTINEL}" ] || fail "shell tick wrapper called sessions_spawn"

jq -e '
  (keys | sort) == [
    "backoff_seconds","chat_summary","max_launch_retries","operation_results",
    "reconcile_actions","spawn_grants","status"
  ]
  and .status == "ready"
  and .max_launch_retries == 3
  and .backoff_seconds == 2
  and .reconcile_actions == []
  and (.spawn_grants | length) == 2
  and (.spawn_grants[0] | del(.child_label)) == {
    job_id:"A:snapshot-0",claim_generation:1,project:"group/repo",iid:42,
    attempt_number:1,
    payload_path:"'"${TEST_ROOT}"'/payload-42.txt"
  }
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen1-[0-9a-f]{40}$"))
  and (.spawn_grants[1] | del(.child_label)) == {
    job_id:"A:snapshot-2",claim_generation:1,project:"group/repo",iid:44,
    attempt_number:1,
    payload_path:"'"${TEST_ROOT}"'/payload-44.txt"
  }
  and (.spawn_grants[1].child_label
    | test("^reqx-iid44-gen1-[0-9a-f]{40}$"))
  and ([.operation_results[] | select(.operation == "synthetic_skip" and .job_id == "A:snapshot-1" and .status == "imported")] | length) == 1
  and ([.operation_results[] | select(.operation == "preparing" and .job_id == "A:snapshot-0" and .status == "ready")] | length) == 1
  and (tostring | contains("private-claim-token") | not)
  and (tostring | contains("payload contains") | not)
' <<<"${tick_output}" >/dev/null \
  || fail "tick did not return the strict token-free spawn grant envelope: ${tick_output}"
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
    iid:42,attempt_number:2,child_label:"#42-att-002",
    payload_path:"${TEST_ROOT}/payload-42.txt",
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
  and .spawn_grants[0].attempt_number == 2
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen2-[0-9a-f]{40}$"))
  and (tostring | contains("continuation-private-claim") | not)
' <<<"${continuation_output}" >/dev/null \
  || fail "running job was not continued without a fresh reservation: ${continuation_output}"
grep -q '^topup:A:snapshot-0$' "${ORDER_LOG}" \
  || fail "running job was not sent back through the project campaign"
archive_launch_actions continuation

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
    attempt_number:2,status:"spawned",run_id:"run-42",
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
      iid,attempt_number:1,
      child_label:("#" + (.iid|tostring) + "-att-001"),
      payload_path:(\$root + "/payload-" + (.iid|tostring) + ".txt"),
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
  [.spawn_grants[].job_id] == ["A:snapshot-0","B:snapshot-0","A:snapshot-2"]
  and (.spawn_grants | all(.claim_generation == 1))
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen1-[0-9a-f]{40}$"))
  and (.spawn_grants[1].child_label
    | test("^reqx-iid42-gen1-[0-9a-f]{40}$"))
  and .spawn_grants[0].child_label != .spawn_grants[1].child_label
  and ([.spawn_grants[].child_label] | length)
    == ([.spawn_grants[].child_label] | unique | length)
  and (tostring | contains("private-") | not)
' <<<"${order_output}" >/dev/null \
  || fail "project grouping reordered grants or reused a cross-project runtime label: ${order_output}"
actual_record_order="$(grep '^record-order:' "${ORDER_LOG}" | sed 's/^record-order://')"
expected_record_order=$'A:snapshot-0\nB:snapshot-0\nA:snapshot-2'
[ "${actual_record_order}" = "${expected_record_order}" ] \
  || fail "preparing/bind did not preserve A1,B10,A2 order: ${actual_record_order}"

echo "ok executor batch tick is recovery-first and returns strict spawn grants"
