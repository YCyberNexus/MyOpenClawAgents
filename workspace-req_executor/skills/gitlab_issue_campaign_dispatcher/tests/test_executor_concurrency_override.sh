#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOPUP_SCRIPT="${SKILL_DIR}/scripts/dispatch_driven_topup.sh"
CREATE_SCRIPT="${SKILL_DIR}/scripts/create_driven_batch.sh"
TICK_SCRIPT="${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
RECORD_SCRIPT="${SKILL_DIR}/scripts/record_executor_batch_spawn.sh"
IMPORT_SCRIPT="${SKILL_DIR}/scripts/import_driven_handoff.sh"
DRAIN_SCRIPT="${SKILL_DIR}/scripts/drain_driven_outbox.sh"

fail() {
  echo "test_executor_concurrency_override.sh: $*" >&2
  exit 1
}

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-concurrency.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
CAPTURE="${TEST_ROOT}/trigger.txt"
PREPARE="${TEST_ROOT}/prepare.sh"
mkdir -p "${CONFIG_DIR}" "${TEST_ROOT}/repos"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=fixture-token
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/pinned-repos
EXECUTOR_SCHEDULER_ROOT=${TEST_ROOT}/pinned-topup-scheduler
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_RUNNING_LEASE_SECONDS=111
EOF
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/local-repos
EXECUTOR_SCHEDULER_ROOT=${TEST_ROOT}/local-topup-scheduler
EXECUTOR_MAX_CONCURRENCY=4
EXECUTOR_RUNNING_LEASE_SECONDS=222
EOF
cat >"${PREPARE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE:?}"
[ "${REPO_PARENT_PATH}" = "${EXPECTED_REPO_PARENT}" ]
[ "${EXECUTOR_SCHEDULER_ROOT}" = "${EXPECTED_SCHEDULER_ROOT}" ]
[ "${EXECUTOR_MAX_CONCURRENCY}" = "${EXPECTED_MAX_CONCURRENCY}" ]
[ "${EXECUTOR_RUNNING_LEASE_SECONDS}" = "${EXPECTED_RUNNING_LEASE}" ]
[ "${GITLAB_HOST}" = "${EXPECTED_GITLAB_HOST}" ]
[ "${GITLAB_API_PROTOCOL}" = "${EXPECTED_GITLAB_API_PROTOCOL}" ]
cat >"${CAPTURE}"
jq -cn '{status:"no_eligible_iids",dispatch_entries:[],skipped_entries:[]}'
EOF
chmod +x "${PREPARE}"

request='{"owner_id":"executor-agent-scheduler-v1","grants":[{"job_id":"A:snapshot-0","batch_id":"A","snapshot_index":0,"project":"group/repo","iid":42,"branch":null,"entry_mode":"auto","force_rerun_pr":false}]}'
printf '%s' "${request}" | \
  CONFIG_DIR="${CONFIG_DIR}" \
  REPO_PARENT_PATH="${TEST_ROOT}/repos" \
  EXECUTOR_SCHEDULER_ROOT="${TEST_ROOT}/process-topup-scheduler" \
  EXECUTOR_MAX_CONCURRENCY=5 \
  EXECUTOR_RUNNING_LEASE_SECONDS=333 \
  GITLAB_HOST=gitlab.process.test \
  GITLAB_API_PROTOCOL=http \
  EXPECTED_REPO_PARENT="${TEST_ROOT}/repos/group" \
  EXPECTED_SCHEDULER_ROOT="${TEST_ROOT}/process-topup-scheduler" \
  EXPECTED_MAX_CONCURRENCY=5 \
  EXPECTED_RUNNING_LEASE=333 \
  EXPECTED_GITLAB_HOST=gitlab.process.test \
  EXPECTED_GITLAB_API_PROTOCOL=http \
  PREPARE_TICK_CMD="${PREPARE}" \
  CAPTURE="${CAPTURE}" \
  bash "${TOPUP_SCRIPT}" >/dev/null

grep -qx 'hourly_issue_quota=5' "${CAPTURE}" \
  || fail "deployment override 5 did not reach hourly_issue_quota"
grep -qx 'max_concurrent_subagents=5' "${CAPTURE}" \
  || fail "deployment override 5 did not reach project topup capacity"
grep -qx "repo_path=${TEST_ROOT}/repos/group" "${CAPTURE}" \
  || fail "process repo parent override did not reach project topup"

echo "ok executor concurrency override is unified across scheduler and topup"

