#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOPUP_SCRIPT="${SKILL_DIR}/scripts/dispatch_driven_topup.sh"
CREATE_SCRIPT="${SKILL_DIR}/scripts/create_driven_batch.sh"
TICK_SCRIPT="${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
RECORD_SCRIPT="${SKILL_DIR}/scripts/record_executor_batch_spawn.sh"

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
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${TEST_ROOT}/scheduler
EXECUTOR_MAX_CONCURRENCY=3
EOF
cat >"${PREPARE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE:?}"
cat >"${CAPTURE}"
jq -cn '{status:"no_eligible_iids",dispatch_entries:[],skipped_entries:[]}'
EOF
chmod +x "${PREPARE}"

request='{"owner_id":"executor-agent-scheduler-v1","grants":[{"job_id":"A:snapshot-0","batch_id":"A","snapshot_index":0,"project":"group/repo","iid":42,"branch":null,"entry_mode":"auto","force_rerun_pr":false}]}'
printf '%s' "${request}" | \
  CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_MAX_CONCURRENCY=5 \
  PREPARE_TICK_CMD="${PREPARE}" \
  CAPTURE="${CAPTURE}" \
  bash "${TOPUP_SCRIPT}" >/dev/null

grep -qx 'hourly_issue_quota=5' "${CAPTURE}" \
  || fail "deployment override 5 did not reach hourly_issue_quota"
grep -qx 'max_concurrent_subagents=5' "${CAPTURE}" \
  || fail "deployment override 5 did not reach project topup capacity"

echo "ok executor concurrency override is unified across scheduler and topup"

# Intake, tick, and post-spawn recording must all honor the same process-level
# scheduler root/concurrency overrides even when campaign_defaults.env pins a
# different root and value. Otherwise one request can split durable state
# across two scheduler roots.
PINNED_ROOT="${TEST_ROOT}/pinned-scheduler"
OVERRIDE_ROOT="${TEST_ROOT}/override-scheduler"
FAKE_BIN="${TEST_ROOT}/override-bin"
OVERRIDE_LOG="${TEST_ROOT}/override.log"
mkdir -p "${FAKE_BIN}" "${TEST_ROOT}/repos/group/repo/.git"
: >"${OVERRIDE_LOG}"
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${PINNED_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF

cat >"${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth) exit 0 ;;
  api)
    case "${2:-}" in
      *'page=1') printf '%s\n' '[{"iid":42,"state":"opened","labels":[]}]' ;;
      *'page=2') printf '%s\n' '[]' ;;
      *) exit 91 ;;
    esac
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
jq -cn '{status:"drained",scanned:0,attempted:0,delivered:0,failed:0}'
EOF
cat >"${FAKE_BIN}/reserve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${EXECUTOR_SCHEDULER_ROOT}" = "${OVERRIDE_ROOT}" ] \
  && [ "${EXECUTOR_MAX_CONCURRENCY}" = 5 ] \
  && [ "${SCHEDULER_STATE_FILE}" = "${OVERRIDE_ROOT}/scheduler_state.json" ] \
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
  || exit 96
printf '%s\n' scheduler-root-ok >>"${OVERRIDE_LOG}"
jq -cn --arg job_id "${JOB_ID}" '{
  status:"recorded",job_id:$job_id,job_status:"running",active_count:1,
  should_spawn:false,claim_generation:null,claim_token:null
}'
EOF
chmod +x "${FAKE_BIN}"/*

EXECUTOR_SCHEDULER_ROOT="${OVERRIDE_ROOT}" EXECUTOR_MAX_CONCURRENCY=5 \
  CONFIG_DIR="${CONFIG_DIR}" GLAB_BIN="${FAKE_BIN}/glab" \
  GITLAB_TOKEN=override-token bash "${CREATE_SCRIPT}" >/dev/null <<'EOF'
RUN_DRIVEN_ISSUE_BATCH
batch_id=override-batch
correlation_id=override-correlation
project=group/repo
selector_type=single
iid=42
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
EOF
[ -f "${OVERRIDE_ROOT}/batches/override-batch/request.json" ] \
  || fail "intake did not use the process scheduler root override"
[ ! -e "${PINNED_ROOT}/batches/override-batch" ] \
  || fail "intake duplicated the batch into the pinned scheduler root"

tick_output="$(EXECUTOR_SCHEDULER_ROOT="${OVERRIDE_ROOT}" \
  EXECUTOR_MAX_CONCURRENCY=5 CONFIG_DIR="${CONFIG_DIR}" \
  TEST_ROOT="${TEST_ROOT}" OVERRIDE_ROOT="${OVERRIDE_ROOT}" \
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

echo "ok intake, tick, topup, and record share process scheduler overrides"
