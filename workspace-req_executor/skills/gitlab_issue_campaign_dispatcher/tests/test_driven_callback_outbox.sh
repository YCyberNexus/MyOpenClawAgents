#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMPORT_HANDOFF="${SKILL_DIR}/scripts/import_driven_handoff.sh"
DRAIN_OUTBOX="${SKILL_DIR}/scripts/drain_driven_outbox.sh"
BIND_CLAIM="${SKILL_DIR}/scripts/bind_driven_claim.sh"
RECORD_LAUNCH="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

fail() {
  echo "test_driven_callback_outbox.sh: $*" >&2
  exit 1
}

[ -x "${IMPORT_HANDOFF}" ] || fail "import_driven_handoff.sh is missing or not executable"
[ -x "${DRAIN_OUTBOX}" ] || fail "drain_driven_outbox.sh is missing or not executable"
[ -x "${BIND_CLAIM}" ] || fail "bind_driven_claim.sh is missing or not executable"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-driven-callback.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

# Task9 binds the exact preparing claim into the project pending entry before
# sessions_spawn. The bind must serialize on the campaign lock, preserve bytes
# on an identical replay, and reject a different generation/token fail-closed.
BIND_PARENT="${TEST_ROOT}/bind-repos"
BIND_REPO="${BIND_PARENT}/repo"
BIND_STATE="${BIND_REPO}/.req_executor/_dispatcher/campaign_state.json"
BIND_LOCK="${BIND_REPO}/.req_executor/_dispatcher/campaign.lock"
mkdir -p \
  "${BIND_REPO}/.git" \
  "${BIND_REPO}/.req_executor/_dispatcher/log" \
  "${BIND_REPO}/.req_executor/issues"
jq -cnS '{
  pending_subagents:{
    "42":{
      attempt_number:1,
      job_id:"batch-A:snapshot-0",
      batch_id:"batch-A",
      snapshot_index:0,
      memberships_source:"scheduler_active_job"
    }
  },
  active_issue_iids:[42],
  active_issue_sessions:["issue-repo-42"]
}' >"${BIND_STATE}"

run_bind() {
  local token="$1"
  local generation="$2"
  PROJECT=repo \
  PROJECT_FULL=group/repo \
  GROUP=group \
  GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example \
  GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${BIND_PARENT}" \
  IID=42 \
  JOB_ID='batch-A:snapshot-0' \
  CLAIM_TOKEN="${token}" \
  CLAIM_GENERATION="${generation}" \
  NOW_ISO='2026-07-11T01:02:03Z' \
  bash "${BIND_CLAIM}"
}

exec 8>"${BIND_LOCK}"
flock -x 8
run_bind claim-token-42 1 >"${TEST_ROOT}/bind-blocked.out" &
BIND_PID=$!
sleep 0.1
kill -0 "${BIND_PID}" 2>/dev/null \
  || fail "bind did not wait for the campaign lock"
jq -e '.pending_subagents["42"] | has("claim_token") | not' \
  "${BIND_STATE}" >/dev/null \
  || fail "bind mutated pending state before acquiring the campaign lock"
flock -u 8
exec 8>&-
wait "${BIND_PID}"
jq -e '
  .pending_subagents["42"].claim_generation == 1
  and .pending_subagents["42"].claim_token == "claim-token-42"
  and .pending_subagents["42"].bound_at == "2026-07-11T01:02:03Z"
' "${BIND_STATE}" >/dev/null \
  || fail "bind did not persist the exact preparing claim"

cp "${BIND_STATE}" "${TEST_ROOT}/bind-state-before-replay.json"
run_bind claim-token-42 1 >"${TEST_ROOT}/bind-replay.out"
cmp -s "${BIND_STATE}" "${TEST_ROOT}/bind-state-before-replay.json" \
  || fail "identical claim replay changed campaign state bytes"
if run_bind conflicting-token 2 >"${TEST_ROOT}/bind-conflict.out" 2>"${TEST_ROOT}/bind-conflict.err"; then
  fail "different claim binding did not fail closed"
fi
cmp -s "${BIND_STATE}" "${TEST_ROOT}/bind-state-before-replay.json" \
  || fail "conflicting claim binding mutated campaign state"

if env -u REPO_PARENT_PATH \
  PROJECT=repo \
  PROJECT_FULL=group/repo \
  GROUP=group \
  GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example \
  GITLAB_API_PROTOCOL=https \
  IID=42 \
  JOB_ID='batch-A:snapshot-0' \
  CLAIM_TOKEN=claim-token-42 \
  CLAIM_GENERATION=1 \
  bash "${BIND_CLAIM}" >"${TEST_ROOT}/bind-no-parent.out" \
    2>"${TEST_ROOT}/bind-no-parent.err"; then
  fail "bind accepted a missing REPO_PARENT_PATH input"
fi
grep -q 'REPO_PARENT_PATH must be set' "${TEST_ROOT}/bind-no-parent.err" \
  || fail "bind did not identify its missing REPO_PARENT_PATH input"

# Pending entries created before claim binding (including reserved claim-0
# preflight terminals) remain valid legacy input. Their physical event carries
# the explicit reserved identity without leaking a token.
LEGACY_HANDOFF_ISSUES="${TEST_ROOT}/legacy-handoff-issues"
LEGACY_PENDING='{
  "job_id":"legacy-batch:snapshot-0",
  "batch_id":"legacy-batch",
  "snapshot_index":0,
  "memberships_source":"scheduler_active_job"
}'
legacy_handoff_path="$(
  CAMPAIGN_STATE_FILE="${TEST_ROOT}/unused-campaign-state.json" \
  PROJECT_URI='https://gitlab.example/group/repo' \
  PROJECT_FULL='group/repo' \
  ISSUES_ROOT="${LEGACY_HANDOFF_ISSUES}" \
  DISPATCH_LIB="${SKILL_DIR}/scripts/_dispatch_lib.sh" \
  LEGACY_PENDING="${LEGACY_PENDING}" \
  bash -c '
    source "${DISPATCH_LIB}"
    phase6_write_driven_handoff "${LEGACY_PENDING}" 42 skipped "" "reserved preflight"
  '
)" || fail "legacy claim-0 pending entry could not write a handoff"
jq -e '
  .event_id == "legacy-batch:snapshot-0:claim-0:terminal-1"
  and .job_id == "legacy-batch:snapshot-0"
  and .claim_generation == 0
  and .claim_token == null
