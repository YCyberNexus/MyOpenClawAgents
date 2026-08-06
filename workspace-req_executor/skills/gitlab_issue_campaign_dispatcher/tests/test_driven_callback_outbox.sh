#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMPORT_HANDOFF="${SKILL_DIR}/scripts/import_driven_handoff.sh"
DRAIN_OUTBOX="${SKILL_DIR}/scripts/drain_driven_outbox.sh"
BIND_CLAIM="${SKILL_DIR}/scripts/bind_driven_claim.sh"
RECORD_LAUNCH="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"
RESERVE_ITEMS="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'
export OPENCLAW_STRICT_JSON_RECEIPT=0

fail() {
  echo "test_driven_callback_outbox.sh: $*" >&2
  exit 1
}

test_sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

[ -x "${IMPORT_HANDOFF}" ] || fail "import_driven_handoff.sh is missing or not executable"
[ -x "${DRAIN_OUTBOX}" ] || fail "drain_driven_outbox.sh is missing or not executable"
[ -x "${BIND_CLAIM}" ] || fail "bind_driven_claim.sh is missing or not executable"
[ -x "${RESERVE_ITEMS}" ] || fail "reserve_driven_batch_items.sh is missing or not executable"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-driven-callback.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_ACCEPTANCE="${TEST_ROOT}/fake-acceptance.sh"
export CONFIG_DIR
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  'EXECUTOR_AGENT=req_executor' \
  'DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main' \
  'DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
cat >"${FAKE_ACCEPTANCE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${BATCH_ID:?}"
jq -cn --arg batch_id "${BATCH_ID}" '{
  status:"success",
  batch_id:$batch_id,
  matched_count:1,
  snapshot_digest:("c" * 64),
  scheduler_status:"completed"
}'
EOF
chmod +x "${FAKE_ACCEPTANCE}"
export DRIVEN_ACCEPTANCE_CMD="${FAKE_ACCEPTANCE}"

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
      execution_id:1,
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
      executor_agent:"req_executor",
      callback_nonce:("a" * 64),
      branch:"main"
    }' >"${batch_dir}/request.json"
  jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg membership_status "${membership_status}" '{
      version:1,
      terminal_counts_version:1,
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

create_batch_fixture batch-A agent:req_dispatcher:main preparing
create_batch_fixture batch-B agent:req_dispatcher:main attached
create_batch_fixture batch-R agent:req_dispatcher:main attached

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
  dispatcher_callback_target:"agent:req_dispatcher:main",
  executor_agent:"req_executor",
  callback_nonce:("b" * 64),
  branch:"main"
}' >"${SCHEDULER_ROOT}/batches/batch-C/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
  >"${SCHEDULER_ROOT}/batches/batch-C/snapshot.json"
jq -cnS '{
  version:1,
  terminal_counts_version:1,
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
  --arg terminal_status "${TERMINAL_STATUS:-}" \
  --arg claim_token "${CLAIM_TOKEN:-}" \
  --arg finalization_event_id "${FINALIZATION_EVENT_ID:-}" \
  '{job_id:$job_id,status:$status,terminal_status:$terminal_status,claim_token:$claim_token,
    finalization_event_id:$finalization_event_id}' \
  >>"${RECORD_LOG:?}"

exec env \
  CONFIG_DIR="${CONFIG_DIR:?}" \
  JOB_ID="${JOB_ID:-}" \
  STATUS="${STATUS:-}" \
  TERMINAL_STATUS="${TERMINAL_STATUS:-}" \
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
    {batch_id:"batch-A",snapshot_index:0,target:"agent:req_dispatcher:main"},
    {batch_id:"batch-B",snapshot_index:0,target:"agent:req_dispatcher:main"},
    {batch_id:"batch-R",snapshot_index:0,target:"agent:req_dispatcher:main"}
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
    and .target == "agent:req_dispatcher:main"
    and .executor_agent == "req_executor"
    and (.callback_nonce | test("^[0-9a-f]{64}$"))
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
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' \
  "${SCHEDULER_ROOT}/batches/batch-A/state.json" >/dev/null \
  || fail "owner membership was not recorded terminal"
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' \
  "${SCHEDULER_ROOT}/batches/batch-B/state.json" >/dev/null \
  || fail "attached membership was not recorded terminal"
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "terminal"
  and .memberships["0"].terminal_status == "done"
' \
  "${SCHEDULER_ROOT}/batches/batch-R/state.json" >/dev/null \
  || fail "recovered membership was not recorded terminal"
jq -e '
  length == 1
  and .[0].job_id == "batch-A:snapshot-0"
  and .[0].status == "terminal"
  and .[0].terminal_status == "done"
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

# A callback transport may occupy its full network timeout, but it must not
# hold the per-event lock for that duration. Otherwise an importer replay takes
# scheduler.lock and waits on that event lock, transitively blocking every new
# reservation. The durable delivery-attempt fence also prevents a second
# drainer from sending the same event while the first transport is in flight.
LEASE_FIXTURE_DIR="${TEST_ROOT}/delivery-lease-fixture"
LEASE_OPENCLAW="${TEST_ROOT}/lease-openclaw.sh"
LEASE_SEND_LOG="${TEST_ROOT}/lease-send.log"
LEASE_NETWORK_STARTED="${TEST_ROOT}/lease-network-started"
LEASE_NETWORK_RELEASE="${TEST_ROOT}/lease-network-release"
LEASE_IMPORT_RC_FILE="${TEST_ROOT}/lease-import.rc"
LEASE_RESERVE_RC_FILE="${TEST_ROOT}/lease-reserve.rc"
mkdir -p "${LEASE_FIXTURE_DIR}"
cp "${OUTBOX_A}" "${LEASE_FIXTURE_DIR}/outbox-a.json"
cp "${OUTBOX_B}" "${LEASE_FIXTURE_DIR}/outbox-b.json"
cp "${OUTBOX_R}" "${LEASE_FIXTURE_DIR}/outbox-r.json"
for deferred_outbox in "${OUTBOX_B}" "${OUTBOX_R}"; do
  jq '.next_attempt_at = 2100000000' "${deferred_outbox}" \
    >"${deferred_outbox}.lease-test"
  mv "${deferred_outbox}.lease-test" "${deferred_outbox}"
done
: >"${LEASE_SEND_LOG}"
cat >"${LEASE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
message=""
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --message) shift; message="${1:-}" ;;
    --message-file) shift; message_file="${1:-}" ;;
  esac
  [ "$#" -gt 0 ] && shift
done
if [ -n "${message_file}" ]; then
  [ "${message_file}" = /dev/stdin ]
  message="$(cat)"
fi
envelope="${message#*callback_envelope=}"
envelope="${envelope%%$'\n'*}"
event_id="$(jq -er '.worker_result_json.event_id' <<<"${envelope}")"
printf '%s\n' "${event_id}" >>"${LEASE_SEND_LOG:?}"
[ "${event_id}" = "${LEASE_EVENT_ID:?}" ] || exit 94
: >"${LEASE_NETWORK_STARTED:?}"
for _wait in $(seq 1 500); do
  [ -e "${LEASE_NETWORK_RELEASE:?}" ] && exit 23
  sleep 0.01
done
exit 95
EOF
chmod +x "${LEASE_OPENCLAW}"

CONFIG_DIR="${CONFIG_DIR}" OPENCLAW_BIN="${LEASE_OPENCLAW}" \
LEASE_SEND_LOG="${LEASE_SEND_LOG}" LEASE_EVENT_ID="${EVENT_A}" \
LEASE_NETWORK_STARTED="${LEASE_NETWORK_STARTED}" \
LEASE_NETWORK_RELEASE="${LEASE_NETWORK_RELEASE}" \
NOW_EPOCH=1999999000 DRIVEN_CALLBACK_TIMEOUT_SECONDS=5 \
DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK=1 \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/lease-drain-first.out" &
LEASE_DRAIN_PID=$!
for _wait in $(seq 1 300); do
  [ -e "${LEASE_NETWORK_STARTED}" ] && break
  sleep 0.01
done
[ -e "${LEASE_NETWORK_STARTED}" ] || {
  : >"${LEASE_NETWORK_RELEASE}"
  wait "${LEASE_DRAIN_PID}" || true
  fail "blocking callback transport did not start"
}

lease_second_drain="$(CONFIG_DIR="${CONFIG_DIR}" \
  OPENCLAW_BIN="${LEASE_OPENCLAW}" LEASE_SEND_LOG="${LEASE_SEND_LOG}" \
  LEASE_EVENT_ID="${EVENT_A}" LEASE_NETWORK_STARTED="${LEASE_NETWORK_STARTED}" \
  LEASE_NETWORK_RELEASE="${LEASE_NETWORK_RELEASE}" \
  NOW_EPOCH=1999999000 DRIVEN_CALLBACK_TIMEOUT_SECONDS=5 \
  DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK=1 bash "${DRAIN_OUTBOX}")"
