#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TICK_SCRIPT="${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
RECONCILE_SCRIPT="${SKILL_DIR}/scripts/resolve_executor_batch_reconcile.sh"
RECORD_SPAWN_SCRIPT="${SKILL_DIR}/scripts/record_executor_batch_spawn.sh"
RECORD_LAUNCH_SCRIPT="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

fail() {
  echo "test_executor_batch_tick_coordinator_recovery.sh: $*" >&2
  exit 1
}

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-tick-coordinator.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/fake-bin"
mkdir -p "${FAKE_BIN}"

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
jq -cn '{max_concurrency:3}'
EOF
cat >"${FAKE_BIN}/resolve.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CASE_ROOT}/repos/group/repo"
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
if [ "${DRIVEN_ACK_RECOVERY_JOB_ID:-}" = "A:snapshot-0" ] \
    && [ "${DRIVEN_ACK_RECOVERY_LEASE_SECONDS:-}" = 180 ] \
    && jq -e --argjson now "${NOW_EPOCH:-$(date +%s)}" '
      .active_jobs["A:snapshot-0"].status == "preparing"
      and ($now - .active_jobs["A:snapshot-0"].updated_at) >= 1
    ' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null; then
  state="$(jq -c '
    .active_jobs["A:snapshot-0"].status = "reserved"
    | .active_jobs["A:snapshot-0"].claim_token = null
  ' "${SCHEDULER_ROOT}/scheduler_state.json")"
  printf '%s\n' "${state}" >"${SCHEDULER_ROOT}/scheduler_state.json"
fi
jq -cn '{
  status:"ready",active_count:1,available_slots:2,
  grants:[{
    job_id:"A:snapshot-0",batch_id:"A",snapshot_index:0,
    project:"group/repo",iid:42,branch:null,entry_mode:"auto",
    force_rerun_pr:false
  }]
}'
EOF
cat >"${FAKE_BIN}/topup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf '%s\n' topup >>"${CALL_LOG}"
[ "${TOPUP_FAIL:-0}" != 1 ] || exit 79
jq -cn --arg payload "${CASE_ROOT}/payload.txt" '{
  status:"ready",
  dispatch_entries:[{
    iid:42,execution_id:1,child_label:"#42-att-001",
    payload_path:$payload,job_id:"A:snapshot-0",batch_id:"A",
    expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
    expected_task_bytes:7,
    snapshot_index:0,memberships_source:"scheduler_active_job"
  }],
  skipped_entries:[]
}'
EOF
cat >"${FAKE_BIN}/skip.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
cat >"${FAKE_BIN}/record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'record:%s\n' "${JOB_ID}" >>"${CALL_LOG}"
state="$(cat "${SCHEDULER_ROOT}/scheduler_state.json")"
status="$(jq -r --arg job_id "${JOB_ID}" '.active_jobs[$job_id].status' <<<"${state}")"
if [ "${status}" = reserved ]; then
  current_generation="$(jq -r --arg job_id "${JOB_ID}" \
    '.active_jobs[$job_id].claim_generation // 0' <<<"${state}")"
  next_generation=$((current_generation + 1))
  state="$(jq -c --arg job_id "${JOB_ID}" '
    .active_jobs[$job_id].status = "preparing"
    | .active_jobs[$job_id].updated_at = (now | floor)
  ' <<<"${state}")"
  state="$(jq -c --arg job_id "${JOB_ID}" \
    --argjson generation "${next_generation}" \
    --arg token "private-coordinator-claim-${next_generation}" '
    .active_jobs[$job_id].claim_generation = $generation
    | .active_jobs[$job_id].claim_token = $token
  ' <<<"${state}")"
  printf '%s\n' "${state}" >"${SCHEDULER_ROOT}/scheduler_state.json"
  jq -cn --arg job_id "${JOB_ID}" --argjson generation "${next_generation}" \
    --arg token "private-coordinator-claim-${next_generation}" '{
    status:"recorded",job_id:$job_id,job_status:"preparing",active_count:1,
    should_spawn:true,claim_generation:$generation,claim_token:$token
  }'