' "${legacy_handoff_path}" >/dev/null \
  || fail "legacy pending handoff did not normalize to claim-0/null"

create_batch_fixture() {
  local batch_id="$1"
  local callback_target="$2"
  local membership_status="$3"
  local batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"

  mkdir -p "${batch_dir}"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg target "${callback_target}" '{
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:"group/repo",
      selector:{type:"single",iid:42},
      force_rerun_pr:false,
      dispatcher_callback_target:$target,
      branch:"main"
    }' >"${batch_dir}/request.json"
  jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg membership_status "${membership_status}" '{
      version:1,
      batch_id:$batch_id,
      status:"running",
      matched_count:1,
      terminal_count:0,
      done_count:0,
      failed_count:0,
      timeout_count:0,
      skipped_count:0,
      next_snapshot_index:1,
      request_digest:"fixture-request",
      snapshot_digest:"fixture-snapshot",
      memberships:{
        "0":{
          snapshot_index:0,
          iid:42,
          status:$membership_status,
          job_id:"batch-A:snapshot-0"
        }
      }
    }' >"${batch_dir}/state.json"
}

create_batch_fixture batch-A agent:req_dispatcher:batch-a preparing
create_batch_fixture batch-B agent:req_dispatcher:batch-b attached
create_batch_fixture batch-R agent:req_dispatcher:batch-r attached

# batch-C is registered by the fake recorder only after importer released the
# scheduler lock. It models a late same-intent membership in the crash window.
mkdir -p "${SCHEDULER_ROOT}/batches/batch-C"
jq -cnS '{
  version:1,
  batch_id:"batch-C",
  correlation_id:"correlation-batch-C",
  project:"group/repo",
  selector:{type:"single",iid:42},
  force_rerun_pr:false,
  dispatcher_callback_target:"agent:req_dispatcher:batch-c",
  branch:"main"
}' >"${SCHEDULER_ROOT}/batches/batch-C/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
  >"${SCHEDULER_ROOT}/batches/batch-C/snapshot.json"
jq -cnS '{
  version:1,
  batch_id:"batch-C",
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
}' >"${SCHEDULER_ROOT}/batches/batch-C/state.json"

jq -cnS '{
  version:1,
  round_robin_cursor:"batch-B",
  batch_order:["batch-A","batch-B"],
  active_jobs:{
    "batch-A:snapshot-0":{
      job_id:"batch-A:snapshot-0",
      physical_key:"group/repo#42",
      project:"group/repo",
      iid:42,
      branch:"main",
      entry_mode:"auto",
      force_rerun_pr:false,
      status:"preparing",
      reservation_seq:1,
      claim_generation:1,
      claim_token:"claim-token-42",
      reserved_at:100,
      updated_at:101,
      owner:{batch_id:"batch-A",snapshot_index:0},
      memberships:[
        {batch_id:"batch-A",snapshot_index:0},
        {batch_id:"batch-B",snapshot_index:0}
      ]
    }
  }
}' >"${SCHEDULER_ROOT}/scheduler_state.json"

PHYSICAL_EVENT_ID='batch-A:snapshot-0:claim-1:terminal-1'
EVENT_A='batch-A:snapshot-0:terminal-1'
EVENT_B='batch-B:snapshot-0:terminal-1'
EVENT_R='batch-R:snapshot-0:terminal-1'
HANDOFF_FILE="${TEST_ROOT}/driven-handoff.json"
RECEIPT_FILE="${SCHEDULER_ROOT}/callback_inbox/${PHYSICAL_EVENT_ID}.json"
OUTBOX_A="${SCHEDULER_ROOT}/callback_outbox/${EVENT_A}.json"
OUTBOX_B="${SCHEDULER_ROOT}/callback_outbox/${EVENT_B}.json"
OUTBOX_R="${SCHEDULER_ROOT}/callback_outbox/${EVENT_R}.json"
RECORD_LOG="${TEST_ROOT}/record.log"

jq -cnS \
  --arg event_id "${PHYSICAL_EVENT_ID}" \
  --arg mr_url 'https://gitlab.example/group/repo/-/merge_requests/9' '{
    version:1,
    event_id:$event_id,
    job_id:"batch-A:snapshot-0",
    memberships:[],
    memberships_source:"scheduler_active_job",
    claim_generation:1,
    claim_token:"claim-token-42",
    project:"group/repo",
    iid:42,
    status:"done",
    mr_url:$mr_url,
    reason:null
  }' >"${HANDOFF_FILE}"

# A callback from claim 1 must not borrow claim 2 from scheduler state. Restore
# the valid claim only after proving the stale handoff leaves no durable trace.
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-before-stale-claim.json"
jq '
  .active_jobs["batch-A:snapshot-0"].claim_generation = 2
  | .active_jobs["batch-A:snapshot-0"].claim_token = "claim-token-43"
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.claim-2.json"
mv "${SCHEDULER_ROOT}/scheduler_state.claim-2.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${HANDOFF_FILE}" \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/stale-claim.out" \
  2>"${TEST_ROOT}/stale-claim.err"; then
  fail "claim-1 handoff borrowed the current claim-2 scheduler identity"
fi
[ ! -e "${RECEIPT_FILE}" ] \
  || fail "stale claim created an import receipt"
[ ! -e "${OUTBOX_A}" ] && [ ! -e "${OUTBOX_B}" ] \
  || fail "stale claim created public outbox entries"