jq -e '.attempted == 0' <<<"${lease_second_drain}" >/dev/null \
  || fail "concurrent drainer ignored the active delivery-attempt fence"
[ "$(grep -Fxc "${EVENT_A}" "${LEASE_SEND_LOG}")" = 1 ] \
  || fail "active delivery attempt was sent more than once"

(
  set +e
  CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${HANDOFF_FILE}" \
    NOW_EPOCH=1999999001 bash "${IMPORT_HANDOFF}" \
    >"${TEST_ROOT}/lease-import.out" 2>"${TEST_ROOT}/lease-import.err"
  printf '%s\n' "$?" >"${LEASE_IMPORT_RC_FILE}"
) &
LEASE_IMPORT_PID=$!

# Wait until the importer either finishes (new lock discipline) or is observed
# holding scheduler.lock while blocked on the old cross-network event lock.
LEASE_IMPORT_OBSERVED=false
exec 9>"${SCHEDULER_ROOT}/scheduler.lock"
for _wait in $(seq 1 300); do
  if [ -e "${LEASE_IMPORT_RC_FILE}" ]; then
    LEASE_IMPORT_OBSERVED=true
    break
  fi
  if ! flock -n 9; then
    LEASE_IMPORT_OBSERVED=true
    break
  fi
  flock -u 9
  sleep 0.01
done
exec 9>&-
[ "${LEASE_IMPORT_OBSERVED}" = true ] || {
  : >"${LEASE_NETWORK_RELEASE}"
  wait "${LEASE_DRAIN_PID}" || true
  wait "${LEASE_IMPORT_PID}" || true
  fail "import replay neither progressed nor reached its scheduler critical section"
}

(
  set +e
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=1999999002 \
    bash "${RESERVE_ITEMS}" >"${TEST_ROOT}/lease-reserve.out" \
    2>"${TEST_ROOT}/lease-reserve.err"
  printf '%s\n' "$?" >"${LEASE_RESERVE_RC_FILE}"
) &
LEASE_RESERVE_PID=$!
LEASE_RESERVATION_FINISHED=false
for _wait in $(seq 1 150); do
  if [ -e "${LEASE_RESERVE_RC_FILE}" ]; then
    LEASE_RESERVATION_FINISHED=true
    break
  fi
  sleep 0.01
done

: >"${LEASE_NETWORK_RELEASE}"
set +e
wait "${LEASE_DRAIN_PID}"
LEASE_DRAIN_RC=$?
wait "${LEASE_IMPORT_PID}"
LEASE_IMPORT_WAIT_RC=$?
wait "${LEASE_RESERVE_PID}"
LEASE_RESERVE_WAIT_RC=$?
set -e
[ "${LEASE_DRAIN_RC}" -eq 0 ] || fail "lease drain wrapper failed"
[ "${LEASE_IMPORT_WAIT_RC}" -eq 0 ] \
  && [ "$(cat "${LEASE_IMPORT_RC_FILE}")" -eq 0 ] \
  || fail "import replay failed around an in-flight callback"
[ "${LEASE_RESERVE_WAIT_RC}" -eq 0 ] \
  && [ "$(cat "${LEASE_RESERVE_RC_FILE}")" -eq 0 ] \
  || fail "reservation command failed around an in-flight callback"
[ "${LEASE_RESERVATION_FINISHED}" = true ] \
  || fail "reservation was transitively blocked by the callback network call"
[ "$(grep -Fxc "${EVENT_A}" "${LEASE_SEND_LOG}")" = 1 ] \
  || fail "delivery-attempt fencing duplicated or lost the in-flight event"
jq -e '.attempts == 1 and (has("delivery_attempt") | not)' \
  "${OUTBOX_A}" >/dev/null \
  || fail "completed delivery attempt did not clear its durable fence"
cp "${LEASE_FIXTURE_DIR}/outbox-a.json" "${OUTBOX_A}"
cp "${LEASE_FIXTURE_DIR}/outbox-b.json" "${OUTBOX_B}"
cp "${LEASE_FIXTURE_DIR}/outbox-r.json" "${OUTBOX_R}"

# Delivery keeps failed entries durable, rejects a wrong accepted event and an
# unsupported same-event status, and accepts a same-event duplicate after the
# dispatcher committed the first attempt but its acknowledgement was lost.
# Retries keep byte-identical public event bodies. The fake also proves that no
# scheduler lock is held during the network call and that GitLab credentials
# remain available to the callback transport process.
OPENCLAW_LOG="${TEST_ROOT}/openclaw.jsonl"
OPENCLAW_ARGV_LOG="${TEST_ROOT}/openclaw.argv"
OPENCLAW_BARRIER_DIR="${TEST_ROOT}/openclaw-barrier"
FAKE_OPENCLAW="${TEST_ROOT}/fake-openclaw.sh"
mkdir -p "${OPENCLAW_BARRIER_DIR}"
cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

token_env_present=true
for secret_name in \
  GITLAB_TOKEN \
  GLAB_TOKEN \
  GITLAB_PRIVATE_TOKEN \
  PRIVATE_TOKEN \
  WIKI_GITLAB_TOKEN
do
  secret_value="${!secret_name-}"
  [ -n "${secret_value}" ] || token_env_present=false
done

target=""
message=""
message_file=""
if [ -n "${OPENCLAW_ARGV_LOG:-}" ]; then
  printf '%s\n' '---' "$@" >>"${OPENCLAW_ARGV_LOG}"
fi
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
    --message-file)
      shift
      message_file="${1:-}"
      ;;
  esac
  [ "$#" -gt 0 ] && shift
done
if [ -n "${message_file}" ]; then
  [ "${message_file}" = /dev/stdin ]
  message="$(cat)"
fi
ACK_ONLY_INSTRUCTION='ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。'
[[ "${message}" == RUN_DRIVEN_BATCH_RESULT_ACK_ONLY$'\n'callback_envelope=*$'\n'"${ACK_ONLY_INSTRUCTION}" ]]

exec 8>"${EXPECT_SCHEDULER_LOCK:?}"
if ! flock -n 8; then
  echo "openclaw was called while scheduler lock was held" >&2
  exit 92
fi
flock -u 8
exec 8>&-

envelope="${message#*callback_envelope=}"
envelope="${envelope%%$'\n'*}"
jq -e '
  (keys | sort) == [
    "batch_acceptance","callback_nonce","executor_agent","worker_result_json"
  ]
  and (.callback_nonce | test("^[0-9a-f]{64}$"))
  and .executor_agent == "req_executor"
  and (.batch_acceptance | keys | sort) == [
    "batch_id","matched_count","scheduler_status","snapshot_digest","status"
  ]
  and .batch_acceptance.status == "success"
  and .batch_acceptance.batch_id == .worker_result_json.batch_id
  and .batch_acceptance.matched_count > .worker_result_json.snapshot_index
  and (.batch_acceptance.snapshot_digest | test("^[0-9a-f]{64}$"))
  and .batch_acceptance.scheduler_status == "completed"
  and (.worker_result_json | keys | sort) == [
    "batch_id","event_id","iid","mr_url","project","reason","snapshot_index","status"
  ]
' <<<"${envelope}" >/dev/null
body="$(jq -c '.worker_result_json' <<<"${envelope}")"
event_id="$(jq -er '.event_id' <<<"${body}")"
jq -nc \
  --arg event_id "${event_id}" \
  --arg run_id "${OPENCLAW_RUN_ID:-}" \
  --arg target "${target}" \
  --argjson token_env_present "${token_env_present}" \
  --arg callback_nonce "$(jq -r '.callback_nonce' <<<"${envelope}")" \
  --arg executor_agent "$(jq -r '.executor_agent' <<<"${envelope}")" \
  --argjson batch_acceptance "$(jq -c '.batch_acceptance' <<<"${envelope}")" \
  --argjson body "${body}" \
  '{event_id:$event_id,run_id:$run_id,target:$target,token_env_present:$token_env_present,
    callback_nonce:$callback_nonce,executor_agent:$executor_agent,
    batch_acceptance:$batch_acceptance,body:$body}' \
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
if [ "${call_count}" -eq 1 ] && [ "${event_id}" = "batch-R:snapshot-0:terminal-1" ]; then
  jq -nc --arg event_id "${event_id}" \
    '{status:"retry_later",event_id:$event_id}'
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
if [ "${call_count}" -eq 2 ] \
    && [ "${event_id}" = "batch-A:snapshot-0:terminal-1" ]; then
  printf '%s\n' '```json'
  jq -nc --arg event_id "${event_id}" \
    '{status:"duplicate",event_id:$event_id}'
  printf '%s\n' '```' '```json'
  jq -nc --arg event_id "${event_id}" \
    '{status:"duplicate",event_id:$event_id}'
  printf '%s\n' '```'
  exit 0