# Intake, tick, and post-spawn recording must all honor the same process-level
# scheduler root/concurrency overrides even when campaign_defaults.env pins a
# different root and value. Otherwise one request can split durable state
# across two scheduler roots.
PINNED_ROOT="${TEST_ROOT}/pinned-scheduler"
OVERRIDE_ROOT="${TEST_ROOT}/override-scheduler"
OVERRIDE_REPO_PARENT="${TEST_ROOT}/override-repos"
FAKE_BIN="${TEST_ROOT}/override-bin"
OVERRIDE_LOG="${TEST_ROOT}/override.log"
mkdir -p "${FAKE_BIN}" "${TEST_ROOT}/repos/group/repo/.git" \
  "${OVERRIDE_REPO_PARENT}/group/repo/.git"
: >"${OVERRIDE_LOG}"
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${PINNED_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_RUNNING_LEASE_SECONDS=456
EXECUTOR_AGENT=pinned_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:pinned
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=86400
EOF
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/local-repos
EXECUTOR_SCHEDULER_ROOT=${TEST_ROOT}/local-scheduler
EXECUTOR_MAX_CONCURRENCY=4
EXECUTOR_RUNNING_LEASE_SECONDS=123
EXECUTOR_AGENT=local_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:local
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=3600
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth) exit 0 ;;
  api)
    [ "${GITLAB_HOST:-}" = "gitlab.tick.process.test" ] \
      && [ "${GITLAB_API_PROTOCOL:-}" = "http" ] \
      || exit 90
    [ "${2:-}" = graphql ] || exit 91
    jq -cn '{data:{project:{issues:{
      nodes:[{iid:"42",state:"opened",labels:{
        nodes:[],pageInfo:{hasNextPage:false}
      }}],
      pageInfo:{hasNextPage:false,endCursor:null}
    }}}}'
    ;;
  *) exit 92 ;;
esac
EOF
cat >"${FAKE_BIN}/resolve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${TEST_ROOT}/repos/group/repo"
EOF
cat >"${FAKE_BIN}/drain_intents.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn '{status:"drained",intent_count:0,results:[]}'
EOF
cat >"${FAKE_BIN}/drain_outbox.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --argjson failed "${FAKE_OUTBOX_FAILED:-0}" '{
  status:"drained",scanned:$failed,attempted:3,delivered:0,failed:$failed
}'
EOF
cat >"${FAKE_BIN}/reserve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${EXECUTOR_SCHEDULER_ROOT}" = "${OVERRIDE_ROOT}" ] \
  && [ "${EXECUTOR_MAX_CONCURRENCY}" = 5 ] \
  && [ "${SCHEDULER_STATE_FILE}" = "${OVERRIDE_ROOT}/scheduler_state.json" ] \
  && [ "${REPO_PARENT_PATH}" = "${OVERRIDE_REPO_PARENT}" ] \
  && [ "${EXECUTOR_RUNNING_LEASE_SECONDS}" = 9876 ] \
  && [ "${EXECUTOR_AGENT}" = "custom_executor" ] \
  && [ "${DISPATCHER_CALLBACK_TARGET}" = "agent:req_dispatcher:custom-session" ] \
  && [ "${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS}" = 172800 ] \
  && [ "${GITLAB_HOST}" = "gitlab.tick.process.test" ] \
  && [ "${GITLAB_API_PROTOCOL}" = "http" ] \
  || { printf 'split:%s:%s:%s\n' "${EXECUTOR_SCHEDULER_ROOT}" \
    "${EXECUTOR_MAX_CONCURRENCY}" "${SCHEDULER_STATE_FILE}" >>"${OVERRIDE_LOG}"; exit 93; }
printf '%s\n' tick-root-ok >>"${OVERRIDE_LOG}"
jq -cn '{status:"idle",grants:[],active_count:0,available_slots:5}'
EOF
cat >"${FAKE_BIN}/unused.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 94
EOF
cat >"${FAKE_BIN}/project_record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${EXECUTOR_SCHEDULER_ROOT}" = "${OVERRIDE_ROOT}" ] \
  && [ "${EXECUTOR_MAX_CONCURRENCY}" = 5 ] \
  && [ "${EXECUTOR_RUNNING_LEASE_SECONDS}" = 9876 ] \
  && [ "${GITLAB_HOST}" = "gitlab.record.process.test" ] \
  && [ "${GITLAB_API_PROTOCOL}" = "http" ] \
  && [ "${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS}" = 172800 ] \
  || exit 95