jq -e '.active_jobs["batch-A:snapshot-0"] | has("finalization") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "stale claim installed a finalization fence"
cp "${TEST_ROOT}/scheduler-before-stale-claim.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-before-expired-claim.json"
jq '
  .active_jobs["batch-A:snapshot-0"].status = "preparing"
  | .active_jobs["batch-A:snapshot-0"].updated_at = 1
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.expired-claim.json"
mv "${SCHEDULER_ROOT}/scheduler_state.expired-claim.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${HANDOFF_FILE}" \
  NOW_EPOCH=5000 DRIVEN_PREPARING_LEASE_SECONDS=10 \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/expired-claim.out" \
  2>"${TEST_ROOT}/expired-claim.err"; then
  fail "expired preparing claim was imported"
fi
[ ! -e "${RECEIPT_FILE}" ] \
  || fail "expired preparing claim created an import receipt"
[ ! -e "${OUTBOX_A}" ] && [ ! -e "${OUTBOX_B}" ] \
  || fail "expired preparing claim created public outbox entries"
jq -e '.active_jobs["batch-A:snapshot-0"] | has("finalization") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "expired preparing claim installed a finalization fence"
cp "${TEST_ROOT}/scheduler-before-expired-claim.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

# Deterministically model a scheduler writer committing after the importer's
# first migration-only call but before it acquires scheduler.lock. The nested
# transaction adds batch-R to the physical job, so reading the stale outer
# state would both lose the finalization marker during recovery and omit fanout.
MIGRATION_WRAPPER="${TEST_ROOT}/migration-wrapper.sh"
MIGRATION_INJECTED="${TEST_ROOT}/migration-injected"
MIGRATION_CALL_LOG="${TEST_ROOT}/migration-calls.log"
cat >"${MIGRATION_WRAPPER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec 8>"${EXPECT_SCHEDULER_LOCK:?}"
if ! flock -n 8; then
  echo "migration-only was called while importer held scheduler.lock" >&2
  exit 88
fi
flock -u 8
exec 8>&-

printf '%s\n' called >>"${MIGRATION_CALL_LOG:?}"
CONFIG_DIR="${CONFIG_DIR:?}" \
NOW_EPOCH="${NOW_EPOCH:-0}" \
DRIVEN_PREPARING_LEASE_SECONDS="${DRIVEN_PREPARING_LEASE_SECONDS:-1800}" \
DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
bash "${ACTUAL_MIGRATION:?}" >/dev/null

if [ "${MIGRATION_ALWAYS_INJECT:-false}" = true ] \
    || [ ! -e "${MIGRATION_INJECTED:?}" ]; then
  exec 8>"${EXPECT_SCHEDULER_LOCK}"
  flock -x 8
  jq \
    --arg job_id 'batch-A:snapshot-0' \
    --slurpfile batch_r_state "${BATCH_R_STATE:?}" '
    . as $persisted
    | .pending_transaction = {
        version:1,
        scheduler_state:($persisted
          | del(.pending_transaction)
          | if (.batch_order | index("batch-R")) == null
            then .batch_order += ["batch-R"] else . end
          | if ([.active_jobs[$job_id].memberships[]
              | select(.batch_id == "batch-R" and .snapshot_index == 0)]
              | length) == 0
            then .active_jobs[$job_id].memberships += [{
                batch_id:"batch-R",
                snapshot_index:0
              }]
            else . end),
        batch_states:{"batch-R":$batch_r_state[0]}
      }
  ' "${EXPECT_SCHEDULER_STATE:?}" \
    >"${EXPECT_SCHEDULER_STATE}.pending-race"
  mv "${EXPECT_SCHEDULER_STATE}.pending-race" "${EXPECT_SCHEDULER_STATE}"
  printf '%s\n' injected >"${MIGRATION_INJECTED}"
  flock -u 8
  exec 8>&-
fi
EOF
chmod +x "${MIGRATION_WRAPPER}"

# A continuously competing writer must not turn the recovery loop into an
# unbounded wait or allow an outer-state marker. After the fixed retry budget,
# importer fails closed before receipt/outbox persistence.
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/scheduler-before-recovery-exhaustion.json"
MIGRATION_EXHAUST_LOG="${TEST_ROOT}/migration-exhaust-calls.log"
set +e
CONFIG_DIR="${CONFIG_DIR}" \
HANDOFF_FILE="${HANDOFF_FILE}" \
DRIVEN_MIGRATION_SCRIPT="${MIGRATION_WRAPPER}" \
ACTUAL_MIGRATION="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
EXPECT_SCHEDULER_STATE="${SCHEDULER_ROOT}/scheduler_state.json" \
BATCH_R_STATE="${SCHEDULER_ROOT}/batches/batch-R/state.json" \
MIGRATION_INJECTED="${TEST_ROOT}/migration-exhaust-injected" \
MIGRATION_CALL_LOG="${MIGRATION_EXHAUST_LOG}" \
MIGRATION_ALWAYS_INJECT=true \
NOW_EPOCH=102 \
DRIVEN_PREPARING_LEASE_SECONDS=10 \
bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/migration-exhaust.out" \
  2>"${TEST_ROOT}/migration-exhaust.err"
MIGRATION_EXHAUST_RC=$?
set -e
[ "${MIGRATION_EXHAUST_RC}" -eq 3 ] \
  || fail "transaction recovery retry exhaustion did not exit 3"
grep -q 'transaction recovery retry limit exhausted' \
  "${TEST_ROOT}/migration-exhaust.err" \
  || fail "transaction recovery exhaustion did not fail closed explicitly"
[ "$(wc -l <"${MIGRATION_EXHAUST_LOG}" | tr -d ' ')" = 4 ] \
  || fail "transaction recovery did not enforce its fixed retry budget"
[ ! -e "${RECEIPT_FILE}" ] \
  && [ ! -e "${OUTBOX_A}" ] \
  && [ ! -e "${OUTBOX_B}" ] \
  && [ ! -e "${OUTBOX_R}" ] \
  || fail "retry exhaustion persisted callback delivery state"