fi
if [ "${call_count}" -eq 2 ] \
    && [ "${event_id}" = "batch-B:snapshot-0:terminal-1" ]; then
  printf '%s\n' '回调已处理，结果如下：' '```json'
  jq -nc --arg event_id "${event_id}" \
    '{status:"duplicate",event_id:$event_id}'
  printf '%s\n' '```'
  exit 0
fi
if [ "${call_count}" -eq 2 ] \
    && [ "${event_id}" = "batch-R:snapshot-0:terminal-1" ]; then
  printf '%s\n' '```json'
  jq -nc --arg event_id "${event_id}" \
    '{status:"duplicate",event_id:$event_id}'
  printf '%s\n' '```'
  exit 0
fi
if [ "${call_count}" -eq 3 ] \
    && [ "${event_id}" = "batch-A:snapshot-0:terminal-1" ]; then
  printf '%s\n' '```'
  jq -nc --arg event_id "${event_id}" \
    '{status:"duplicate",event_id:$event_id}'
  printf '%s\n' '```'
  exit 0
fi
jq -nc --arg event_id "${event_id}" '{status:"accepted",event_id:$event_id}'
EOF
chmod +x "${FAKE_OPENCLAW}"
: >"${OPENCLAW_ARGV_LOG}"
export OPENCLAW_ARGV_LOG

export GITLAB_TOKEN='callback-transport-token'
export GLAB_TOKEN='callback-transport-token'
export GITLAB_PRIVATE_TOKEN='callback-transport-token'
export PRIVATE_TOKEN='callback-transport-token'
export WIKI_GITLAB_TOKEN='callback-transport-token'

CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
NOW_EPOCH=2000000000 \
bash "${DRAIN_OUTBOX}" >/dev/null
grep -Fxq -- '--message-file' "${OPENCLAW_ARGV_LOG}" \
  || fail "callback transport did not use --message-file"
grep -Fxq -- '/dev/stdin' "${OPENCLAW_ARGV_LOG}" \
  || fail "callback transport did not stream the message through stdin"
if grep -Fxq -- '--message' "${OPENCLAW_ARGV_LOG}"; then
  fail "callback transport still placed the envelope in --message argv"
fi
for private_nonce in \
  "$(jq -r '.callback_nonce' "${OUTBOX_A}")" \
  "$(jq -r '.callback_nonce' "${OUTBOX_B}")" \
  "$(jq -r '.callback_nonce' "${OUTBOX_R}")"
do
  if grep -Fq -- "${private_nonce}" "${OPENCLAW_ARGV_LOG}"; then
    fail "callback nonce leaked into openclaw argv"
  fi
done
jq -se 'length == 3 and all(.[]; .token_env_present == true)' \
  "${OPENCLAW_LOG}" >/dev/null \
  || fail "callback transport did not inherit GitLab credentials"
jq -se '
  all(.[];
    (.callback_nonce | test("^[0-9a-f]{64}$"))
    and .executor_agent == "req_executor"
    and .batch_acceptance.status == "success"
    and .batch_acceptance.batch_id == .body.batch_id
    and .batch_acceptance.matched_count > .body.snapshot_index
    and (.batch_acceptance.snapshot_digest | test("^[0-9a-f]{64}$"))
    and (.body | has("callback_nonce") | not)
    and (.body | has("executor_agent") | not))
' "${OPENCLAW_LOG}" >/dev/null \
  || fail "callback authentication was absent or leaked into public worker_result_json"
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}" "${OUTBOX_R}"; do
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
NOW_EPOCH=2000000030 \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/drain-a.out" &
DRAIN_PID_A=$!
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
NOW_EPOCH=2000000030 \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/drain-b.out" &
DRAIN_PID_B=$!
wait "${DRAIN_PID_A}"
wait "${DRAIN_PID_B}"

OUTBOX_R="${SCHEDULER_ROOT}/callback_archive/${EVENT_R}.json"

jq -e '
  .attempts == 2
  and .delivered_at == null
  and (.last_error | type == "string" and length > 0)
' "${OUTBOX_A}" >/dev/null \
  || fail "double-fenced ack stream was accepted from one valid fenced object"
jq -e '
  .attempts == 2
  and .delivered_at == null
  and .last_error == "malformed_or_ambiguous_ack"
' "${OUTBOX_B}" >/dev/null \
  || fail "prose-prefixed fenced strict ack was accepted"
jq -e '
  .attempts == 2
  and (.delivered_at | type == "number" and . >= 0)
  and .last_error == null
' "${OUTBOX_R}" >/dev/null \
  || fail "exact single json-fenced matching ack did not atomically mark delivery"

# Once double-fenced and prose-prefixed fenced streams are rejected, a later
# exact single plain fence and a whole-response strict JSON acknowledgement for
# the same events remain valid and idempotent.
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
NOW_EPOCH=2000000090 \
bash "${DRAIN_OUTBOX}" >/dev/null
OUTBOX_A="${SCHEDULER_ROOT}/callback_archive/${EVENT_A}.json"
OUTBOX_B="${SCHEDULER_ROOT}/callback_archive/${EVENT_B}.json"
for outbox_file in "${OUTBOX_A}" "${OUTBOX_B}"; do
  jq -e '
    .attempts == 3
    and (.delivered_at | type == "number" and . >= 0)
    and .last_error == null
  ' "${outbox_file}" >/dev/null \
    || fail "strict matching ack did not complete delivery after stream rejection"
done
[ -f "${OUTBOX_A}" ] && [ -f "${OUTBOX_B}" ] && [ -f "${OUTBOX_R}" ] \
  || fail "drain did not retain durable outbox evidence in cold archive"
jq -se \
  --arg event_a "${EVENT_A}" \
  --arg event_b "${EVENT_B}" \
  --arg event_r "${EVENT_R}" '
  def bodies($event): [.[] | select(.event_id == $event) | (.body | @json)];
  def run_ids($event): [.[] | select(.event_id == $event) | .run_id];
  ((bodies($event_a) | length) == 3 and (bodies($event_a) | unique | length) == 1)
  and ((bodies($event_b) | length) == 3 and (bodies($event_b) | unique | length) == 1)
  and ((bodies($event_r) | length) == 2 and (bodies($event_r) | unique | length) == 1)
  and (all(.[]; .run_id | test("^driven-callback-[0-9a-f]{64}$")))
  and ((run_ids($event_a) | unique | length) == 3)
  and ((run_ids($event_b) | unique | length) == 3)
  and ((run_ids($event_r) | unique | length) == 2)
' "${OPENCLAW_LOG}" >/dev/null \
  || fail "drain changed the public event body, reused an OpenClaw idempotency key, or duplicated a concurrent send"

cold_only_drain="$(CONFIG_DIR="${CONFIG_DIR}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" OPENCLAW_LOG="${OPENCLAW_LOG}" \
  OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
  EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
  bash "${DRAIN_OUTBOX}")"
jq -e '.scanned == 0 and .attempted == 0' <<<"${cold_only_drain}" >/dev/null \
  || fail "delivered callback history remained in the hot outbox scan"

# Rolling lock-layout upgrade: an old drainer can create the former hot lock
# after the new process already completed its migration scan. The new drainer
# must still acquire that late old-path lock before sending the same event.
ROLLING_FIRST_EVENT='aaa-rolling-lock:snapshot-0:terminal-1'
ROLLING_RACE_EVENT='zzz-rolling-lock:snapshot-0:terminal-1'
for rolling_event in "${ROLLING_FIRST_EVENT}" "${ROLLING_RACE_EVENT}"; do
  jq --arg event_id "${rolling_event}" '
    .event_id = $event_id
    | .body.event_id = $event_id
    | .body.batch_id = ($event_id | split(":")[0])
    | .attempts = 0
    | .last_error = null
    | .delivered_at = null
    | .ready_at = 1
    | .next_attempt_at = null
  ' "${OUTBOX_A}" >"${SCHEDULER_ROOT}/callback_outbox/${rolling_event}.json"
done
ROLLING_SCAN_DONE="${TEST_ROOT}/rolling-scan-done"
ROLLING_OLD_READY="${TEST_ROOT}/rolling-old-ready"
ROLLING_RELEASE="${TEST_ROOT}/rolling-release"
ROLLING_SEND_LOG="${TEST_ROOT}/rolling-send.log"
ROLLING_OPENCLAW="${TEST_ROOT}/rolling-openclaw.sh"
cat >"${ROLLING_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
message=""
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --message) shift; message="${1:-}" ;;
    --message-file) shift; message_file="${1:-}" ;;
  esac
  [ "$#" -gt 0 ] && shift
done
if [ -n "${message_file}" ]; then
  [ "${message_file}" = /dev/stdin ]
  message="$(cat)"