else
  jq -cn --arg job_id "${JOB_ID}" '{
    status:"recorded",job_id:$job_id,job_status:"preparing",active_count:1,
    should_spawn:false,claim_generation:null,claim_token:null
  }'
fi
EOF
cat >"${FAKE_BIN}/bind.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'bind:%s:%s\n' "${JOB_ID}" "${CLAIM_GENERATION}" >>"${CALL_LOG}"
jq -cn --arg job_id "${JOB_ID}" --argjson generation "${CLAIM_GENERATION}" '{
  status:"bound",iid:42,job_id:$job_id,claim_generation:$generation
}'
EOF
cat >"${FAKE_BIN}/project_record.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
status_before="$(jq -r '.active_jobs["A:snapshot-0"].status' \
  "${SCHEDULER_ROOT}/scheduler_state.json")"
[ "${status_before}" = reserved ] || {
  echo "project record did not run before scheduler recovery" >&2
  exit 98
}
printf 'project:%s:%s\n' "${STATUS}" "${IID}" >>"${CALL_LOG}"
jq -cn --argjson iid "${IID}" --argjson attempt "${EXECUTION_ID}" '{
  status:"spawned",iid:$iid,execution_id:$attempt,
  remaining_pending_count:1,chat_summary:"recorded"
}'
EOF
chmod +x "${FAKE_BIN}"/*.sh

setup_case() {
  local name="$1"
  CASE_ROOT="${TEST_ROOT}/${name}"
  CONFIG_DIR="${CASE_ROOT}/config"
  SCHEDULER_ROOT="${CASE_ROOT}/scheduler"
  CALL_LOG="${CASE_ROOT}/calls.log"
  mkdir -p "${CONFIG_DIR}" "${SCHEDULER_ROOT}/batches/A" \
    "${CASE_ROOT}/repos/group/repo/.git"
  : >"${CALL_LOG}"
  printf '%s' payload >"${CASE_ROOT}/payload.txt"
  cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=fixture-token
EOF
  cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${CASE_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF
  cat >"${SCHEDULER_ROOT}/batches/A/request.json" <<'EOF'
{"version":1,"batch_id":"A","project":"group/repo","dispatcher_callback_target":"agent:req_dispatcher:main"}
EOF
  cat >"${SCHEDULER_ROOT}/scheduler_state.json" <<'EOF'
{"version":1,"round_robin_cursor":null,"batch_order":["A"],"active_jobs":{
  "A:snapshot-0":{
    "job_id":"A:snapshot-0","project":"group/repo","iid":42,
    "branch":null,"entry_mode":"auto","force_rerun_pr":false,
    "status":"reserved","claim_generation":0,"claim_token":null,
    "owner":{"batch_id":"A","snapshot_index":0}
  }
}}
EOF
}

run_case_tick() {
  local fault="${1:-}" topup_fail="${2:-0}"
  CONFIG_DIR="${CONFIG_DIR}" \
  CASE_ROOT="${CASE_ROOT}" SCHEDULER_ROOT="${SCHEDULER_ROOT}" CALL_LOG="${CALL_LOG}" \
  TOPUP_FAIL="${topup_fail}" \
  SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_outbox.sh" \
  RESERVE_CMD="${FAKE_BIN}/reserve.sh" \
  TOPUP_CMD="${FAKE_BIN}/topup.sh" \
  IMPORT_SKIP_CMD="${FAKE_BIN}/skip.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/record.sh" \
  BIND_CLAIM_CMD="${FAKE_BIN}/bind.sh" \
  DRIVEN_COORDINATOR_FAULT="${fault}" \
    bash "${TICK_SCRIPT}"
}

upgrade_case_for_real_recording() {
  cat >"${SCHEDULER_ROOT}/batches/A/snapshot.json" <<'EOF'
{"version":1,"project":"group/repo","iids":[42]}
EOF
  cat >"${SCHEDULER_ROOT}/batches/A/state.json" <<'EOF'
{
  "version":1,"batch_id":"A","status":"running","matched_count":1,
  "terminal_count":0,"done_count":0,"failed_count":0,"timeout_count":0,
  "skipped_count":0,"next_snapshot_index":1,
  "request_digest":"fixture-request","snapshot_digest":"fixture-snapshot",
  "memberships":{"0":{
    "snapshot_index":0,"iid":42,"status":"reserved",
    "job_id":"A:snapshot-0"
  }}
}
EOF
  scheduler_state="$(jq -c '
    .active_jobs["A:snapshot-0"] += {
      physical_key:"group/repo#42",reservation_seq:1,
      reserved_at:1,updated_at:1,
      memberships:[{batch_id:"A",snapshot_index:0}],
      finalization:null
    }
  ' "${SCHEDULER_ROOT}/scheduler_state.json")"
  printf '%s\n' "${scheduler_state}" >"${SCHEDULER_ROOT}/scheduler_state.json"
  request_state="$(jq -c '
    .force_rerun_pr = false
    | .branch = null
  ' "${SCHEDULER_ROOT}/batches/A/request.json")"
  printf '%s\n' "${request_state}" >"${SCHEDULER_ROOT}/batches/A/request.json"
}

assert_replay_once() {
  local expected_prior_stage="$1" generation1_label=""
  mapfile -t files < <(find "${SCHEDULER_ROOT}/launch_actions" \
    -maxdepth 1 -type f -name '*.json' -print)
  [ "${#files[@]}" -eq 1 ] || fail "${expected_prior_stage}: missing coordinator action"
  jq -e --arg stage "${expected_prior_stage}" '.stage == $stage' "${files[0]}" >/dev/null \
    || fail "expected coordinator stage ${expected_prior_stage}"
  replay="$(run_case_tick '' 1)" || fail "${expected_prior_stage}: replay failed"
  jq -e '
    .status == "ready"
    and (.spawn_grants | length) == 1
    and .spawn_grants[0].job_id == "A:snapshot-0"
    and .spawn_grants[0].claim_generation == 1
    and (tostring | contains("private-coordinator-claim") | not)
  ' <<<"${replay}" >/dev/null || fail "${expected_prior_stage}: replay did not emit one safe action"
  generation1_label="$(jq -r '.spawn_grants[0].child_label' <<<"${replay}")"
  [[ "${generation1_label}" =~ ^reqx-iid42-gen1-[0-9a-f]{40}$ ]] \
    || fail "${expected_prior_stage}: generation 1 runtime label is unsafe"
  record_count="$(grep -c '^record:' "${CALL_LOG}" || true)"
  bind_count="$(grep -c '^bind:' "${CALL_LOG}" || true)"
  [ "${record_count}" -le 1 ] && [ "${bind_count}" -le 1 ] \
    || fail "${expected_prior_stage}: replay repeated record/bind"
  third="$(run_case_tick '' 1)" || true
  jq -e '.spawn_grants == []' <<<"${third}" >/dev/null \
    || fail "${expected_prior_stage}: coordinator emitted the same actionable grant twice"

  # The most dangerous window is action_emitted durable + sessions_spawn may
  # have succeeded + no post-ack wrapper call yet. Before the dedicated ACK
  # lease expires, the same claim stays suppressed. Once it expires, the tick
  # itself must reach reserve, fence preparing back to reserved, and require
  # runtime enumeration before the physical job may get a new generation.
  action_file="${files[0]}"
  jq -e '.stage == "action_emitted" and .claim_generation == 1' \
    "${action_file}" >/dev/null \
    || fail "${expected_prior_stage}: actionable emission was not durable"
  action_state="$(jq -c '.updated_at = 1' "${action_file}")"
  printf '%s\n' "${action_state}" >"${action_file}"
  scheduler_state="$(jq -c '
    .active_jobs["A:snapshot-0"].updated_at = 1
  ' "${SCHEDULER_ROOT}/scheduler_state.json")"
  printf '%s\n' "${scheduler_state}" >"${SCHEDULER_ROOT}/scheduler_state.json"
  reconcile_required="$(run_case_tick '' 1)" \
    || fail "${expected_prior_stage}: emitted-action reconciliation failed"
  jq -e --arg child_label "${generation1_label}" '
    .spawn_grants == []
    and (.reconcile_actions | length) == 1
    and .reconcile_actions[0] == {
      action:"reconcile_emitted_spawn",
      job_id:"A:snapshot-0",
      claim_generation:1,
      project:"group/repo",
      iid:42,
      execution_id:1,
      child_label:$child_label,
      expected_task_sha256:"0000000000000000000000000000000000000000000000000000000000000042",
      expected_task_bytes:7
    }
    and (tostring | contains("private-coordinator-claim") | not)
  ' <<<"${reconcile_required}" >/dev/null \
    || fail "${expected_prior_stage}: expired emitted action was re-spawned before runtime reconciliation"

  not_found_result="$(printf '%s' "$(jq -cn '{
    job_id:"A:snapshot-0",claim_generation:1,resolution:"not_found",
    evidence:"subagents_list_no_matching_label"
  }')" | \
    CONFIG_DIR="${CONFIG_DIR}" SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
    SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
    RECORD_SPAWN_CMD="${FAKE_BIN}/record.sh" \
    bash "${RECONCILE_SCRIPT}")" \
    || fail "${expected_prior_stage}: explicit not_found reconciliation failed"
  jq -e '
    .status == "reset_for_next_generation"
    and .job_id == "A:snapshot-0"
    and .claim_generation == 1
  ' <<<"${not_found_result}" >/dev/null \
    || fail "${expected_prior_stage}: not_found returned an invalid result"

  next_generation="$(run_case_tick '' 1)" \
    || fail "${expected_prior_stage}: reconciled generation did not retry"
  jq -e --arg generation1_label "${generation1_label}" '
    .reconcile_actions == []
    and (.spawn_grants | length) == 1
    and .spawn_grants[0].job_id == "A:snapshot-0"
    and .spawn_grants[0].claim_generation == 2
    and (.spawn_grants[0].child_label
      | test("^reqx-iid42-gen2-[0-9a-f]{40}$"))
    and .spawn_grants[0].child_label != $generation1_label
    and (tostring | contains("private-coordinator-claim") | not)
  ' <<<"${next_generation}" >/dev/null \
    || fail "${expected_prior_stage}: next generation was not fenced behind explicit evidence"
}

setup_case after_topup
set +e
run_case_tick after_topup_seed >/dev/null
rc=$?
set -e
[ "${rc}" -eq 83 ] || fail "after_topup_seed fault did not exit 83 (got ${rc})"
[ ! -s "${CALL_LOG}" ] || [ "$(cat "${CALL_LOG}")" = topup ] \
  || fail "after_topup_seed crossed preparing"
assert_replay_once topup_prepared

setup_case after_preparing
set +e
run_case_tick after_preparing_persist >/dev/null
rc=$?
set -e
[ "${rc}" -eq 84 ] || fail "after_preparing_persist fault did not exit 84 (got ${rc})"
[ "$(grep -c '^record:' "${CALL_LOG}")" -eq 1 ] \
  && [ "$(grep -c '^bind:' "${CALL_LOG}" || true)" -eq 0 ] \
  || fail "after_preparing_persist crossed bind"
assert_replay_once preparing_claimed

setup_case after_bind
set +e
run_case_tick after_bind_persist >/dev/null
rc=$?
set -e
[ "${rc}" -eq 85 ] || fail "after_bind_persist fault did not exit 85 (got ${rc})"
[ "$(grep -c '^record:' "${CALL_LOG}")" -eq 1 ] \
  && [ "$(grep -c '^bind:' "${CALL_LOG}")" -eq 1 ] \
  || fail "after_bind_persist did not persist exactly one bind"
assert_replay_once bound

# If runtime enumeration finds the child after the preparing lease was fenced,
# the explicit evidence must finish the original generation project-first,
# restore that same scheduler generation, and leave the following tick with no
# second spawn or reconciliation action.
setup_case runtime_found
upgrade_case_for_real_recording
first_generation="$(run_case_tick)" || fail "runtime_found: initial tick failed"
jq -e '
  (.spawn_grants | length) == 1
  and .spawn_grants[0].job_id == "A:snapshot-0"
  and .spawn_grants[0].claim_generation == 1
' <<<"${first_generation}" >/dev/null \
  || fail "runtime_found: initial generation was not emitted"
found_generation1_label="$(jq -r '.spawn_grants[0].child_label' \
  <<<"${first_generation}")"
[[ "${found_generation1_label}" =~ ^reqx-iid42-gen1-[0-9a-f]{40}$ ]] \
  || fail "runtime_found: initial runtime label is unsafe"

mapfile -t runtime_action_files < <(find "${SCHEDULER_ROOT}/launch_actions" \
  -maxdepth 1 -type f -name '*.json' -print)
[ "${#runtime_action_files[@]}" -eq 1 ] \
  || fail "runtime_found: durable launch action is missing before expiry"
runtime_action_state="$(jq -c '.updated_at = 1' "${runtime_action_files[0]}")"
printf '%s\n' "${runtime_action_state}" >"${runtime_action_files[0]}"
scheduler_state="$(jq -c '
  .active_jobs["A:snapshot-0"].updated_at = 1
' "${SCHEDULER_ROOT}/scheduler_state.json")"
printf '%s\n' "${scheduler_state}" >"${SCHEDULER_ROOT}/scheduler_state.json"

reconcile_required="$(run_case_tick '' 1)" \
  || fail "runtime_found: fenced tick failed"
jq -e --arg child_label "${found_generation1_label}" '
  .spawn_grants == []
  and (.reconcile_actions | length) == 1
  and .reconcile_actions[0].job_id == "A:snapshot-0"
  and .reconcile_actions[0].claim_generation == 1
  and .reconcile_actions[0].child_label == $child_label
' <<<"${reconcile_required}" >/dev/null \
  || fail "runtime_found: fenced action did not require explicit evidence"

: >"${CALL_LOG}"
found_result="$(printf '%s' "$(jq -cn '{
  job_id:"A:snapshot-0",claim_generation:1,resolution:"spawned",
  run_id:"runtime-run-1",
  child_session_key:"agent:req_executor:subagent:runtime-1"
}')" | \
  CONFIG_DIR="${CONFIG_DIR}" CASE_ROOT="${CASE_ROOT}" \
  SCHEDULER_ROOT="${SCHEDULER_ROOT}" CALL_LOG="${CALL_LOG}" \
  SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
  PROJECT_RECORD_CMD="${FAKE_BIN}/project_record.sh" \
  RECORD_LAUNCH_CMD="${RECORD_LAUNCH_SCRIPT}" \
  RECORD_SPAWN_CMD="${RECORD_SPAWN_SCRIPT}" \
  bash "${RECONCILE_SCRIPT}")" \
  || fail "runtime_found: spawned reconciliation failed"
jq -e '
  .status == "spawned_recorded"
  and .job_id == "A:snapshot-0"
  and .claim_generation == 1
' <<<"${found_result}" >/dev/null \
  || fail "runtime_found: spawned reconciliation returned a loose result"
[ "$(cat "${CALL_LOG}")" = 'project:spawned:42' ] \
  || fail "runtime_found: project state was not recorded exactly once first"
jq -e '
  .active_jobs["A:snapshot-0"].status == "running"
  and .active_jobs["A:snapshot-0"].claim_generation == 1
  and (.active_jobs["A:snapshot-0"].claim_token | type == "string" and length > 0)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "runtime_found: scheduler did not restore the original generation"
mapfile -t found_action_files < <(find "${SCHEDULER_ROOT}/launch_actions" \
  -maxdepth 1 -type f -name '*.json' -print)
[ "${#found_action_files[@]}" -eq 1 ] \
  || fail "runtime_found: durable launch action is missing"
jq -e --arg child_label "${found_generation1_label}" '
  .stage == "completed"
  and .runtime_label_version == 1
  and .child_label == $child_label
' "${found_action_files[0]}" >/dev/null \
  || fail "runtime_found: durable action lost the exact runtime label"

: >"${CALL_LOG}"
after_found="$(run_case_tick)" || fail "runtime_found: recovery tick failed"
jq -e '.spawn_grants == [] and .reconcile_actions == []' \
  <<<"${after_found}" >/dev/null \
  || fail "runtime_found: recovered child was spawned or reconciled twice"
if grep -Eq '^(record|bind):' "${CALL_LOG}"; then
  fail "runtime_found: recovery tick allocated another generation"
fi

echo "ok tick coordinator recovers launch stages and explicit runtime reconciliation"