jq -e '
  has("pending_transaction")
  and (.active_jobs["batch-A:snapshot-0"] | has("finalization") | not)
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "retry exhaustion installed a fence into the outer scheduler state"
cp "${TEST_ROOT}/scheduler-before-recovery-exhaustion.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

FAKE_RECORD="${TEST_ROOT}/fake-record.sh"
cat >"${FAKE_RECORD}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec 8>"${EXPECT_SCHEDULER_LOCK:?}"
if ! flock -n 8; then
  echo "record was called while scheduler lock was held" >&2
  exit 90
fi
flock -u 8
exec 8>&-

CONFIG_DIR="${CONFIG_DIR:?}" \
NOW_EPOCH="${NOW_EPOCH:-0}" \
DRIVEN_PREPARING_LEASE_SECONDS="${DRIVEN_PREPARING_LEASE_SECONDS:-1800}" \
DRIVEN_SCHEDULER_MIGRATION_ONLY=1 \
bash "${PRE_RECORD_MIGRATION_SCRIPT:?}" >/dev/null

for required_file in \
  "${EXPECT_RECEIPT:?}" \
  "${EXPECT_OUTBOX_A:?}" \
  "${EXPECT_OUTBOX_B:?}" \
  "${EXPECT_OUTBOX_R:?}"
do
  [ -f "${required_file}" ] || {
    echo "record ran before durable callback file: ${required_file}" >&2
    exit 91
  }
done

jq -e \
  --arg job_id "${JOB_ID:-}" \
  --arg event_id "${FINALIZATION_EVENT_ID:-}" '
  .active_jobs[$job_id].finalization.event_id == $event_id
  and .active_jobs[$job_id].finalization.claim_generation == 1
  and .active_jobs[$job_id].finalization.claim_token == "claim-token-42"
  and .active_jobs[$job_id].finalization.membership_keys == [
    "batch-A:snapshot-0",
    "batch-B:snapshot-0",
    "batch-R:snapshot-0"
  ]
' "${EXPECT_SCHEDULER_STATE:?}" >/dev/null || {
  echo "record ran without a complete finalization fence" >&2
  exit 92
}
if [ ! -e "${INJECT_FENCE_ONCE_FILE:?}" ]; then
  exec 8>"${EXPECT_SCHEDULER_LOCK}"
  flock -x 8
  jq '
    if (.batch_order | index("batch-C")) == null
    then .batch_order += ["batch-C"]
    else .
    end
  ' "${EXPECT_SCHEDULER_STATE}" \
    >"${EXPECT_SCHEDULER_STATE}.inject-next"
  mv "${EXPECT_SCHEDULER_STATE}.inject-next" "${EXPECT_SCHEDULER_STATE}"
  printf '%s\n' injected >"${INJECT_FENCE_ONCE_FILE}"
  flock -u 8
  exec 8>&-
  CONFIG_DIR="${CONFIG_DIR:?}" NOW_EPOCH=102 \
    bash "${RESERVE_SCRIPT:?}" >/dev/null
  jq -e --arg job_id "${JOB_ID:-}" '
    .memberships["0"].status == "pending"
    and .memberships["0"].blocked_by_job_id == $job_id
  ' "${BATCH_C_STATE:?}" >/dev/null || {
    echo "late membership escaped the finalization fence" >&2
    exit 93
  }
  jq -e --arg job_id "${JOB_ID:-}" '
    [.active_jobs[$job_id].memberships[].batch_id] == ["batch-A","batch-B","batch-R"]
  ' "${EXPECT_SCHEDULER_STATE}" >/dev/null || {
    echo "late membership changed the finalization snapshot" >&2
    exit 93
  }
fi
if [ "${FAKE_RECORD_MODE:-}" = fail_before_terminal ]; then
  exit 94
fi

jq -nc \
  --arg job_id "${JOB_ID:-}" \
  --arg status "${STATUS:-}" \
  --arg claim_token "${CLAIM_TOKEN:-}" \
  --arg finalization_event_id "${FINALIZATION_EVENT_ID:-}" \
  '{job_id:$job_id,status:$status,claim_token:$claim_token,
    finalization_event_id:$finalization_event_id}' \
  >>"${RECORD_LOG:?}"

exec env \
  CONFIG_DIR="${CONFIG_DIR:?}" \
  JOB_ID="${JOB_ID:-}" \
  STATUS="${STATUS:-}" \
  CLAIM_TOKEN="${CLAIM_TOKEN:-}" \
  FINALIZATION_EVENT_ID="${FINALIZATION_EVENT_ID:-}" \
  bash "${ACTUAL_RECORD:?}"
EOF
chmod +x "${FAKE_RECORD}"

set +e
CONFIG_DIR="${CONFIG_DIR}" \
HANDOFF_FILE="${HANDOFF_FILE}" \
DRIVEN_MIGRATION_SCRIPT="${MIGRATION_WRAPPER}" \
DRIVEN_RECORD_SCRIPT="${FAKE_RECORD}" \
ACTUAL_MIGRATION="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
ACTUAL_RECORD="${RECORD_LAUNCH}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
EXPECT_SCHEDULER_STATE="${SCHEDULER_ROOT}/scheduler_state.json" \
EXPECT_RECEIPT="${RECEIPT_FILE}" \
EXPECT_OUTBOX_A="${OUTBOX_A}" \
EXPECT_OUTBOX_B="${OUTBOX_B}" \
EXPECT_OUTBOX_R="${OUTBOX_R}" \
PRE_RECORD_MIGRATION_SCRIPT="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
BATCH_R_STATE="${SCHEDULER_ROOT}/batches/batch-R/state.json" \
MIGRATION_INJECTED="${MIGRATION_INJECTED}" \
MIGRATION_CALL_LOG="${MIGRATION_CALL_LOG}" \
RECORD_LOG="${RECORD_LOG}" \
INJECT_FENCE_ONCE_FILE="${TEST_ROOT}/fence-injected" \
RESERVE_SCRIPT="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
BATCH_C_STATE="${SCHEDULER_ROOT}/batches/batch-C/state.json" \
FAKE_RECORD_MODE=fail_before_terminal \
NOW_EPOCH=102 \
DRIVEN_PREPARING_LEASE_SECONDS=10 \
bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/import-record-failed.out" \
  2>"${TEST_ROOT}/import-record-failed.err"