fi
envelope="${message#*callback_envelope=}"
envelope="${envelope%%$'\n'*}"
event_id="$(jq -r '.worker_result_json.event_id' <<<"${envelope}")"
printf '%s\n' "${event_id}" >>"${ROLLING_SEND_LOG:?}"
if [ "${event_id}" = "${ROLLING_FIRST_EVENT:?}" ]; then
  : >"${ROLLING_SCAN_DONE:?}"
  for _wait in $(seq 1 200); do
    [ -e "${ROLLING_OLD_READY:?}" ] && break
    sleep 0.01
  done
  [ -e "${ROLLING_OLD_READY}" ]
fi
jq -nc --arg event_id "${event_id}" '{status:"accepted",event_id:$event_id}'
EOF
chmod +x "${ROLLING_OPENCLAW}"
: >"${ROLLING_SEND_LOG}"
(
  for _wait in $(seq 1 200); do
    [ -e "${ROLLING_SCAN_DONE}" ] && break
    sleep 0.01
  done
  [ -e "${ROLLING_SCAN_DONE}" ]
  exec 8>"${SCHEDULER_ROOT}/callback_outbox/.${ROLLING_RACE_EVENT}.lock"
  flock -x 8
  : >"${ROLLING_OLD_READY}"
  for _wait in $(seq 1 300); do
    [ -e "${ROLLING_RELEASE}" ] && break
    sleep 0.01
  done
  [ -e "${ROLLING_RELEASE}" ]
  flock -u 8
) &
ROLLING_OLD_PID=$!
CONFIG_DIR="${CONFIG_DIR}" OPENCLAW_BIN="${ROLLING_OPENCLAW}" \
ROLLING_SEND_LOG="${ROLLING_SEND_LOG}" \
ROLLING_FIRST_EVENT="${ROLLING_FIRST_EVENT}" \
ROLLING_SCAN_DONE="${ROLLING_SCAN_DONE}" ROLLING_OLD_READY="${ROLLING_OLD_READY}" \
NOW_EPOCH=2000000100 DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=86400 \
bash "${DRAIN_OUTBOX}" >"${TEST_ROOT}/rolling-drain.out" &
ROLLING_DRAIN_PID=$!
for _wait in $(seq 1 300); do
  [ -e "${ROLLING_OLD_READY}" ] && break
  sleep 0.01
done
[ -e "${ROLLING_OLD_READY}" ] || fail "rolling callback old lock was not established"
sleep 0.2
if grep -Fxq "${ROLLING_RACE_EVENT}" "${ROLLING_SEND_LOG}"; then
  : >"${ROLLING_RELEASE}"
  wait "${ROLLING_OLD_PID}" || true
  wait "${ROLLING_DRAIN_PID}" || true
  fail "new callback drainer bypassed a late old-path rolling-upgrade lock"
fi
: >"${ROLLING_RELEASE}"
wait "${ROLLING_OLD_PID}"
wait "${ROLLING_DRAIN_PID}"
grep -Fxq "${ROLLING_RACE_EVENT}" "${ROLLING_SEND_LOG}" \
  || fail "rolling callback did not resume after the old lock released"

# A crash/upgrade can leave the delivered JSON in hot storage after
# delivered_at was committed. The next drain must archive it without a second
# network send; otherwise this history remains in every hot scan forever.
PREDELIVERED_EVENT='batch-pre-delivered:snapshot-0:terminal-1'
PREDELIVERED_HOT="${SCHEDULER_ROOT}/callback_outbox/${PREDELIVERED_EVENT}.json"
PREDELIVERED_ARCHIVE="${SCHEDULER_ROOT}/callback_archive/${PREDELIVERED_EVENT}.json"
jq --arg event_id "${PREDELIVERED_EVENT}" '
  .event_id = $event_id
  | .body.event_id = $event_id
  | .body.batch_id = "batch-pre-delivered"
  | .attempts = 7
  | .delivered_at = 12345
  | .updated_at = 12345
  | .target = "agent:req_dispatcher:legacy-pre-delivered"
  | del(.callback_auth_mode, .executor_agent, .callback_nonce)
' "${OUTBOX_A}" >"${PREDELIVERED_HOT}"
OPENCLAW_CALLS_BEFORE_PREDELIVERED="$(wc -l <"${OPENCLAW_LOG}" | tr -d ' ')"
CONFIG_DIR="${CONFIG_DIR}" \
OPENCLAW_BIN="${FAKE_OPENCLAW}" OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
bash "${DRAIN_OUTBOX}" >/dev/null
[ ! -e "${PREDELIVERED_HOT}" ] && [ -f "${PREDELIVERED_ARCHIVE}" ] \
  || fail "pre-delivered hot callback was not idempotently archived"
jq -e '.callback_auth_mode == "legacy_pre_upgrade"' \
  "${PREDELIVERED_ARCHIVE}" >/dev/null \
  || fail "pre-delivered legacy callback was archived without explicit upgrade classification"
[ "$(wc -l <"${OPENCLAW_LOG}" | tr -d ' ')" = "${OPENCLAW_CALLS_BEFORE_PREDELIVERED}" ] \
  || fail "pre-delivered hot callback was sent again"

# Upgrade old stable lock files out of the hot JSON directory. Their history
# must not affect the callback glob/readdir cost or the reported scan count.
for history_lock_index in $(seq 0 104); do
  : >"${SCHEDULER_ROOT}/callback_outbox/.history-${history_lock_index}.lock"
done
history_lock_drain="$(CONFIG_DIR="${CONFIG_DIR}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" OPENCLAW_LOG="${OPENCLAW_LOG}" \
  OPENCLAW_BARRIER_DIR="${OPENCLAW_BARRIER_DIR}" \
  EXPECT_SCHEDULER_LOCK="${SCHEDULER_ROOT}/scheduler.lock" \
  bash "${DRAIN_OUTBOX}")"
jq -e '.scanned == 0 and .attempted == 0' <<<"${history_lock_drain}" >/dev/null \
  || fail "historical callback locks polluted the hot callback scan"
if find "${SCHEDULER_ROOT}/callback_outbox" -maxdepth 1 -type f -name '*.lock' \
    -print -quit | grep -q .; then
  fail "historical callback locks remained beside hot JSON"
fi
[ "$(find "${SCHEDULER_ROOT}/callback_locks" -maxdepth 1 -type f -name '*.lock' | wc -l | tr -d ' ')" -ge 105 ] \
  || fail "historical callback locks were not migrated to the independent lock directory"

# A large failed callback backlog must not monopolize the executor tick. Limit
# actual sends per invocation and persist a retry clock so the same earliest
# entries do not immediately consume every later tick.
BUDGET_BACKLOG_ARCHIVE="${TEST_ROOT}/budget-backlog-fixture"
BUDGET_OPENCLAW_LOG="${TEST_ROOT}/budget-openclaw.log"
mkdir -p "${BUDGET_BACKLOG_ARCHIVE}"
: >"${BUDGET_OPENCLAW_LOG}"
for budget_index in $(seq 0 104); do
  budget_suffix="$(printf '%03d' "${budget_index}")"
  budget_event="budget-${budget_suffix}:snapshot-0:terminal-1"
  jq --arg event_id "${budget_event}" --arg batch_id "budget-${budget_suffix}" '
    .event_id = $event_id
    | .body.event_id = $event_id
    | .body.batch_id = $batch_id
    | .attempts = 0
    | .last_error = null
    | .delivered_at = null
    | .ready_at = 1
    | .created_at = 1
    | .updated_at = 1
    | del(.next_attempt_at)
  ' "${OUTBOX_A}" >"${SCHEDULER_ROOT}/callback_outbox/${budget_event}.json"
done
budget_first_out="$(CONFIG_DIR="${CONFIG_DIR}" \
  OPENCLAW_BIN="${NOT_READY_OPENCLAW}" \
  NOT_READY_OPENCLAW_LOG="${BUDGET_OPENCLAW_LOG}" \
  NOW_EPOCH=1000 DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK=3 \
  DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS=10 \
  DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS=100 \
  bash "${DRAIN_OUTBOX}")"
jq -e '.attempted == 3 and .failed == 3' <<<"${budget_first_out}" >/dev/null \
  || fail "outbox tick exceeded its configured delivery-attempt budget"
jq -e '.attempts == 1 and .next_attempt_at == 1010' \
  "${SCHEDULER_ROOT}/callback_outbox/budget-000:snapshot-0:terminal-1.json" >/dev/null \
  || fail "failed callback did not persist its first retry backoff"
budget_second_out="$(CONFIG_DIR="${CONFIG_DIR}" \
  OPENCLAW_BIN="${NOT_READY_OPENCLAW}" \
  NOT_READY_OPENCLAW_LOG="${BUDGET_OPENCLAW_LOG}" \
  NOW_EPOCH=1000 DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK=3 \
  DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS=10 \
  DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS=100 \
  bash "${DRAIN_OUTBOX}")"
