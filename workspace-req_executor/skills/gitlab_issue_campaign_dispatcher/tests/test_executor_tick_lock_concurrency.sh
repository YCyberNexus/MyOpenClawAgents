#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TICK_SCRIPT="${SKILL_DIR}/scripts/run_executor_batch_tick.sh"

fail() {
  echo "test_executor_tick_lock_concurrency.sh: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-tick-lock.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BARRIER_ROOT="${TEST_ROOT}/barriers"
REPO_ROOT="${TEST_ROOT}/repos/group/repo"
mkdir -p "${CONFIG_DIR}" "${SCHEDULER_ROOT}" "${FAKE_BIN}" \
  "${BARRIER_ROOT}" "${REPO_ROOT}/.git"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab.example.test
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=tick-lock-fixture
EOF
cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${TEST_ROOT}/repos
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_RUNNING_LEASE_SECONDS=999999
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF

now_epoch="$(date +%s)"
jq -cnS --argjson now "${now_epoch}" '{
  version:1,round_robin_cursor:null,batch_order:[],active_jobs:{
    "batch-A:snapshot-0":{
      job_id:"batch-A:snapshot-0",physical_key:"group/repo#42",
      project:"group/repo",iid:42,branch:null,entry_mode:"auto",
      force_rerun_pr:false,status:"running",reservation_seq:1,
      reserved_at:$now,updated_at:$now,claim_generation:1,
      claim_token:"running-claim",
      owner:{batch_id:"batch-A",snapshot_index:0},
      memberships:[{batch_id:"batch-A",snapshot_index:0}]
    }
  }
}' >"${SCHEDULER_ROOT}/scheduler_state.json"

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
export EXECUTOR_SCHEDULER_ROOT="${SCHEDULER_ROOT}"
export EXECUTOR_MAX_CONCURRENCY=3
export EXECUTOR_RUNNING_LEASE_SECONDS=999999
export EXECUTOR_AGENT=req_executor
export DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
export DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
export LEGACY_LOCK_COMPAT_ACTIVE=false
export SCHEDULER_STATE_FILE="${SCHEDULER_ROOT}/scheduler_state.json"
export SCHEDULER_LOCK_FILE="${SCHEDULER_ROOT}/scheduler.lock"
export BATCHES_ROOT="${SCHEDULER_ROOT}/batches"
export CALLBACK_INBOX="${SCHEDULER_ROOT}/callback_inbox"
export CALLBACK_OUTBOX="${SCHEDULER_ROOT}/callback_outbox"
mkdir -p "${BATCHES_ROOT}" "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}"
jq -cn "{scheduler_root:\"${SCHEDULER_ROOT}\",max_concurrency:3}"
'
write_fake resolve.sh 'printf "%s\n" "${TEST_ROOT}/repos/group/repo"'
write_fake drain_intents.sh \
  'jq -cn '\''{status:"drained",intent_count:0,results:[]}'\'''
write_fake reconcile_counts.sh \
  'jq -cn '\''{status:"reconciled",scanned:0,repaired:0,unresolved:0}'\'''
cat >"${FAKE_BIN}/drain_outbox.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${TICK_TEST_ROLE:-}" = OUTBOX_A ]; then
  : >"${BARRIER_ROOT}/outbox_a_waiting"
  waits=0
  while [ ! -e "${BARRIER_ROOT}/release_outbox_a" ]; do
    waits=$((waits + 1))
    [ "${waits}" -le 200 ] || exit 84
    sleep 0.05
  done
fi
jq -cn '{status:"drained",scanned:0,attempted:0,delivered:0,failed:0}'
EOF
chmod +x "${FAKE_BIN}/drain_outbox.sh"
write_fake reserve.sh \
  'jq -cn '\''{status:"at_capacity",grants:[],active_count:1,available_slots:0}'\'''

cat >"${FAKE_BIN}/topup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$(cat)"
jq -e '.grants | length == 1 and .[0].job_id == "batch-A:snapshot-0"' \
  <<<"${request}" >/dev/null
case "${TICK_TEST_ROLE:?}" in
  A)
    : >"${BARRIER_ROOT}/a_snapshot_ready"
    waits=0
    while [ ! -e "${BARRIER_ROOT}/release_a" ]; do
      waits=$((waits + 1))
      [ "${waits}" -le 200 ] || exit 81
      sleep 0.05
    done
    jq -cn '{
      status:"no_eligible_iids",dispatch_entries:[],pending_iids:[],
      skipped_entries:[{
        job_id:"batch-A:snapshot-0",batch_id:"batch-A",snapshot_index:0,
        project:"group/repo",iid:42,status:"skipped",reason:"closed"
      }]
    }'
    ;;
  B)
    : >"${BARRIER_ROOT}/b_entered_topup"
    jq -cn '{job_id:"batch-A:snapshot-0",iid:42}' \
      >"${BARRIER_ROOT}/project_pending.json"
    jq -cn '{
      status:"waiting_for_callbacks",dispatch_entries:[],pending_iids:[42],
      skipped_entries:[]
    }'
    ;;
  OUTBOX_A|OUTBOX_B)
    if [ "${TICK_TEST_ROLE}" = OUTBOX_B ]; then
      : >"${BARRIER_ROOT}/outbox_b_entered_topup"
    fi
    jq -cn '{
      status:"waiting_for_callbacks",dispatch_entries:[],pending_iids:[42],
      skipped_entries:[]
    }'
    ;;
  *) exit 82 ;;