FAILED_IMPORT_RC=$?
set -e
[ "${FAILED_IMPORT_RC}" -ne 0 ] \
  || fail "importer treated a failed terminal record as success"
MIGRATION_CALLS=0
if [ -f "${MIGRATION_CALL_LOG}" ]; then
  MIGRATION_CALLS="$(wc -l <"${MIGRATION_CALL_LOG}" | tr -d ' ')"
fi
[ "${MIGRATION_CALLS}" = 2 ] \
  || fail "importer did not recover a transaction injected after migration-only"
jq -e '
  has("terminal_recorded")
  and .terminal_recorded == false
  and [.memberships[].batch_id] == ["batch-A","batch-B","batch-R"]
' "${RECEIPT_FILE}" >/dev/null \
  || fail "failed terminal record did not leave a replayable false receipt gate"
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}" "${OUTBOX_R}"; do
  jq -e 'has("ready_at") and .ready_at == null' "${outbox_file}" >/dev/null \
    || fail "failed terminal record exposed an outbox entry for delivery"
done
jq -e '
  (has("pending_transaction") | not)
  and .active_jobs["batch-A:snapshot-0"].finalization.membership_keys == [
    "batch-A:snapshot-0",
    "batch-B:snapshot-0",
    "batch-R:snapshot-0"
  ]
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "finalization fence was not installed on recovered scheduler state"

NOT_READY_OPENCLAW_LOG="${TEST_ROOT}/not-ready-openclaw.log"
NOT_READY_OPENCLAW="${TEST_ROOT}/not-ready-openclaw.sh"
cat >"${NOT_READY_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called >>"${NOT_READY_OPENCLAW_LOG:?}"
exit 95
EOF
chmod +x "${NOT_READY_OPENCLAW}"
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${NOT_READY_OPENCLAW}" \
NOT_READY_OPENCLAW_LOG="${NOT_READY_OPENCLAW_LOG}" \
bash "${DRAIN_OUTBOX}" >/dev/null
[ ! -s "${NOT_READY_OPENCLAW_LOG}" ] \
  || fail "drain sent an outbox entry before terminal record completed"

# A crash may also leave an already-installed marker inside the transaction's
# nested scheduler state. Migration recovery must preserve that exact fence so
# the replay can satisfy the recorder's mandatory event contract.
jq '
  . as $persisted
  | .pending_transaction = {
      version:1,
      scheduler_state:($persisted | del(.pending_transaction)),
      batch_states:{}
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.nested-finalization"
mv "${SCHEDULER_ROOT}/scheduler_state.nested-finalization" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

IMPORT_OUTPUT="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  HANDOFF_FILE="${HANDOFF_FILE}" \
  DRIVEN_MIGRATION_SCRIPT="${MIGRATION_WRAPPER}" \
  DRIVEN_RECORD_SCRIPT="${FAKE_RECORD}" \
  ACTUAL_MIGRATION="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
  ACTUAL_RECORD="${RECORD_LAUNCH}" \
  EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
  EXPECT_SCHEDULER_STATE="${SCHEDULER_ROOT}/scheduler_state.json" \
  EXPECT_RECEIPT="${RECEIPT_FILE}" \
  EXPECT_OUTBOX_A="${OUTBOX_A}" \
  EXPECT_OUTBOX_B="${OUTBOX_B}" \
  EXPECT_OUTBOX_R="${OUTBOX_R}" \
  PRE_RECORD_MIGRATION_SCRIPT="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
  BATCH_R_STATE="${SCHEDULER_ROOT}/batches/batch-R/state.json" \
  MIGRATION_INJECTED="${MIGRATION_INJECTED}" \
  MIGRATION_CALL_LOG="${MIGRATION_CALL_LOG}" \
  RECORD_LOG="${RECORD_LOG}" \
  INJECT_FENCE_ONCE_FILE="${TEST_ROOT}/fence-injected" \
  RESERVE_SCRIPT="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
BATCH_C_STATE="${SCHEDULER_ROOT}/batches/batch-C/state.json" \
NOW_EPOCH=5000 \
DRIVEN_PREPARING_LEASE_SECONDS=10 \
bash "${IMPORT_HANDOFF}"
)"
[ "$(wc -l <"${MIGRATION_CALL_LOG}" | tr -d ' ')" = 3 ] \
  || fail "nested finalization transaction was not recovered before replay"
jq -e '
  .status == "imported"
  and .job_id == "batch-A:snapshot-0"
  and .outbox_count == 3
  and .terminal_recorded == true
' <<<"${IMPORT_OUTPUT}" >/dev/null \
  || fail "importer did not report a completed recovered-membership import"

[ -f "${RECEIPT_FILE}" ] || fail "import receipt was not persisted"
[ -f "${OUTBOX_A}" ] || fail "batch-A outbox entry was not persisted"
[ -f "${OUTBOX_B}" ] || fail "batch-B outbox entry was not persisted"
[ -f "${OUTBOX_R}" ] || fail "recovered batch-R outbox entry was not persisted"
jq -e '
  .event_id == "batch-A:snapshot-0:claim-1:terminal-1"
  and .job_id == "batch-A:snapshot-0"
  and [.memberships[] | {batch_id,snapshot_index,target}] == [
    {batch_id:"batch-A",snapshot_index:0,target:"agent:req_dispatcher:batch-a"},
    {batch_id:"batch-B",snapshot_index:0,target:"agent:req_dispatcher:batch-b"},
    {batch_id:"batch-R",snapshot_index:0,target:"agent:req_dispatcher:batch-r"}
  ]
  and .claim_generation == 1
  and .claim_token == "claim-token-42"
  and .terminal_recorded == true
  and .scheduler_status == "preparing"
