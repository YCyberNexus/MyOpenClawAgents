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
sha42="$(printf "%064d" 42)"
sha44="$(printf "%064d" 44)"
printf "topup:%s\n" "${jobs}" >>"${ORDER_LOG}"
case "${jobs}" in
  A:snapshot-0,A:snapshot-1)
    jq -cn "{
      status:\"ready\",
      dispatch_entries:[{
        iid:42,attempt_number:1,child_label:\"#42-att-001\",
        payload_path:\"${TEST_ROOT}/payload-42.txt\",
        expected_task_sha256:\"${sha42}\",expected_task_bytes:42,
        job_id:\"A:snapshot-0\",batch_id:\"A\",snapshot_index:0,
        memberships_source:\"scheduler_active_job\"
      }],
      pending_iids:[],
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
[[ "${EXPECTED_TASK_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || exit 95
[[ "${EXPECTED_TASK_BYTES:-}" =~ ^[1-9][0-9]*$ ]] || exit 95
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

write_fake expire_running.sh '
if [ "${DRIVEN_RESULT_RECONCILE:-0}" = 1 ]; then
  worker_result="$(cat)"
  printf "result:%s:%s:%s\n" \
    "${DRIVEN_RECONCILE_JOB_ID}" "${DRIVEN_RECONCILE_CLAIM_GENERATION}" \
    "${DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256}" >>"${ORDER_LOG}"
  jq -e --argjson iid "${IID}" \
    ".iid == \$iid and .status == \"done\"" <<<"${worker_result}" >/dev/null
  if [ "${RESULT_TEST_RELEASE:-0}" = 1 ]; then
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
if [ "${DRIVEN_COMPLETED_RECONCILE:-0}" = 1 ]; then
  printf "completed:%s:%s:%s\n" \
    "${DRIVEN_RECONCILE_JOB_ID}" "${DRIVEN_RECONCILE_CLAIM_GENERATION}" \
    "${DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256}" >>"${ORDER_LOG}"
  if [ "${COMPLETION_TEST_RELEASE:-0}" = 1 ]; then
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
  PATH="${FAKE_BIN}:${PATH}" \
  SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve_driven_repo_path.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_driven_handoff_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_driven_outbox.sh" \
  RECONCILE_COUNTS_CMD="${FAKE_BIN}/reconcile_driven_terminal_counts.sh" \
  REAP_PLACEHOLDERS_CMD="${FAKE_BIN}/reap_driven_orphan_placeholders.sh" \
  EXPIRE_RUNNING_CMD="${FAKE_BIN}/expire_running.sh" \
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
reconcile
intent:group/repo
outbox
reap:
reserve:1
topup:A:snapshot-0,A:snapshot-1
skip:A:snapshot-1
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
    attempt_number:1,
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
    iid:42,attempt_number:2,child_label:"#42-att-002",
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
  and .spawn_grants[0].attempt_number == 2
  and (.spawn_grants[0].child_label
    | test("^reqx-iid42-gen2-[0-9a-f]{40}$"))
  and (tostring | contains("continuation-private-claim") | not)
' <<<"${continuation_output}" >/dev/null \
  || fail "running job was not continued without a fresh reservation: ${continuation_output}"
grep -q '^topup:A:snapshot-0$' "${ORDER_LOG}" \
  || fail "running job was not sent back through the project campaign"
archive_launch_actions continuation

# A live preflight may report that a continuation now looks closed/pr-labeled.
# While the exact project pending entry still exists, the tick must re-check
# the current claim and GitLab completion through dispatch_followup, then write
# a claim-bound skipped handoff immediately instead of waiting for the running
# timeout lease.
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
grep -Eq '^completed:A:snapshot-0:2:[0-9a-f]{64}$' "${ORDER_LOG}" \
  || fail "running completion did not receive the exact hashed claim fence"
if grep -q 'continuation-private-claim' "${ORDER_LOG}" \
    || grep -q 'continuation-private-claim' <<<"${running_skip_output}"; then
  fail "running completion recovery exposed the private claim token"
fi
jq -e '
  .spawn_grants == []
  and ([.operation_results[]
    | select(.operation == "running_preflight_skip"
      and .job_id == "A:snapshot-0"
      and .status == "handoff_recorded"
      and .claim_generation == 2)]
    | length) == 1
  and ([.operation_results[]
    | select(.operation == "synthetic_skip" and .job_id == "A:snapshot-0")]
    | length) == 0
' <<<"${running_skip_output}" >/dev/null \
  || fail "running continuation did not produce an immediate claim-bound handoff"

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
grep -q '^skip:A:snapshot-0$' "${ORDER_LOG}" \
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
  batch_id:"A",snapshot_index:0,attempt_number:1,
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
    attempt_number:2,status:"spawned",run_id:"run-42",
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
      iid,attempt_number:1,
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
RESULT_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/attempt-003"
mkdir -p "${CAMPAIGN_DIR}" "${RESULT_LOG_DIR}"
cat >"${CAMPAIGN_DIR}/campaign_state.json" <<'EOF'
{"pending_subagents":{"42":{
  "job_id":"A:snapshot-0","claim_generation":3,"attempt_number":3,
  "run_id":"run-42-result","child_session_key":"agent:req_executor:subagent:42"
}}}
EOF
cat >"${RESULT_LOG_DIR}/worker_result.json" <<EOF
{"iid":42,"attempt_number":3,"status":"done","mode_actual":"fresh","work_branch":"issue/42","local_branch":"issue/42-att003","commit_sha":"0123456789abcdef","merge_request_url":"https://gitlab.example.test/group/repo/-/merge_requests/1","mr_action":"created","wiki_url":"","labels_added":["pr"],"labels_removed":["doing","done"],"summary_posted":true,"block_reason":"","log_dir":"${RESULT_LOG_DIR}"}
EOF
cat >"${RESULT_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"attempt_number":3,"exit_code":0,"completed_at_epoch":100}
EOF
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

# If the wrapper died after acpx_terminal.json but before worker_result.json,
# wait for a bounded grace period and then reclaim only the matching native
# child. The marker is exact-schema and attempt-scoped, so an in-flight acpx
# process cannot be mistaken for this post-acpx state.
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
  "job_id":"A:snapshot-0","claim_generation":4,"attempt_number":4,
  "run_id":"run-42-marker","child_session_key":"agent:req_executor:subagent:42"
}}}
EOF
MARKER_LOG_DIR="${PROJECT_RUNTIME}/.worktrees/issue-42/.req_executor/issue-42/log/attempt-004"
mkdir -p "${MARKER_LOG_DIR}"
cat >"${MARKER_LOG_DIR}/acpx_terminal.json" <<'EOF'
{"version":1,"iid":42,"attempt_number":4,"exit_code":0,"completed_at_epoch":100}
EOF
post_acpx_output="$(
  NOW_EPOCH=2000 EXECUTOR_POST_ACPX_GRACE_SECONDS=900 \
    SERIAL_GATE_RESERVE_SENTINEL=1 run_tick
)" || fail "post-acpx watchdog tick failed"
jq -e '
  .status == "cleanup_required"
  and .spawn_grants == []
  and .reconcile_actions == []
  and (.cleanup_actions | length) == 1
  and .cleanup_actions[0].action == "kill"
  and .cleanup_actions[0].target == "agent:req_executor:subagent:42"
  and .cleanup_actions[0].reason == "post_acpx_finalization_grace_exceeded"
  and .cleanup_actions[0].attempt_number == 4
  and .cleanup_actions[0].claim_generation == 4
  and ([.operation_results[] | select(
    .operation == "post_acpx_watchdog"
    and .job_id == "A:snapshot-0" and .status == "kill_required")] | length) == 1
  and (tostring | contains("post-acpx-private-claim") | not)
' <<<"${post_acpx_output}" >/dev/null \
  || fail "post-acpx marker did not return one exact cleanup action"

echo "ok executor batch tick is recovery-first and returns strict spawn grants"