jq -e '.attempted == 3 and .failed == 3' <<<"${budget_second_out}" >/dev/null \
  || fail "deferred callback backlog prevented the next bounded drain"
jq -e '.attempts == 1 and .next_attempt_at == 1010' \
  "${SCHEDULER_ROOT}/callback_outbox/budget-000:snapshot-0:terminal-1.json" >/dev/null \
  || fail "callback was retried before its persisted next_attempt_at"
[ "$(wc -l <"${BUDGET_OPENCLAW_LOG}" | tr -d ' ')" = 6 ] \
  || fail "bounded drains performed an unexpected number of network sends"
mv "${SCHEDULER_ROOT}"/callback_outbox/budget-*.json \
  "${BUDGET_BACKLOG_ARCHIVE}/"

# Rolling upgrade: a trusted pre-upgrade request can already be running before
# callback auth fields existed. Its real terminal import must still release the
# scheduler slot and explicitly classify a raw-I3 legacy delivery.
LEGACY_BATCH_ID='batch-legacy-pre-upgrade'
LEGACY_JOB_ID="${LEGACY_BATCH_ID}:snapshot-0"
LEGACY_EVENT_ID="${LEGACY_BATCH_ID}:snapshot-0:terminal-1"
LEGACY_PHYSICAL_EVENT_ID="${LEGACY_JOB_ID}:claim-1:terminal-1"
LEGACY_BATCH_DIR="${SCHEDULER_ROOT}/batches/${LEGACY_BATCH_ID}"
LEGACY_HANDOFF="${TEST_ROOT}/legacy-pre-upgrade-handoff.json"
LEGACY_OUTBOX_HOT="${SCHEDULER_ROOT}/callback_outbox/${LEGACY_EVENT_ID}.json"
LEGACY_OUTBOX_ARCHIVE="${SCHEDULER_ROOT}/callback_archive/${LEGACY_EVENT_ID}.json"
mkdir -p "${LEGACY_BATCH_DIR}"
jq -cnS --arg batch_id "${LEGACY_BATCH_ID}" '{
  version:1,
  batch_id:$batch_id,
  correlation_id:"legacy-correlation",
  project:"group/repo",
  selector:{type:"single",iid:42},
  force_rerun_pr:false,
  dispatcher_callback_target:"agent:req_dispatcher:legacy-session",
  branch:"main"
}' >"${LEGACY_BATCH_DIR}/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
  >"${LEGACY_BATCH_DIR}/snapshot.json"
jq -cnS --arg batch_id "${LEGACY_BATCH_ID}" --arg job_id "${LEGACY_JOB_ID}" '{
  version:1,batch_id:$batch_id,status:"running",
  matched_count:1,terminal_count:0,done_count:0,failed_count:0,
  timeout_count:0,skipped_count:0,next_snapshot_index:1,
  request_digest:"legacy-request",snapshot_digest:"legacy-snapshot",
  memberships:{"0":{snapshot_index:0,iid:42,status:"running",job_id:$job_id}}
}' >"${LEGACY_BATCH_DIR}/state.json"
jq --arg batch_id "${LEGACY_BATCH_ID}" --arg job_id "${LEGACY_JOB_ID}" '
  .batch_order = ((.batch_order + [$batch_id]) | unique)
  | .active_jobs[$job_id] = {
      job_id:$job_id,physical_key:"group/repo#42",project:"group/repo",iid:42,
      branch:"main",entry_mode:"auto",force_rerun_pr:false,status:"running",
      reservation_seq:99,claim_generation:1,claim_token:"legacy-private-claim",
      reserved_at:200,updated_at:201,
      owner:{batch_id:$batch_id,snapshot_index:0},
      memberships:[{batch_id:$batch_id,snapshot_index:0}]
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.legacy-running"
mv "${SCHEDULER_ROOT}/scheduler_state.legacy-running" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
jq -cnS --arg event_id "${LEGACY_PHYSICAL_EVENT_ID}" \
  --arg job_id "${LEGACY_JOB_ID}" '{
  version:1,event_id:$event_id,job_id:$job_id,
  memberships:[],memberships_source:"scheduler_active_job",
  claim_generation:1,claim_token:"legacy-private-claim",
  project:"group/repo",iid:42,status:"done",mr_url:null,reason:null
}' >"${LEGACY_HANDOFF}"
legacy_import_out="$(CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${LEGACY_HANDOFF}" \
  NOW_EPOCH=300 bash "${IMPORT_HANDOFF}")" \
  || fail "trusted pre-upgrade request could not import its terminal handoff"
jq -e '.status == "imported" and .terminal_recorded == true and .outbox_count == 1' \
  <<<"${legacy_import_out}" >/dev/null \
  || fail "pre-upgrade terminal import returned an invalid result"
jq -e --arg job_id "${LEGACY_JOB_ID}" '.active_jobs | has($job_id) | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "pre-upgrade terminal import did not release the scheduler slot"
jq -e '
  .callback_auth_mode == "legacy_pre_upgrade"
  and (has("executor_agent") | not)
  and (has("callback_nonce") | not)
  and .target == "agent:req_dispatcher:legacy-session"
' "${LEGACY_OUTBOX_HOT}" >/dev/null \
  || fail "pre-upgrade outbox was not explicitly classified without fabricating auth"
# Also model an outbox file written by the old binary before the importer
# itself knew about the explicit marker. The drainer must classify that trusted
# exact legacy shape once before transport.
jq 'del(.callback_auth_mode)' "${LEGACY_OUTBOX_HOT}" \
  >"${LEGACY_OUTBOX_HOT}.pre-upgrade"
mv "${LEGACY_OUTBOX_HOT}.pre-upgrade" "${LEGACY_OUTBOX_HOT}"

LEGACY_OPENCLAW="${TEST_ROOT}/legacy-openclaw.sh"
LEGACY_OPENCLAW_LOG="${TEST_ROOT}/legacy-openclaw.jsonl"
cat >"${LEGACY_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=""
message=""
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-key) shift; target="${1:-}" ;;
    --message) shift; message="${1:-}" ;;
    --message-file) shift; message_file="${1:-}" ;;
  esac
  [ "$#" -gt 0 ] && shift
done
if [ -n "${message_file}" ]; then
  [ "${message_file}" = /dev/stdin ]
  message="$(cat)"
fi
[ "${target}" = "agent:req_dispatcher:legacy-session" ]
ACK_ONLY_INSTRUCTION='ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。'
[[ "${message}" == RUN_DRIVEN_BATCH_RESULT_ACK_ONLY$'\n'worker_result_json=*$'\n'"${ACK_ONLY_INSTRUCTION}" ]]
[[ "${message}" != *callback_envelope=* ]]
body="${message#*worker_result_json=}"
body="${body%%$'\n'*}"
jq -e '(keys | sort) == [
  "batch_id","event_id","iid","mr_url","project","reason","snapshot_index","status"
]' <<<"${body}" >/dev/null
printf '%s\n' "${body}" >>"${LEGACY_OPENCLAW_LOG:?}"
jq -nc --arg event_id "$(jq -r '.event_id' <<<"${body}")" \
  '{status:"accepted",event_id:$event_id}'
EOF
chmod +x "${LEGACY_OPENCLAW}"
: >"${LEGACY_OPENCLAW_LOG}"
legacy_drain_out="$(CONFIG_DIR="${CONFIG_DIR}" OPENCLAW_BIN="${LEGACY_OPENCLAW}" \
  LEGACY_OPENCLAW_LOG="${LEGACY_OPENCLAW_LOG}" NOW_EPOCH=2000000200 \
  bash "${DRAIN_OUTBOX}")"
jq -e '.attempted == 1 and .delivered == 1 and .failed == 0' \
  <<<"${legacy_drain_out}" >/dev/null \
  || fail "pre-upgrade raw I3 callback was not delivered"
[ ! -e "${LEGACY_OUTBOX_HOT}" ] && [ -f "${LEGACY_OUTBOX_ARCHIVE}" ] \
  || fail "delivered pre-upgrade callback did not leave hot storage"
jq -e '.callback_auth_mode == "legacy_pre_upgrade"' \
  "${LEGACY_OUTBOX_ARCHIVE}" >/dev/null \
  || fail "old outbox shape was not durably upgraded before raw delivery"
jq -se 'length == 1 and .[0].event_id == "batch-legacy-pre-upgrade:snapshot-0:terminal-1"' \
  "${LEGACY_OPENCLAW_LOG}" >/dev/null \
  || fail "pre-upgrade callback did not preserve the strict raw eight-field I3"