' "${RECEIPT_FILE}" >/dev/null \
  || fail "receipt did not freeze the scheduler-locked membership resolution"

for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}" "${OUTBOX_R}"; do
  jq -e '
    .version == 1
    and (.target | startswith("agent:req_dispatcher:"))
    and .attempts == 0
    and (.ready_at | type == "number" and . >= 0)
    and .delivered_at == null
    and .last_error == null
    and (.body | keys | sort) == [
      "batch_id","event_id","iid","mr_url","project","reason","snapshot_index","status"
    ]
    and .body.project == "group/repo"
    and .body.iid == 42
    and .body.status == "done"
    and (.body | has("target") | not)
    and (.body | has("correlation_id") | not)
  ' "${outbox_file}" >/dev/null \
    || fail "outbox entry mixed internal delivery fields into its public body"
done
jq -e --arg event_id "${EVENT_A}" \
  '.event_id == $event_id and .body.event_id == $event_id and .body.batch_id == "batch-A"' \
  "${OUTBOX_A}" >/dev/null || fail "batch-A event identity is unstable"
jq -e --arg event_id "${EVENT_B}" \
  '.event_id == $event_id and .body.event_id == $event_id and .body.batch_id == "batch-B"' \
  "${OUTBOX_B}" >/dev/null || fail "batch-B event identity is unstable"
jq -e --arg event_id "${EVENT_R}" \
  '.event_id == $event_id and .body.event_id == $event_id and .body.batch_id == "batch-R"' \
  "${OUTBOX_R}" >/dev/null || fail "batch-R event identity is unstable"
jq -e '.active_jobs | has("batch-A:snapshot-0") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "scheduler job was not recorded terminal"
jq -e '.memberships["0"].status == "terminal"' \
  "${SCHEDULER_ROOT}/batches/batch-A/state.json" >/dev/null \
  || fail "owner membership was not recorded terminal"
jq -e '.memberships["0"].status == "terminal"' \
  "${SCHEDULER_ROOT}/batches/batch-B/state.json" >/dev/null \
  || fail "attached membership was not recorded terminal"
jq -e '.memberships["0"].status == "terminal"' \
  "${SCHEDULER_ROOT}/batches/batch-R/state.json" >/dev/null \
  || fail "recovered membership was not recorded terminal"
jq -e '
  length == 1
  and .[0].job_id == "batch-A:snapshot-0"
  and .[0].status == "terminal"
  and .[0].claim_token == "claim-token-42"
  and .[0].finalization_event_id == "batch-A:snapshot-0:claim-1:terminal-1"
' --slurp "${RECORD_LOG}" >/dev/null \
  || fail "terminal record did not carry the current claim token exactly once"

# Simulate a crash after record deleted active_jobs but before readiness was
# published. Replay must repair both gates from the durable receipt without
# recursively invoking record.
jq '.terminal_recorded = false' "${RECEIPT_FILE}" \
  >"${RECEIPT_FILE}.crash-window"
mv "${RECEIPT_FILE}.crash-window" "${RECEIPT_FILE}"
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}" "${OUTBOX_R}"; do
  jq '.ready_at = null' "${outbox_file}" >"${outbox_file}.crash-window"
  mv "${outbox_file}.crash-window" "${outbox_file}"
done
CONFIG_DIR="${CONFIG_DIR}" \
HANDOFF_FILE="${HANDOFF_FILE}" \
DRIVEN_RECORD_SCRIPT="${FAKE_RECORD}" \
ACTUAL_RECORD="${RECORD_LAUNCH}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
EXPECT_SCHEDULER_STATE="${SCHEDULER_ROOT}/scheduler_state.json" \
EXPECT_RECEIPT="${RECEIPT_FILE}" \
EXPECT_OUTBOX_A="${OUTBOX_A}" \
EXPECT_OUTBOX_B="${OUTBOX_B}" \
RECORD_LOG="${RECORD_LOG}" \
INJECT_FENCE_ONCE_FILE="${TEST_ROOT}/fence-injected" \
RESERVE_SCRIPT="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh" \
BATCH_C_STATE="${SCHEDULER_ROOT}/batches/batch-C/state.json" \
bash "${IMPORT_HANDOFF}" >/dev/null
[ "$(wc -l <"${RECORD_LOG}" | tr -d ' ')" = 1 ] \
  || fail "receipt replay recursively recorded an already-terminal job"
jq -e '.terminal_recorded == true' "${RECEIPT_FILE}" >/dev/null \
  || fail "active-missing receipt replay did not repair terminal_recorded"
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}" "${OUTBOX_R}"; do
  jq -e '(.ready_at | type == "number" and . >= 0)' \
    "${outbox_file}" >/dev/null \
    || fail "active-missing receipt replay did not repair outbox readiness"
done

cp "${RECEIPT_FILE}" "${TEST_ROOT}/receipt-before-invalid-migration-path.json"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${HANDOFF_FILE}" \
  DRIVEN_MIGRATION_SCRIPT='scripts/reserve_driven_batch_items.sh' \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/invalid-migration-path.out" \
  2>"${TEST_ROOT}/invalid-migration-path.err"; then
  fail "importer accepted a relative migration override"
fi
grep -q 'DRIVEN_MIGRATION_SCRIPT must be an absolute path' \
  "${TEST_ROOT}/invalid-migration-path.err" \
  || fail "invalid migration override did not fail strict validation"
cmp -s "${RECEIPT_FILE}" \
  "${TEST_ROOT}/receipt-before-invalid-migration-path.json" \
  || fail "invalid migration override changed durable receipt state"