esac
EOF
chmod +x "${FAKE_BIN}/topup.sh"

cat >"${FAKE_BIN}/import_skip.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
entry="$(cat)"
job_id="$(jq -r '.job_id' <<<"${entry}")"
jq --arg job_id "${job_id}" 'del(.active_jobs[$job_id])' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
jq -cn --arg job_id "${job_id}" \
  '{status:"imported",job_id:$job_id,event_id:($job_id + ":claim-1:terminal-1")}'
EOF
chmod +x "${FAKE_BIN}/import_skip.sh"

write_fake unused.sh 'exit 83'

run_tick() {
  local role="$1" output="$2"
  TICK_TEST_ROLE="${role}" BARRIER_ROOT="${BARRIER_ROOT}" \
  CONFIG_DIR="${CONFIG_DIR}" TEST_ROOT="${TEST_ROOT}" \
  SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
  SCHEDULER_ENV_CMD="${FAKE_BIN}/scheduler_env.sh" \
  RESOLVE_REPO_CMD="${FAKE_BIN}/resolve.sh" \
  DRAIN_HANDOFF_CMD="${FAKE_BIN}/drain_intents.sh" \
  DRAIN_OUTBOX_CMD="${FAKE_BIN}/drain_outbox.sh" \
  RECONCILE_COUNTS_CMD="${FAKE_BIN}/reconcile_counts.sh" \
  RESERVE_CMD="${FAKE_BIN}/reserve.sh" \
  TOPUP_CMD="${FAKE_BIN}/topup.sh" \
  IMPORT_SKIP_CMD="${FAKE_BIN}/import_skip.sh" \
  RECORD_LAUNCH_CMD="${FAKE_BIN}/unused.sh" \
  BIND_CLAIM_CMD="${FAKE_BIN}/unused.sh" \
  RESUME_SPAWN_CMD="${FAKE_BIN}/unused.sh" \
  EXPIRE_RUNNING_CMD="${FAKE_BIN}/unused.sh" \
    bash "${TICK_SCRIPT}" >"${output}" 2>"${output}.err"
  : >"${output}.done"
}

run_tick OUTBOX_A "${TEST_ROOT}/tick-outbox-a.out" &
tick_outbox_a_pid=$!
waits=0
while [ ! -e "${BARRIER_ROOT}/outbox_a_waiting" ]; do
  waits=$((waits + 1))
  [ "${waits}" -le 200 ] || fail "tick OUTBOX_A did not reach the callback barrier"
  sleep 0.05
done

run_tick OUTBOX_B "${TEST_ROOT}/tick-outbox-b.out" &
tick_outbox_b_pid=$!
outbox_b_entered_topup=false
for _ in $(seq 1 60); do
  if [ -e "${BARRIER_ROOT}/outbox_b_entered_topup" ]; then
    outbox_b_entered_topup=true
    break
  fi
  [ ! -e "${TEST_ROOT}/tick-outbox-b.out.done" ] || break
  sleep 0.05
done
: >"${BARRIER_ROOT}/release_outbox_a"
wait "${tick_outbox_a_pid}" || fail "tick OUTBOX_A failed"
wait "${tick_outbox_b_pid}" || fail "tick OUTBOX_B failed"
[ "${outbox_b_entered_topup}" = true ] \
  || fail "a slow callback drain held the global topup transaction lock"

run_tick A "${TEST_ROOT}/tick-a.out" &
tick_a_pid=$!
waits=0
while [ ! -e "${BARRIER_ROOT}/a_snapshot_ready" ]; do
  waits=$((waits + 1))
  [ "${waits}" -le 200 ] || fail "tick A did not reach the controlled barrier"
  sleep 0.05
done

run_tick B "${TEST_ROOT}/tick-b.out" &
tick_b_pid=$!
concurrent_entry=false
tick_b_returned=false
for _ in $(seq 1 30); do
  if [ -e "${BARRIER_ROOT}/b_entered_topup" ]; then
    concurrent_entry=true
    break
  fi
  if [ -e "${TEST_ROOT}/tick-b.out.done" ]; then
    tick_b_returned=true
    break
  fi
  sleep 0.05
done

: >"${BARRIER_ROOT}/release_a"
wait "${tick_a_pid}" || fail "tick A failed"
wait "${tick_b_pid}" || fail "tick B failed"

[ "${concurrent_entry}" = false ] \
  || fail "tick B entered topup before tick A finalized its stale skip snapshot"
[ "${tick_b_returned}" = true ] \
  || fail "overlapping tick B blocked instead of returning an idle lock-held envelope"
jq -e '
  .status == "idle"
  and .spawn_grants == []
  and .reconcile_actions == []
  and ([.operation_results[] | select(
    .operation == "tick_lock" and .status == "held")] | length) == 1
' "${TEST_ROOT}/tick-b.out" >/dev/null \
  || fail "overlapping tick B did not return the strict lock-held envelope"
[ ! -e "${BARRIER_ROOT}/project_pending.json" ] \
  || fail "a concurrent tick left project pending after the scheduler job was removed"
jq -e '.active_jobs == {}' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "tick A did not finalize the running scheduler job"

echo "ok executor tick lock keeps topup snapshot and skip finalize atomic"