legacy_replay_out="$(CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${LEGACY_HANDOFF}" \
  NOW_EPOCH=500 bash "${IMPORT_HANDOFF}")" \
  || fail "delivered legacy_pre_upgrade handoff was not replayable"
jq -e '.status == "replayed" and .terminal_recorded == true and .outbox_count == 1' \
  <<<"${legacy_replay_out}" >/dev/null \
  || fail "legacy_pre_upgrade replay returned an invalid result"
[ "$(wc -l <"${LEGACY_OPENCLAW_LOG}" | tr -d ' ')" = 1 ] \
  || fail "legacy_pre_upgrade import replay resent an archived callback"

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

unset GITLAB_TOKEN GLAB_TOKEN GITLAB_PRIVATE_TOKEN PRIVATE_TOKEN WIKI_GITLAB_TOKEN

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
  "${SKILL_DIR}/scripts/git_network_guard.sh" \
  "${SKILL_DIR}/scripts/drain_driven_handoff_intents.sh" \
  "${FOLLOWUP_SCRIPTS}/"

cat >"${FOLLOWUP_SCRIPTS}/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
evidence="${DISPATCHER_LOG_DIR}/reconcile-20260711T000000Z.json"
jq -cn --argjson iid "${MIN_IID:?}" \
  --argjson completed "${RECONCILE_LIVE_COMPLETED:-false}" \
  --argjson finish "${RECONCILE_LIVE_FINISH:-false}" '[{
  iid:$iid,
  is_closed_on_gitlab:$completed,
  is_done_on_gitlab:($completed or $finish),
  has_done_pr:$completed,
  has_finish:$finish,
  labels:(if $finish then ["finish"] else [] end)
}]' >"${evidence}"
printf '%s\n' "${evidence}"
EOF
cat >"${FOLLOWUP_SCRIPTS}/set_issue_label.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s:%s\n' "$1" "$2" >>"${FOLLOWUP_LABEL_LOG:?}"
if [ "${FOLLOWUP_FAIL_FINISH:-false}" = true ] \
    && [ "$1" = add ] && [ "$2" = finish ]; then
  exit 73
fi
exit 0
EOF
cat >"${FOLLOWUP_SCRIPTS}/merge_mr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${MERGE_MR_MODE:?}" = verify ]
jq -cn \
  --argjson iid "${MR_IID}" \
  --arg web_url "${MERGE_REQUEST_URL}" \
  --arg source_branch "${WORK_BRANCH}" \
  --arg target_branch "${MERGE_TARGET_BRANCH}" \
  --arg dependency_base_sha "${DEPENDENCY_BASE_SHA:-}" \
  --arg sha "${COMMIT_SHA}" '{
    version:1,iid:$iid,web_url:$web_url,
    source_branch:$source_branch,target_branch:$target_branch,
    dependency_base_sha:$dependency_base_sha,sha:$sha,
    observed_state:"merged",outcome:"merged",verified:true,
    merge_attempted:false,merge_api_succeeded:false,reason:"verified_merged"
  }'
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
FOLLOWUP_LABEL_LOG="${FOLLOWUP_ROOT}/labels.log"
export FOLLOWUP_LABEL_LOG
: >"${FOLLOWUP_LABEL_LOG}"

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
      execution_id:1,
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
cp "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/campaign-state-baseline.json"
: >"${FOLLOWUP_IMPORT_LOG}"

write_followup_auto_merge_marker() {
  local marker_dir="${FOLLOWUP_REPO}/.req_executor/.worktrees/issue-42/.req_executor/issue-42/log/execution-1"
  mkdir -p "${marker_dir}"
  jq -cn '{
    version:1,iid:9,
    web_url:"https://gitlab.example/group/repo/-/merge_requests/9",
    source_branch:"issue/42",target_branch:"release",
    sha:"0123456789abcdef0123456789abcdef01234567",
    observed_state:"merged",outcome:"merged",verified:true,
    merge_attempted:true,merge_api_succeeded:true,reason:"verified_merged",
    mr_action:"created",issue_iid:42,execution_id:1,auto_merge:true
  }' >"${marker_dir}/mr_result.json"
  chmod 600 "${marker_dir}/mr_result.json"
}

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

jq -e --arg expected_status "${EXPECT_HANDOFF_STATUS:-done}" '
  (.pending_subagents | has("42") | not)
  and (if $expected_status == "done" then .completed_iids == [42]
       elif $expected_status == "timeout" then .timeout_iids == [42]
       else .completed_iids == [] and .timeout_iids == [] end)
' "${EXPECT_CAMPAIGN_STATE:?}" >/dev/null
jq -e --arg expected_status "${EXPECT_HANDOFF_STATUS:-done}" '
  .event_id == "batch-A:snapshot-0:claim-1:terminal-1"
  and .job_id == "batch-A:snapshot-0"
  and .memberships == []
  and .memberships_source == "scheduler_active_job"
  and .claim_generation == 1
  and .claim_token == "claim-token-42"
  and .project == "group/repo"
  and .iid == 42
  and .status == $expected_status
' "${HANDOFF_FILE:?}" >/dev/null
printf '%s\n' "${HANDOFF_FILE}" >>"${FOLLOWUP_IMPORT_LOG:?}"
exit 47
EOF
chmod +x "${FAKE_IMPORTER}"

TIMEOUT_TOKEN_SHA="$(printf '%s' 'claim-token-42' | test_sha256_text)"
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
cp "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-wrong-timeout-fence.json"
wrong_timeout_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_TIMEOUT_RECONCILE=1 \
  DRIVEN_TIMEOUT_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_TIMEOUT_CLAIM_GENERATION=2 \
  DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_TIMEOUT_NOW_EPOCH=2000000000 \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "stale_claim"' <<<"${wrong_timeout_out}" >/dev/null \
  || fail "timeout reconcile accepted a stale claim generation"
cmp -s "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-wrong-timeout-fence.json" \
  || fail "stale timeout claim mutated campaign state"

cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"].spawned_at = "1970-01-01T00:00:01Z"' \
  "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.not-due"
mv "${FOLLOWUP_STATE}.not-due" "${FOLLOWUP_STATE}"
cp "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-not-due.json"
not_due_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_TIMEOUT_RECONCILE=1 \
  DRIVEN_TIMEOUT_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_TIMEOUT_CLAIM_GENERATION=1 \
  DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_TIMEOUT_NOW_EPOCH=100 \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "not_due"' <<<"${not_due_out}" >/dev/null \
  || fail "timeout reconcile terminated a claim before its ACPX deadline"
cmp -s "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-not-due.json" \
  || fail "not-due timeout reconcile mutated campaign state"

# A heartbeat preflight that observes pr/closed may request immediate
# completion reconciliation without waiting for the running lease. The project
# wrapper must re-check GitLab under campaign.lock, reject stale positive
# evidence without mutation, then write the same claim-bound skipped handoff
# when the live evidence is still present.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
cp "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-not-completed.json"
not_completed_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_COMPLETED_RECONCILE=1 \
  DRIVEN_RECONCILE_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_RECONCILE_CLAIM_GENERATION=1 \
  DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "not_completed" and .iid == 42' \
  <<<"${not_completed_out}" >/dev/null \
  || fail "heartbeat completion reconcile accepted stale positive evidence"
cmp -s "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-not-completed.json" \
  || fail "not-completed heartbeat reconcile mutated campaign state"

cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"
heartbeat_completed_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  RECONCILE_LIVE_COMPLETED=true \
  DRIVEN_COMPLETED_RECONCILE=1 \
  DRIVEN_RECONCILE_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_RECONCILE_CLAIM_GENERATION=1 \
  DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=skipped EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "skipped"
  and (.block_reason | contains("heartbeat completion reconciliation"))
' <<<"${heartbeat_completed_out}" >/dev/null \
  || fail "heartbeat completion reconcile did not emit a claim-bound skipped handoff"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 1 ] \
  || fail "heartbeat completion reconcile did not invoke the handoff importer once"
jq -e '
  (.pending_subagents | has("42") | not)
  and .active_issue_iids == []
  and .campaign_status == "running"
  and .completed_iids == []
  and .timeout_iids == []
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "heartbeat completion reconcile did not release project pending state"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven-handoffs-heartbeat-completed"
fi

# A lost running callback can be discovered after GitLab already shows the
# issue closed/pr-complete. The timeout reconciler must preserve those labels
# while still emitting the exact claim-bound terminal handoff that releases
# the scheduler slot. A plain ghost drop would strand active_jobs forever.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"
live_completed_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  RECONCILE_LIVE_COMPLETED=true \
  DRIVEN_TIMEOUT_RECONCILE=1 \
  DRIVEN_TIMEOUT_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_TIMEOUT_CLAIM_GENERATION=1 \
  DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_TIMEOUT_NOW_EPOCH=2000000000 \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=skipped EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "skipped"