CONFLICT_HANDOFF="${TEST_ROOT}/conflicting-handoff.json"
jq '.status = "failed" | .reason = "changed terminal body"' \
  "${HANDOFF_FILE}" >"${CONFLICT_HANDOFF}"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${CONFLICT_HANDOFF}" \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/conflict.out" 2>"${TEST_ROOT}/conflict.err"; then
  fail "same physical event with a different body did not fail closed"
fi

ORPHAN_HANDOFF="${TEST_ROOT}/orphan-handoff.json"
jq '.event_id = "orphan:snapshot-0:claim-1:terminal-1"
  | .job_id = "orphan:snapshot-0"' \
  "${HANDOFF_FILE}" >"${ORPHAN_HANDOFF}"
if CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${ORPHAN_HANDOFF}" \
  bash "${IMPORT_HANDOFF}" >"${TEST_ROOT}/orphan.out" 2>"${TEST_ROOT}/orphan.err"; then
  fail "missing scheduler job without a receipt was forged as success"
fi

# Delivery keeps failed entries durable, rejects a wrong accepted event, and
# retries with byte-identical public event bodies. The fake also proves that
# no scheduler lock is held during the network call.
OPENCLAW_LOG="${TEST_ROOT}/openclaw.jsonl"
OPENCLAW_BARRIER_DIR="${TEST_ROOT}/openclaw-barrier"
FAKE_OPENCLAW="${TEST_ROOT}/fake-openclaw.sh"
mkdir -p "${OPENCLAW_BARRIER_DIR}"
cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-key)
      shift
      target="${1:-}"
      ;;
    --message)
      shift
      message="${1:-}"
      ;;
  esac
  [ "$#" -gt 0 ] && shift
done

exec 8>"${EXPECT_SCHEDULER_LOCK:?}"
if ! flock -n 8; then
  echo "openclaw was called while scheduler lock was held" >&2
  exit 92
fi
flock -u 8
exec 8>&-

body="${message#*worker_result_json=}"
event_id="$(jq -er '.event_id' <<<"${body}")"
jq -nc \
  --arg event_id "${event_id}" \
  --arg target "${target}" \
  --argjson body "${body}" \
  '{event_id:$event_id,target:$target,body:$body}' \
  >>"${OPENCLAW_LOG:?}"
call_count="$(jq -sr --arg event_id "${event_id}" \
  '[.[] | select(.event_id == $event_id)] | length' "${OPENCLAW_LOG}")"

if [ "${call_count}" -eq 1 ] && [ "${event_id}" = "batch-A:snapshot-0:terminal-1" ]; then
  exit 23
fi
if [ "${call_count}" -eq 1 ] && [ "${event_id}" = "batch-B:snapshot-0:terminal-1" ]; then
  jq -nc '{status:"accepted",event_id:"wrong-event"}'
  exit 0
fi
if [ "${call_count}" -eq 2 ]; then
  printf '%s\n' ready >"${OPENCLAW_BARRIER_DIR:?}/${event_id}"
  barrier_ready=false
  for _barrier_attempt in {1..100}; do
    if [ -f "${OPENCLAW_BARRIER_DIR}/batch-A:snapshot-0:terminal-1" ] \
       && [ -f "${OPENCLAW_BARRIER_DIR}/batch-B:snapshot-0:terminal-1" ]; then
      barrier_ready=true
      break
    fi
    sleep 0.02
  done
  [ "${barrier_ready}" = true ] || exit 96
fi
jq -nc --arg event_id "${event_id}" '{status:"accepted",event_id:$event_id}'
EOF
chmod +x "${FAKE_OPENCLAW}"

CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >/dev/null
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}"; do
  jq -e '
    .attempts == 1
    and .delivered_at == null
    and (.last_error | type == "string" and length > 0)
  ' "${outbox_file}" >/dev/null \
    || fail "failed or wrong-ack delivery was not retained for retry"
done

CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/drain-a.out" &
DRAIN_PID_A=$!
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/drain-b.out" &
DRAIN_PID_B=$!
wait "${DRAIN_PID_A}"
wait "${DRAIN_PID_B}"

for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}"; do
  jq -e '
    .attempts == 2
    and (.delivered_at | type == "number" and . >= 0)
    and .last_error == null
  ' "${outbox_file}" >/dev/null \
    || fail "accepted matching ack did not atomically mark delivery"
done
[ -f "${OUTBOX_A}" ] && [ -f "${OUTBOX_B}" ] \
  || fail "drain deleted durable outbox evidence"
jq -se \
  --arg event_a "${EVENT_A}" \
  --arg event_b "${EVENT_B}" '
  def bodies($event): [.[] | select(.event_id == $event) | (.body | @json)];
  ((bodies($event_a) | length) == 2 and (bodies($event_a) | unique | length) == 1)
  and ((bodies($event_b) | length) == 2 and (bodies($event_b) | unique | length) == 1)
' "${OPENCLAW_LOG}" >/dev/null \
  || fail "drain changed the public event body across retries or duplicated a concurrent send"

INVALID_OUTBOX="${SCHEDULER_ROOT}/callback_outbox/not-the-event.json"
jq '
  .attempts = 0
  | .last_error = null
  | .delivered_at = null
' "${OUTBOX_A}" >"${INVALID_OUTBOX}"
cp "${INVALID_OUTBOX}" "${TEST_ROOT}/invalid-outbox-before-drain.json"
OPENCLAW_CALLS_BEFORE_INVALID="$(wc -l <"${OPENCLAW_LOG}" | tr -d ' ')"
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >/dev/null 2>"${TEST_ROOT}/invalid-outbox.err"
cmp -s "${INVALID_OUTBOX}" "${TEST_ROOT}/invalid-outbox-before-drain.json" \
  || fail "invalid filename/event identity was mutated by drain"