printf '%s\n' project-root-ok >>"${OVERRIDE_LOG}"
jq -cn --argjson iid "${IID}" --argjson attempt "${ATTEMPT_NUMBER}" '{
  status:"spawned",iid:$iid,attempt_number:$attempt,
  remaining_pending_count:1,chat_summary:"recorded"
}'
EOF
cat >"${FAKE_BIN}/scheduler_record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${EXECUTOR_SCHEDULER_ROOT}" = "${OVERRIDE_ROOT}" ] \
  && [ "${EXECUTOR_MAX_CONCURRENCY}" = 5 ] \
  && [ "${SCHEDULER_STATE_FILE}" = "${OVERRIDE_ROOT}/scheduler_state.json" ] \
  && [ "${EXECUTOR_RUNNING_LEASE_SECONDS}" = 9876 ] \
  && [ "${GITLAB_HOST}" = "gitlab.record.process.test" ] \
  && [ "${GITLAB_API_PROTOCOL}" = "http" ] \
  && [ "${DRIVEN_LEGACY_LOCK_COMPAT_SECONDS}" = 172800 ] \
  || exit 96
printf '%s\n' scheduler-root-ok >>"${OVERRIDE_LOG}"
jq -cn --arg job_id "${JOB_ID}" '{
  status:"recorded",job_id:$job_id,job_status:"running",active_count:1,
  should_spawn:false,claim_generation:null,claim_token:null
}'
EOF
chmod +x "${FAKE_BIN}"/*

  EXECUTOR_SCHEDULER_ROOT="${OVERRIDE_ROOT}" EXECUTOR_MAX_CONCURRENCY=5 \
  EXECUTOR_AGENT=custom_executor \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:custom-session \
  GITLAB_HOST=gitlab.tick.process.test \
  GITLAB_API_PROTOCOL=http \
  CONFIG_DIR="${CONFIG_DIR}" GLAB_BIN="${FAKE_BIN}/glab" \
  GITLAB_TOKEN=override-token bash "${CREATE_SCRIPT}" >/dev/null <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=override-batch
correlation_id=override-correlation
project=group/repo
selector_type=single
iid=42
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:custom-session
executor_agent=custom_executor
callback_nonce=5555555555555555555555555555555555555555555555555555555555555555
EOF
[ -f "${OVERRIDE_ROOT}/batches/override-batch/request.json" ] \
  || fail "intake did not use the process scheduler root override"
[ ! -e "${PINNED_ROOT}/batches/override-batch" ] \
  || fail "intake duplicated the batch into the pinned scheduler root"

tick_output="$(EXECUTOR_SCHEDULER_ROOT="${OVERRIDE_ROOT}" \
  EXECUTOR_MAX_CONCURRENCY=5 CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_RUNNING_LEASE_SECONDS=9876 \
  REPO_PARENT_PATH="${OVERRIDE_REPO_PARENT}" \
  EXECUTOR_AGENT=custom_executor \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:custom-session \
  GITLAB_HOST=gitlab.tick.process.test \
  GITLAB_API_PROTOCOL=http \
  FAKE_OUTBOX_FAILED=105 \
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=172800 \
  TEST_ROOT="${TEST_ROOT}" OVERRIDE_ROOT="${OVERRIDE_ROOT}" \
  OVERRIDE_REPO_PARENT="${OVERRIDE_REPO_PARENT}" \
  OVERRIDE_LOG="${OVERRIDE_LOG}" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_outbox.sh" \
  RESERVE_CMD="${FAKE_BIN}/reserve.sh" \
  TOPUP_CMD="${FAKE_BIN}/unused.sh" IMPORT_SKIP_CMD="${FAKE_BIN}/unused.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/unused.sh" BIND_CLAIM_CMD="${FAKE_BIN}/unused.sh" \
  bash "${TICK_SCRIPT}")" || fail "tick rejected the process scheduler override"
jq -e '.status == "idle" and .spawn_grants == []' <<<"${tick_output}" >/dev/null \
  || fail "override tick returned an invalid envelope"
jq -e '
  ([.operation_results[] | select(.operation == "outbox_drain" and .failed == 105)] | length) == 1
  and ([.operation_results[] | select(.operation == "reservation" and .status == "idle")] | length) == 1
' <<<"${tick_output}" >/dev/null \
  || fail "100+ failed callbacks prevented the same tick from reaching reservation"

# Record sources scheduler_env.sh after its own config load. Add a local
# GitLab endpoint only after the tick so the record boundary must preserve the
# stronger process override across both config-loading layers.
cat >>"${CONFIG_DIR}/campaign_defaults.local.env" <<'EOF'
GITLAB_HOST=gitlab.record.local.test
GITLAB_API_PROTOCOL=https
EOF

job_id='override-batch:snapshot-0'
job_digest="$(printf '%s' "${job_id}" | shasum -a 256 | awk '{print $1}')"
mkdir -p "${OVERRIDE_ROOT}/launch_actions"
jq -cnS --arg job_id "${job_id}" '{
  version:1,job_id:$job_id,project:"group/repo",iid:42,
  batch_id:"override-batch",snapshot_index:0,attempt_number:1,
  child_label:"reqx-iid42-gen1-0123456789abcdef0123456789abcdef01234567",
  runtime_label_version:1,payload_path:"/private/payload",
  claim_generation:1,claim_token:"private-override-claim",
  stage:"action_emitted",outcome:null,ack:null,created_at:1,updated_at:1
}' >"${OVERRIDE_ROOT}/launch_actions/${job_digest}.json"
chmod 600 "${OVERRIDE_ROOT}/launch_actions/${job_digest}.json"
jq -cn --arg job_id "${job_id}" '{
  version:1,round_robin_cursor:null,batch_order:["override-batch"],
  active_jobs:{($job_id):{
    job_id:$job_id,project:"group/repo",iid:42,status:"preparing",
    claim_generation:1,claim_token:"private-override-claim"
  }}
}' >"${OVERRIDE_ROOT}/scheduler_state.json"

record_output="$(jq -cn --arg job_id "${job_id}" '{
  job_id:$job_id,claim_generation:1,project:"group/repo",iid:42,
  attempt_number:1,status:"spawned",run_id:"override-run",
  child_session_key:"agent:req_executor:subagent:override"
}' | EXECUTOR_SCHEDULER_ROOT="${OVERRIDE_ROOT}" EXECUTOR_MAX_CONCURRENCY=5 \
  EXECUTOR_RUNNING_LEASE_SECONDS=9876 \
  GITLAB_HOST=gitlab.record.process.test \
  GITLAB_API_PROTOCOL=http \
  EXECUTOR_AGENT=custom_executor \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:custom-session \
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=172800 \
  CONFIG_DIR="${CONFIG_DIR}" TEST_ROOT="${TEST_ROOT}" \
  OVERRIDE_ROOT="${OVERRIDE_ROOT}" OVERRIDE_LOG="${OVERRIDE_LOG}" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
  PROJECT_RECORD_CMD="${FAKE_BIN}/project_record.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/scheduler_record.sh" \
  bash "${RECORD_SCRIPT}")" || fail "post-spawn record split from the override root"
jq -e '.status == "spawned_recorded"' <<<"${record_output}" >/dev/null \
  || fail "override post-spawn record returned an invalid envelope"
[ "$(cat "${OVERRIDE_LOG}")" = $'tick-root-ok\nproject-root-ok\nscheduler-root-ok' ] \
  || fail "intake/tick/record did not share one override root: $(cat "${OVERRIDE_LOG}")"

# The same custom route must survive the real import and delivery wrappers,
# not only intake/tick. campaign_defaults.env intentionally pins different
# values above, so any lost process override makes this handoff fail closed.
AUTH_ROOT="${TEST_ROOT}/auth-override-scheduler"
AUTH_BATCH='auth-override-batch'
AUTH_JOB="${AUTH_BATCH}:snapshot-0"
AUTH_EVENT="${AUTH_BATCH}:snapshot-0:terminal-1"
AUTH_PHYSICAL_EVENT="${AUTH_JOB}:claim-1:terminal-1"
AUTH_NONCE='6666666666666666666666666666666666666666666666666666666666666666'
mkdir -p "${AUTH_ROOT}/batches/${AUTH_BATCH}"
CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_SCHEDULER_ROOT="${AUTH_ROOT}" \
  EXECUTOR_AGENT=custom_executor \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:custom-session \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
jq -cnS --arg batch_id "${AUTH_BATCH}" --arg nonce "${AUTH_NONCE}" '{
  version:1,batch_id:$batch_id,correlation_id:"auth-override-correlation",
  project:"group/repo",selector:{type:"single",iid:42},force_rerun_pr:false,
  dispatcher_callback_target:"agent:req_dispatcher:custom-session",
  executor_agent:"custom_executor",callback_nonce:$nonce,branch:"main"
}' >"${AUTH_ROOT}/batches/${AUTH_BATCH}/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
  >"${AUTH_ROOT}/batches/${AUTH_BATCH}/snapshot.json"
jq -cnS --arg batch_id "${AUTH_BATCH}" --arg job_id "${AUTH_JOB}" '{
  version:1,batch_id:$batch_id,status:"running",matched_count:1,
  terminal_count:0,done_count:0,failed_count:0,timeout_count:0,skipped_count:0,
  next_snapshot_index:1,request_digest:"fixture",snapshot_digest:"fixture",
  memberships:{"0":{snapshot_index:0,iid:42,status:"running",job_id:$job_id}}
}' >"${AUTH_ROOT}/batches/${AUTH_BATCH}/state.json"
jq -cnS --arg batch_id "${AUTH_BATCH}" --arg job_id "${AUTH_JOB}" '{
  version:1,round_robin_cursor:$batch_id,batch_order:[$batch_id],
  active_jobs:{($job_id):{
    job_id:$job_id,physical_key:"group/repo#42",project:"group/repo",iid:42,
    branch:"main",entry_mode:"auto",force_rerun_pr:false,status:"running",
    reservation_seq:1,claim_generation:1,claim_token:"auth-override-claim",
    reserved_at:1,updated_at:2,owner:{batch_id:$batch_id,snapshot_index:0},
    memberships:[{batch_id:$batch_id,snapshot_index:0}]
  }}
}' >"${AUTH_ROOT}/scheduler_state.json"
AUTH_HANDOFF="${TEST_ROOT}/auth-override-handoff.json"
jq -cnS --arg event_id "${AUTH_PHYSICAL_EVENT}" --arg job_id "${AUTH_JOB}" '{
  version:1,event_id:$event_id,job_id:$job_id,memberships:[],
  memberships_source:"scheduler_active_job",claim_generation:1,
  claim_token:"auth-override-claim",project:"group/repo",iid:42,
  status:"done",mr_url:null,reason:null
}' >"${AUTH_HANDOFF}"
auth_import="$(CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_SCHEDULER_ROOT="${AUTH_ROOT}" \
  EXECUTOR_AGENT=custom_executor \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:custom-session \
  HANDOFF_FILE="${AUTH_HANDOFF}" NOW_EPOCH=10 bash "${IMPORT_SCRIPT}")" \
  || fail "custom auth route did not reach the real handoff importer"
jq -e '.status == "imported" and .terminal_recorded == true' \
  <<<"${auth_import}" >/dev/null \
  || fail "custom auth importer returned an invalid result"
jq -e --arg nonce "${AUTH_NONCE}" '
  .callback_auth_mode == "nonce_v1"
  and .executor_agent == "custom_executor"
  and .target == "agent:req_dispatcher:custom-session"
  and .callback_nonce == $nonce
' "${AUTH_ROOT}/callback_outbox/${AUTH_EVENT}.json" >/dev/null \
  || fail "custom auth route was not frozen into the imported outbox"

AUTH_OPENCLAW="${TEST_ROOT}/auth-override-openclaw.sh"
cat >"${AUTH_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
agent=""
target=""
message=""
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) shift; agent="${1:-}" ;;
    --session-key) shift; target="${1:-}" ;;
    --message) shift; message="${1:-}" ;;
    --message-file) shift; message_file="${1:-}" ;;
  esac
  [ "$#" -gt 0 ] && shift
done
[ -z "${message_file}" ] || [ "${message_file}" = /dev/stdin ]
[ -z "${message_file}" ] || message="$(cat)"
[ "${agent}" = req_dispatcher ]
[ "${target}" = agent:req_dispatcher:custom-session ]
envelope="${message#*callback_envelope=}"
jq -e --arg nonce "${AUTH_NONCE:?}" '
  .executor_agent == "custom_executor"
  and .callback_nonce == $nonce
' <<<"${envelope}" >/dev/null
jq -nc --arg event_id "$(jq -r '.worker_result_json.event_id' <<<"${envelope}")" \
  '{status:"accepted",event_id:$event_id}'
EOF
chmod +x "${AUTH_OPENCLAW}"
auth_drain="$(CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_SCHEDULER_ROOT="${AUTH_ROOT}" \
  EXECUTOR_AGENT=custom_executor \
  DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:custom-session \
  OPENCLAW_BIN="${AUTH_OPENCLAW}" AUTH_NONCE="${AUTH_NONCE}" \
  NOW_EPOCH=2000000000 bash "${DRAIN_SCRIPT}")"
jq -e '.attempted == 1 and .delivered == 1 and .failed == 0' \
  <<<"${auth_drain}" >/dev/null \
  || fail "custom auth route did not reach callback delivery"
[ -f "${AUTH_ROOT}/callback_archive/${AUTH_EVENT}.json" ] \
  || fail "custom auth callback was not archived after delivery"

echo "ok intake, tick, topup, and record share process scheduler overrides"