' <<<"${live_completed_out}" >/dev/null \
  || fail "live-completed timeout reconcile did not emit a claim-bound skipped handoff"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 1 ] \
  || fail "live-completed timeout reconcile did not invoke the handoff importer once"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == []
  and .timeout_iids == []
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "live-completed timeout reconcile regressed project terminal labels/state"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs-live-completed"
fi

# A shared MR checkpoint must never enter the ordinary completed-ghost drain.
# Even if GitLab already shows `pr`/closed and the native callback is failure-
# shaped, a temporarily missing exact marker retains the same claim for the
# heartbeat's MR-only recovery path.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"] += {
  auto_merge:false,merge_target_branch:"main",
  work_branch:"issue/42+43",branch_members:[42,43],
  shared_branch_role:"head",dependency_iid:null,
  dependency_branch:null,dependency_base_sha:null
}' "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.shared-pending"
mv "${FOLLOWUP_STATE}.shared-pending" "${FOLLOWUP_STATE}"
jq -cn '{
  iid:42,status:"doing",work_branch:"issue/42+43",
  branch_members:[42,43],shared_branch_role:"head",
  dependency_iid:null,dependency_branch:null,dependency_base_sha:null,
  dependency_pinned_execution_id:1,dependency_history_verified:true,
  work_branch_sha:"0123456789abcdef0123456789abcdef01234567",
  mr_finalization:{
    status:"pending",source_execution_id:1,
    work_branch:"issue/42+43",branch_members:[42,43],
    shared_branch_role:"head",
    commit_sha:"0123456789abcdef0123456789abcdef01234567",
    intent_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    target_branch:"main"
  }
}' >"${FOLLOWUP_REPO}/.req_executor/issues/issue-42/state.json"
chmod 600 "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/state.json"
: >"${FOLLOWUP_LABEL_LOG}"
shared_failure_reply="$(jq -cn '{
  iid:42,execution_id:1,status:"blocked",mode_actual:"fresh",
  work_branch:"issue/42+43",local_branch:"issue/42",
  commit_sha:"0123456789abcdef0123456789abcdef01234567",
  merge_request_url:"",mr_action:"none",wiki_url:"",
  labels_added:[],labels_removed:[],summary_posted:false,
  block_reason:"native callback arrived before shared MR marker",
  log_dir:"/tmp/shared-marker-pending",block_side:"dispatcher"
}')"
shared_ghost_out="$(printf '%s' "${shared_failure_reply}" | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 EXECUTION_ID=1 \
  CALLBACK_RUN_ID=run-42 \
  CALLBACK_CHILD_SESSION_KEY='agent:req_executor:subagent:42' \
  RECONCILE_LIVE_COMPLETED=true \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled" and .terminal_status == "blocked"
  and (.remaining_pending_iids | index(42) != null)
' <<<"${shared_ghost_out}" >/dev/null \
  || fail "shared failure callback was drained by the completed-ghost path"
jq -e '
  .pending_subagents["42"].mr_finalization_retry == true
  and .pending_subagents["42"].mr_finalization_retry_execution_id == 1
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "shared failure callback did not preserve the exact MR recovery claim"
[ ! -s "${FOLLOWUP_LABEL_LOG}" ] \
  || fail "shared marker-pending callback mutated workflow labels"

cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"

due_timeout_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_TIMEOUT_RECONCILE=1 \
  DRIVEN_TIMEOUT_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_TIMEOUT_CLAIM_GENERATION=1 \
  DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_TIMEOUT_NOW_EPOCH=2000000000 \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=timeout EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "handled" and .terminal_status == "timeout"' \
  <<<"${due_timeout_out}" >/dev/null \
  || fail "due running claim did not synthesize a timeout terminal"
jq -e '(.pending_subagents | has("42") | not) and .timeout_iids == [42]' \
  "${FOLLOWUP_STATE}" >/dev/null \
  || fail "due timeout did not durably drain project pending state"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs-timeout"
fi

# The proactive marker probe can overlap create_mr.sh after it has persisted
# exact identity but before its bounded merge helper returns. That initial
# marker is not a terminal opened/merged observation and must stay pending.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"] += {
  auto_merge:true,
  merge_target_branch:"release"
}' "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.marker-pending"
mv "${FOLLOWUP_STATE}.marker-pending" "${FOLLOWUP_STATE}"
write_followup_auto_merge_marker
PENDING_MARKER="${FOLLOWUP_REPO}/.req_executor/.worktrees/issue-42/.req_executor/issue-42/log/execution-1/mr_result.json"
jq '.verified=false
  | .outcome="unknown"
  | .observed_state="unknown"
  | .merge_attempted=false
  | .merge_api_succeeded=false
  | .reason="exact_mr_verification_pending"' \
  "${PENDING_MARKER}" >"${PENDING_MARKER}.pending"
chmod 600 "${PENDING_MARKER}.pending"
mv "${PENDING_MARKER}.pending" "${PENDING_MARKER}"
cp "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-marker-pending.json"
: >"${FOLLOWUP_LABEL_LOG}"
marker_pending_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_MARKER_RECONCILE=1 \
  DRIVEN_RECONCILE_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_RECONCILE_CLAIM_GENERATION=1 \
  DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "marker_not_ready" and .iid == 42' \
  <<<"${marker_pending_out}" >/dev/null \
  || fail "optimistic marker reconcile classified an in-progress marker"
cmp -s "${FOLLOWUP_STATE}" "${FOLLOWUP_ROOT}/before-marker-pending.json" \
  || fail "in-progress marker reconcile mutated pending state"
[ ! -s "${FOLLOWUP_LABEL_LOG}" ] \
  || fail "in-progress marker reconcile changed workflow labels"

# A wrapper may be killed after GitLab merged a non-default-target MR but before
# worker_result.json was written. Such a merge need not close the Issue, so the
# due timeout path must recover the private current-execution marker, independently
# verify the exact MR, add finish, and emit done instead of synthesizing timeout.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"] += {
  auto_merge:true,
  merge_target_branch:"release"
}' "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.auto-merge"
mv "${FOLLOWUP_STATE}.auto-merge" "${FOLLOWUP_STATE}"
write_followup_auto_merge_marker
: >"${FOLLOWUP_IMPORT_LOG}"
: >"${FOLLOWUP_LABEL_LOG}"
marker_timeout_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_TIMEOUT_RECONCILE=1 \
  DRIVEN_TIMEOUT_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_TIMEOUT_CLAIM_GENERATION=1 \
  DRIVEN_TIMEOUT_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_TIMEOUT_NOW_EPOCH=2000000000 \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=done EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .merge_request_url == "https://gitlab.example/group/repo/-/merge_requests/9"
' <<<"${marker_timeout_out}" >/dev/null \
  || fail "timeout reconcile did not recover a merged current-execution marker"
[ "$(cat "${FOLLOWUP_LABEL_LOG}")" = 'add:finish' ] \
  || fail "marker recovery did not perform one atomic finish transition"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
  and .timeout_iids == []
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "marker recovery was classified as timeout or left pending"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven-handoffs-marker-timeout"
fi

# A platform-generated failed/killed callback can race after the fixed wrapper
# has already persisted the exact current-execution MR marker. Even without a
# prior finish-label failure flag, the callback must enter the same independent
# MR verification path and converge the merged result instead of downgrading it.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"] += {
  auto_merge:true,
  merge_target_branch:"release"
}' "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.post-merge-kill"
mv "${FOLLOWUP_STATE}.post-merge-kill" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"
: >"${FOLLOWUP_LABEL_LOG}"
post_merge_killed_out="$(printf '%s\n' '{
  "iid":42,
  "execution_id":1,
  "status":"failed",
  "block_reason":"platform killed outer task before final compact reply"
}' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 EXECUTION_ID=1 \
  CALLBACK_RUN_ID=run-42 \
  CALLBACK_CHILD_SESSION_KEY='agent:req_executor:subagent:42' \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=done EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .merge_request_url == "https://gitlab.example/group/repo/-/merge_requests/9"
' <<<"${post_merge_killed_out}" >/dev/null \
  || fail "post-merge killed callback downgraded a verified current marker"
[ "$(cat "${FOLLOWUP_LABEL_LOG}")" = 'add:finish' ] \
  || fail "post-merge killed recovery did not converge finish atomically"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
  and .failed_iids == []
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "post-merge killed recovery did not complete and drain"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven-handoffs-post-merge-kill"
fi