[ "$(wc -l <"${OPENCLAW_LOG}" | tr -d ' ')" = "${OPENCLAW_CALLS_BEFORE_INVALID}" ] \
  || fail "invalid filename/event identity reached OpenClaw"

# Run the real followup wrapper in a small project fixture. Its importer exits
# non-zero deliberately after proving the campaign lock is available and both
# campaign state and handoff are durable.
FOLLOWUP_ROOT="${TEST_ROOT}/followup"
FOLLOWUP_PARENT="${FOLLOWUP_ROOT}/repos"
FOLLOWUP_REPO="${FOLLOWUP_PARENT}/repo"
FOLLOWUP_SCRIPTS="${FOLLOWUP_ROOT}/scripts"
FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_ROOT}/notify.log"
FOLLOWUP_IMPORT_LOG="${FOLLOWUP_ROOT}/import.log"
mkdir -p \
  "${FOLLOWUP_REPO}/.git" \
  "${FOLLOWUP_SCRIPTS}" \
  "${FOLLOWUP_REPO}/.req_executor/_dispatcher/log" \
  "${FOLLOWUP_REPO}/.req_executor/issues/issue-42"
cp \
  "${SKILL_DIR}/scripts/dispatch_followup.sh" \
  "${SKILL_DIR}/scripts/_dispatch_lib.sh" \
  "${SKILL_DIR}/scripts/env_paths.sh" \
  "${FOLLOWUP_SCRIPTS}/"

cat >"${FOLLOWUP_SCRIPTS}/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
evidence="${DISPATCHER_LOG_DIR}/reconcile-20260711T000000Z.json"
jq -cn --argjson iid "${MIN_IID:?}" '[{
  iid:$iid,
  is_closed_on_gitlab:false,
  is_done_on_gitlab:false,
  has_done_pr:false
}]' >"${evidence}"
printf '%s\n' "${evidence}"
EOF
cat >"${FOLLOWUP_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FOLLOWUP_SCRIPTS}/notify_dispatcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called >>"${FOLLOWUP_NOTIFY_LOG:?}"
exit 0
EOF
cat >"${FOLLOWUP_SCRIPTS}/post_result_note.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FOLLOWUP_SCRIPTS}"/*.sh

FOLLOWUP_STATE="${FOLLOWUP_REPO}/.req_executor/_dispatcher/campaign_state.json"
FOLLOWUP_LOCK="${FOLLOWUP_REPO}/.req_executor/_dispatcher/campaign.lock"
jq -cnS '{
  project:"repo",
  repo_path:"unused",
  blocked_retry_limit:3,
  tick_seq:1,
  result_note_enabled:false,
  kill_subagent_on_terminal:false,
  pending_subagents:{
    "42":{
      attempt_number:1,
      run_id:"run-42",
      child_session_key:"agent:req_executor:subagent:42",
      spawned_at:"2026-07-11T00:00:00Z",
      placeholder:false,
      acpx_timeout_seconds:18000,
      job_id:"batch-A:snapshot-0",
      batch_id:"batch-A",
      snapshot_index:0,
      branch:"main",
      entry_mode:"auto",
      force_rerun_pr:false,
      memberships_source:"scheduler_active_job",
      claim_generation:1,
      claim_token:"claim-token-42",
      bound_at:"2026-07-11T00:01:00Z"
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
  campaign_status:"waiting_for_callbacks"
}' >"${FOLLOWUP_STATE}"

FAKE_IMPORTER="${FOLLOWUP_ROOT}/fake-importer.sh"
cat >"${FAKE_IMPORTER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec 8>"${EXPECT_CAMPAIGN_LOCK:?}"
if ! flock -n 8; then
  echo "importer observed the campaign lock held" >&2
  exit 93
fi
flock -u 8
exec 8>&-

jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
' "${EXPECT_CAMPAIGN_STATE:?}" >/dev/null
jq -e '
  .event_id == "batch-A:snapshot-0:claim-1:terminal-1"
  and .job_id == "batch-A:snapshot-0"
  and .memberships == []
  and .memberships_source == "scheduler_active_job"
  and .claim_generation == 1
  and .claim_token == "claim-token-42"
  and .project == "group/repo"
  and .iid == 42
  and .status == "done"
' "${HANDOFF_FILE:?}" >/dev/null
printf '%s\n' "${HANDOFF_FILE}" >>"${FOLLOWUP_IMPORT_LOG:?}"
exit 47
EOF
chmod +x "${FAKE_IMPORTER}"

FOLLOWUP_OUTPUT="$(
  printf '%s\n' '{
    "iid":42,
    "attempt_number":1,
    "status":"done",
    "merge_request_url":"https://gitlab.example/group/repo/-/merge_requests/9"
  }' | \
  PROJECT=repo \
  PROJECT_FULL=group/repo \
  GROUP=group \
  GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example \
  GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" \
  IID=42 \
  ATTEMPT_NUMBER=1 \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh"
)"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .handoff_import_status == "pending"
  and (.handoff_path | type == "string" and length > 0)
' <<<"${FOLLOWUP_OUTPUT}" >/dev/null \
  || fail "followup did not expose the non-fatal pending handoff import"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 1 ] \
  || fail "followup did not call the importer exactly once"
FOLLOWUP_HANDOFF="$(cat "${FOLLOWUP_IMPORT_LOG}")"
[ -f "${FOLLOWUP_HANDOFF}" ] || fail "followup rolled back its handoff after import failure"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "import failure rolled back completed Phase 6 state"
[ ! -s "${FOLLOWUP_NOTIFY_LOG}" ] \
  || fail "scheduler-driven followup still called notify_dispatcher directly"
grep -Fq 'handoff import pending' \
  "${FOLLOWUP_REPO}/.req_executor/_dispatcher/log/wrapper.log" \
  || fail "followup log did not retain the pending import reason"
exec 8>"${FOLLOWUP_LOCK}"
flock -n 8 || fail "followup left the campaign lock held"
flock -u 8
exec 8>&-

echo "ok driven callback outbox"