# If exact merge verification succeeds but the atomic finish write is
# transiently unavailable, the claim remains pending with an attempt fence.
# A later non-empty native killed/failure callback must not downgrade it: the
# fence recovers the same marker, retries only verification + finish, and then
# releases the scheduler job.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"] += {
  auto_merge:true,
  merge_target_branch:"release"
}' "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.finish-retry"
mv "${FOLLOWUP_STATE}.finish-retry" "${FOLLOWUP_STATE}"
write_followup_auto_merge_marker
: >"${FOLLOWUP_IMPORT_LOG}"
: >"${FOLLOWUP_LABEL_LOG}"
finish_retry_blocked_out="$(printf '' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_MARKER_RECONCILE=1 \
  DRIVEN_RECONCILE_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_RECONCILE_CLAIM_GENERATION=1 \
  DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  FOLLOWUP_FAIL_FINISH=true \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "blocked"
  and .remaining_pending_iids == [42]
' <<<"${finish_retry_blocked_out}" >/dev/null \
  || fail "finish-label failure did not stay pending and retryable"
jq -e '
  .pending_subagents["42"].finish_label_retry == true
  and .pending_subagents["42"].finish_label_retry_execution_id == 1
  and ((.completed_iids // []) | index(42) == null)
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "finish-label failure omitted its current-execution durable fence"
[ ! -s "${FOLLOWUP_IMPORT_LOG}" ] \
  || fail "finish-label failure emitted a terminal scheduler handoff"
[ "$(cat "${FOLLOWUP_LABEL_LOG}")" = 'add:finish' ] \
  || fail "finish-label failure performed unexpected label transitions"

: >"${FOLLOWUP_IMPORT_LOG}"
finish_retry_killed_out="$(printf '%s\n' '{
  "iid":42,
  "execution_id":1,
  "status":"failed",
  "block_reason":"native child killed after marker recovery"
}' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 EXECUTION_ID=1 \
  CALLBACK_RUN_ID=run-42 \
  CALLBACK_CHILD_SESSION_KEY='agent:req_executor:subagent:42' \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=done EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .merge_request_url == "https://gitlab.example/group/repo/-/merge_requests/9"
' <<<"${finish_retry_killed_out}" >/dev/null \
  || fail "current-execution finish retry was downgraded by a killed callback"
[ "$(cat "${FOLLOWUP_LABEL_LOG}")" = $'add:finish\nadd:finish' ] \
  || fail "finish retry did not perform exactly two atomic finish attempts"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
  and .failed_iids == []
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "successful finish retry did not complete and drain the claim"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven-handoffs-finish-retry"
fi

# A stale retry flag from another attempt is never an override authority for a
# current callback, even if an old marker remains on disk.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
jq '.pending_subagents["42"] += {
  auto_merge:true,
  merge_target_branch:"release",
  finish_label_retry:true,
  finish_label_retry_execution_id:99
}' "${FOLLOWUP_STATE}" >"${FOLLOWUP_STATE}.stale-finish-retry"
mv "${FOLLOWUP_STATE}.stale-finish-retry" "${FOLLOWUP_STATE}"
STALE_FENCE_MARKER="${FOLLOWUP_REPO}/.req_executor/.worktrees/issue-42/.req_executor/issue-42/log/execution-1/mr_result.json"
mv "${STALE_FENCE_MARKER}" "${STALE_FENCE_MARKER}.held-for-stale-fence-test"
: >"${FOLLOWUP_IMPORT_LOG}"
: >"${FOLLOWUP_LABEL_LOG}"
stale_finish_retry_out="$(printf '%s\n' '{
  "iid":42,
  "execution_id":1,
  "status":"failed",
  "block_reason":"current native failure"
}' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 EXECUTION_ID=1 \
  CALLBACK_RUN_ID=run-42 \
  CALLBACK_CHILD_SESSION_KEY='agent:req_executor:subagent:42' \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=failed EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "handled" and .terminal_status == "failed"' \
  <<<"${stale_finish_retry_out}" >/dev/null \
  || fail "stale finish retry attempt hijacked the current native callback"
if grep -Fxq 'add:finish' "${FOLLOWUP_LABEL_LOG}"; then
  fail "stale finish retry attempt authorized a finish transition"
fi
jq -e '
  (.pending_subagents | has("42") | not)
  and .failed_iids == [42]
  and .completed_iids == []
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "stale finish retry attempt prevented current failure classification"
mv "${STALE_FENCE_MARKER}.held-for-stale-fence-test" "${STALE_FENCE_MARKER}"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven-handoffs-stale-finish-retry"
fi

# A late ordinary done callback may arrive after a newer automatic flow already
# placed finish. Fresh reconcile evidence must drain the old callback without
# invoking the ordinary done->pr transition.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"
: >"${FOLLOWUP_LABEL_LOG}"
late_done_out="$(printf '%s\n' '{
  "iid":42,
  "execution_id":1,
  "status":"done",
  "merge_request_url":"https://gitlab.example/group/repo/-/merge_requests/8"
}' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 EXECUTION_ID=1 \
  CALLBACK_RUN_ID=run-42 \
  CALLBACK_CHILD_SESSION_KEY='agent:req_executor:subagent:42' \
  RECONCILE_LIVE_FINISH=true \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=done EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '.callback_status == "handled" and .terminal_status == "done"' \
  <<<"${late_done_out}" >/dev/null \
  || fail "late ordinary done callback was not drained as done"
[ ! -s "${FOLLOWUP_LABEL_LOG}" ] \
  || fail "late ordinary done callback downgraded live finish: $(cat "${FOLLOWUP_LABEL_LOG}")"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven-handoffs-late-finish"
fi

# A durable worker_result.json is authoritative only when the heartbeat passes
# the same job/generation/token-digest fence as the native callback path. Phase
# 6 must consume it normally, then explicitly request cleanup of the native
# child whose outer model never emitted the final compact line.
cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"
durable_result_followup_out="$(printf '%s\n' '{
  "iid":42,
  "execution_id":1,
  "status":"done",
  "mode_actual":"fresh",
  "work_branch":"issue/42",
  "local_branch":"issue/42",
  "commit_sha":"0123456789abcdef",
  "merge_request_url":"https://gitlab.example/group/repo/-/merge_requests/9",
  "mr_action":"created",
  "wiki_url":"",
  "labels_added":["pr"],
  "labels_removed":["doing","done"],
  "summary_posted":true,
  "block_reason":"",
  "log_dir":"/private/attempt-001"
}' | \
  PROJECT=repo PROJECT_FULL=group/repo GROUP=group GITLAB_TOKEN=fake-token \
  GITLAB_HOST=gitlab.example GITLAB_API_PROTOCOL=https \
  REPO_PARENT_PATH="${FOLLOWUP_PARENT}" IID=42 \
  DRIVEN_RESULT_RECONCILE=1 \
  DRIVEN_RECONCILE_JOB_ID='batch-A:snapshot-0' \
  DRIVEN_RECONCILE_CLAIM_GENERATION=1 \
  DRIVEN_RECONCILE_CLAIM_TOKEN_SHA256="${TIMEOUT_TOKEN_SHA}" \
  DRIVEN_HANDOFF_IMPORTER="${FAKE_IMPORTER}" \
  EXPECT_HANDOFF_STATUS=done EXPECT_CAMPAIGN_LOCK="${FOLLOWUP_LOCK}" \
  EXPECT_CAMPAIGN_STATE="${FOLLOWUP_STATE}" \
  FOLLOWUP_IMPORT_LOG="${FOLLOWUP_IMPORT_LOG}" \
  FOLLOWUP_NOTIFY_LOG="${FOLLOWUP_NOTIFY_LOG}" \
  bash "${FOLLOWUP_SCRIPTS}/dispatch_followup.sh")"
jq -e '
  .callback_status == "handled"
  and .terminal_status == "done"
  and .cleanup == {
    action:"kill",
    target:"agent:req_executor:subagent:42",
    reason:"durable_worker_result_recovered"
  }
' <<<"${durable_result_followup_out}" >/dev/null \
  || fail "durable-result reconcile did not finish Phase 6 and request child cleanup"
jq -e '
  (.pending_subagents | has("42") | not)
  and .completed_iids == [42]
' "${FOLLOWUP_STATE}" >/dev/null \
  || fail "durable-result reconcile did not durably drain project pending state"
[ "$(wc -l <"${FOLLOWUP_IMPORT_LOG}" | tr -d ' ')" = 1 ] \
  || fail "durable-result reconcile did not invoke the handoff importer once"
if [ -d "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" ]; then
  mv "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs" \
    "${FOLLOWUP_REPO}/.req_executor/issues/issue-42/driven_handoffs-durable-result"
fi

cp "${FOLLOWUP_ROOT}/campaign-state-baseline.json" "${FOLLOWUP_STATE}"
: >"${FOLLOWUP_IMPORT_LOG}"

FOLLOWUP_OUTPUT="$(
  printf '%s\n' '{
    "iid":42,
    "execution_id":1,
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
  EXECUTION_ID=1 \
  CALLBACK_RUN_ID=run-42 \
  CALLBACK_CHILD_SESSION_KEY=agent:req_executor:subagent:42 \
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
