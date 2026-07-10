#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"
RECORD="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-driven-fairness.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/_scheduler"
mkdir -p "${CONFIG_DIR}"

# Deliberately omit EXECUTOR_MAX_CONCURRENCY: scheduler_env.sh's deployment
# default must provide the requested three executor-wide slots.
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  >"${CONFIG_DIR}/campaign_defaults.env"

CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

create_batch_fixture() {
  local batch_id="$1"
  local iids_json="$2"
  local batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"
  local matched_count=""

  mkdir -p "${batch_dir}"
  matched_count="$(jq -r 'length' <<<"${iids_json}")"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    '{
      version:1,
      batch_id:$batch_id,
      correlation_id:("correlation-" + $batch_id),
      project:"group/repo",
      selector:{type:"range",iid_min:1,iid_max:100},
      force_rerun_pr:false,
      dispatcher_callback_target:"agent:req_dispatcher:main",
      branch:"main"
    }' >"${batch_dir}/request.json"
  jq -cnS \
    --argjson iids "${iids_json}" \
    '{version:1,project:"group/repo",iids:$iids}' \
    >"${batch_dir}/snapshot.json"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --argjson matched_count "${matched_count}" \
    '{
      version:1,
      batch_id:$batch_id,
      status:"queued",
      matched_count:$matched_count,
      terminal_count:0,
      done_count:0,
      failed_count:0,
      timeout_count:0,
      skipped_count:0,
      next_snapshot_index:0,
      request_digest:"fixture-request",
      snapshot_digest:"fixture-snapshot",
      memberships:{}
    }' >"${batch_dir}/state.json"
}

create_batch_fixture A '[1,2,3]'
create_batch_fixture B '[10,11]'
jq '.batch_order = ["A","B"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" "${SCHEDULER_ROOT}/scheduler_state.json"

first_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .status == "ready"
  and .active_count == 3
  and .available_slots == 0
  and [.grants[] | {batch_id,iid}] == [
    {batch_id:"A",iid:1},
    {batch_id:"B",iid:10},
    {batch_id:"A",iid:2}
  ]
  and ([.grants[].job_id] | length) == ([.grants[].job_id] | unique | length)
  and all(.grants[];
    (.snapshot_index | type == "number")
    and .project == "group/repo"
    and .branch == "main"
    and (.entry_mode | type == "string")
    and .force_rerun_pr == false)
' <<<"${first_reserve}" >/dev/null

# Before any grant is acknowledged as preparing, a fresh reserve process must
# replay every persisted reservation in the exact physical creation order.
first_grant_order="$(jq -c '[.grants[] | {job_id,batch_id,iid}]' <<<"${first_reserve}")"
replayed_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
replayed_grant_order="$(jq -c '[.grants[] | {job_id,batch_id,iid}]' <<<"${replayed_reserve}")"
if [ "${replayed_grant_order}" != "${first_grant_order}" ]; then
  echo "expected unacknowledged grant replay order ${first_grant_order}, got ${replayed_grant_order}" >&2
  exit 1
fi
jq -e \
  --argjson first_grants "$(jq -c '.grants' <<<"${first_reserve}")" '
  .status == "ready"
  and .grants == $first_grants
  and .active_count == 3
  and .available_slots == 0
  and all(.grants[]; has("reservation_seq") | not)
' <<<"${replayed_reserve}" >/dev/null

jq -e --argjson expected_order "${first_grant_order}" '
  .round_robin_cursor == "A"
  and (.active_jobs | length) == 3
  and ([.active_jobs[].reservation_seq] | length) ==
    ([.active_jobs[].reservation_seq] | unique | length)
  and ([.active_jobs[]
    | {job_id,batch_id:.owner.batch_id,iid,reservation_seq}]
    | sort_by(.reservation_seq)
    | map(del(.reservation_seq))) == $expected_order
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
jq -e '
  .next_snapshot_index == 2
  and .memberships["0"].status == "reserved"
  and .memberships["1"].status == "reserved"
' "${SCHEDULER_ROOT}/batches/A/state.json" >/dev/null
jq -e '
  .next_snapshot_index == 1
  and .memberships["0"].status == "reserved"
' "${SCHEDULER_ROOT}/batches/B/state.json" >/dev/null

a1_job_id="$(jq -r '.grants[] | select(.batch_id == "A" and .iid == 1) | .job_id' <<<"${first_reserve}")"
reserved_scheduler_before="$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")"
reserved_batch_before="$(jq -cS . "${SCHEDULER_ROOT}/batches/A/state.json")"
set +e
reserved_spawn_output="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=spawned \
    bash "${RECORD}" 2>&1
)"
reserved_spawn_status=$?
set -e
if [ "${reserved_spawn_status}" -ne 3 ]; then
  echo "expected spawned:reserved to exit 3, got ${reserved_spawn_status}: ${reserved_spawn_output}" >&2
  exit 1
fi
[ "$(jq -cS . "${SCHEDULER_ROOT}/scheduler_state.json")" = "${reserved_scheduler_before}" ] || {
  echo "expected rejected spawned:reserved to leave scheduler state unchanged" >&2
  exit 1
}
[ "$(jq -cS . "${SCHEDULER_ROOT}/batches/A/state.json")" = "${reserved_batch_before}" ] || {
  echo "expected rejected spawned:reserved to leave batch state unchanged" >&2
  exit 1
}

first_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=preparing \
    bash "${RECORD}"
)"
if ! jq -e '
  .job_status == "preparing"
  and .should_spawn == true
  and (.claim_token | type == "string" and length > 0)
' \
  <<<"${first_claim}" >/dev/null; then
  echo "expected first preparing claim to return an actionable token, got ${first_claim}" >&2
  exit 1
fi
a1_claim_token="$(jq -r '.claim_token' <<<"${first_claim}")"
duplicate_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=preparing \
    bash "${RECORD}"
)"
if ! jq -e '
  .job_status == "preparing"
  and .should_spawn == false
  and .claim_token == null
' \
  <<<"${duplicate_claim}" >/dev/null; then
  echo "expected duplicate preparing claim to withhold an actionable token, got ${duplicate_claim}" >&2
  exit 1
fi
while IFS= read -r reserved_job_id; do
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${reserved_job_id}" STATUS=preparing \
    bash "${RECORD}" >/dev/null
done < <(jq -r --arg a1_job_id "${a1_job_id}" \
  '.grants[].job_id | select(. != $a1_job_id)' <<<"${first_reserve}")
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=spawned \
  CLAIM_TOKEN="${a1_claim_token}" \
  bash "${RECORD}" >/dev/null

set +e
running_claim_output="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=preparing \
    bash "${RECORD}" 2>&1
)"
running_claim_status=$?
set -e
if [ "${running_claim_status}" -ne 3 ]; then
  echo "expected running preparing claim to exit 3, got ${running_claim_status}: ${running_claim_output}" >&2
  exit 1
fi

full_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .status == "at_capacity"
  and .grants == []
  and .active_count == 3
  and .available_slots == 0
' <<<"${full_reserve}" >/dev/null
jq -e --arg job_id "${a1_job_id}" \
  '.active_jobs[$job_id].status == "running"' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=terminal \
  CLAIM_TOKEN="${a1_claim_token}" \
  bash "${RECORD}" >/dev/null

# This is a fresh process invocation: the next choice must start after the
# persisted cursor A, proving that the cursor is not process memory.
second_reserve="$(CONFIG_DIR="${CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .status == "ready"
  and .active_count == 3
  and .available_slots == 0
  and [.grants[] | {batch_id,iid}] == [{batch_id:"B",iid:11}]
' <<<"${second_reserve}" >/dev/null
jq -e '.round_robin_cursor == "B"' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

# Simulate a process dying after batch state has been published but before the
# final scheduler state replaces its transaction marker. A fresh invocation
# must finish that durable transaction instead of losing the reservation or
# advancing the cursor twice.
CRASH_ROOT="${TEST_ROOT}/crash-scheduler"
CRASH_CONFIG_DIR="${TEST_ROOT}/crash-config"
CRASH_BATCH_DIR="${CRASH_ROOT}/batches/X"
CRASH_BIN="${TEST_ROOT}/crash-bin"
mkdir -p "${CRASH_CONFIG_DIR}" "${CRASH_BIN}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${CRASH_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=1' \
  >"${CRASH_CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CRASH_CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
mkdir -p "${CRASH_BATCH_DIR}"
jq -cnS '{
  version:1,
  batch_id:"X",
  correlation_id:"correlation-X",
  project:"group/repo",
  selector:{type:"single",iid:42},
  force_rerun_pr:false,
  dispatcher_callback_target:"agent:req_dispatcher:main",
  branch:"main"
}' >"${CRASH_BATCH_DIR}/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
  >"${CRASH_BATCH_DIR}/snapshot.json"
jq -cnS '{
  version:1,
  batch_id:"X",
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
}' >"${CRASH_BATCH_DIR}/state.json"
jq '.batch_order = ["X"]' \
  "${CRASH_ROOT}/scheduler_state.json" \
  >"${CRASH_ROOT}/scheduler_state.next.json"
/bin/mv "${CRASH_ROOT}/scheduler_state.next.json" "${CRASH_ROOT}/scheduler_state.json"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'destination="${*: -1}"' \
  'if [ "${destination}" = "${FAIL_SCHEDULER_DEST:?}" ]; then' \
  '  count=0' \
  '  [ ! -f "${MV_COUNT_FILE:?}" ] || count="$(<"${MV_COUNT_FILE}")"' \
  '  count=$((count + 1))' \
  '  printf "%s" "${count}" >"${MV_COUNT_FILE}"' \
  '  [ "${count}" -ne 2 ] || exit 97' \
  'fi' \
  'exec /bin/mv "$@"' \
  >"${CRASH_BIN}/mv"
chmod +x "${CRASH_BIN}/mv"

set +e
PATH="${CRASH_BIN}:${PATH}" \
  FAIL_SCHEDULER_DEST="${CRASH_ROOT}/scheduler_state.json" \
  MV_COUNT_FILE="${TEST_ROOT}/crash-mv-count" \
  CONFIG_DIR="${CRASH_CONFIG_DIR}" \
  bash "${RESERVE}" >"${TEST_ROOT}/crash-reserve.out" 2>"${TEST_ROOT}/crash-reserve.err"
crash_status=$?
set -e
if [ "${crash_status}" -ne 97 ]; then
  echo "expected injected final scheduler publish failure, got ${crash_status}" >&2
  exit 1
fi
jq -e '
  .pending_transaction.version == 1
  and .pending_transaction.scheduler_state
    .active_jobs["X:snapshot-0"].reservation_seq == 1
' \
  "${CRASH_ROOT}/scheduler_state.json" >/dev/null

recovered_reserve="$(CONFIG_DIR="${CRASH_CONFIG_DIR}" bash "${RESERVE}")"
jq -e '
  .status == "ready"
  and [.grants[] | {batch_id,iid}] == [{batch_id:"X",iid:42}]
  and .active_count == 1
  and .available_slots == 0
' <<<"${recovered_reserve}" >/dev/null
jq -e '
  (.pending_transaction | not)
  and .round_robin_cursor == "X"
  and (.active_jobs | length) == 1
  and .active_jobs["X:snapshot-0"].reservation_seq == 1
' "${CRASH_ROOT}/scheduler_state.json" >/dev/null
jq -e '
  .next_snapshot_index == 1
  and .memberships["0"].status == "reserved"
' "${CRASH_BATCH_DIR}/state.json" >/dev/null

# A preparing claim is a recoverable lease. Before expiry it remains hidden;
# after expiry reserve atomically restores the owner membership and replays the
# exact original public grants in their stable reservation sequence.
LEASE_ROOT="${TEST_ROOT}/lease-scheduler"
CONFIG_DIR="${TEST_ROOT}/lease-config"
SCHEDULER_ROOT="${LEASE_ROOT}"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${LEASE_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=2' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_batch_fixture L '[21,22]'
jq '.batch_order = ["L"]' \
  "${LEASE_ROOT}/scheduler_state.json" \
  >"${LEASE_ROOT}/scheduler_state.next.json"
/bin/mv "${LEASE_ROOT}/scheduler_state.next.json" \
  "${LEASE_ROOT}/scheduler_state.json"

lease_first_reserve="$(
  CONFIG_DIR="${CONFIG_DIR}" \
    DRIVEN_PREPARING_LEASE_SECONDS=10 NOW_EPOCH=100 \
    bash "${RESERVE}"
)"
jq -e '
  [.grants[] | {batch_id,iid}] == [
    {batch_id:"L",iid:21},
    {batch_id:"L",iid:22}
  ]
' <<<"${lease_first_reserve}" >/dev/null
lease_sequences_before="$(jq -c '
  [.active_jobs[] | {job_id,reservation_seq}] | sort_by(.reservation_seq)
' "${LEASE_ROOT}/scheduler_state.json")"
lease_job_id="$(jq -r '.grants[0].job_id' <<<"${lease_first_reserve}")"
lease_other_job_id="$(jq -r '.grants[1].job_id' <<<"${lease_first_reserve}")"
lease_claim1="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=preparing \
    NOW_EPOCH=101 bash "${RECORD}"
)"
if ! jq -e '
  .should_spawn == true
  and (.claim_token | type == "string" and length > 0)
' <<<"${lease_claim1}" >/dev/null; then
  echo "expected lease claim1 to return an actionable token, got ${lease_claim1}" >&2
  exit 1
fi
lease_claim1_token="$(jq -r '.claim_token' <<<"${lease_claim1}")"
lease_other_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_other_job_id}" STATUS=preparing \
    NOW_EPOCH=101 bash "${RECORD}"
)"
jq -e '
  .should_spawn == true
  and (.claim_token | type == "string" and length > 0)
' <<<"${lease_other_claim}" >/dev/null

before_lease_expiry="$(
  CONFIG_DIR="${CONFIG_DIR}" \
    DRIVEN_PREPARING_LEASE_SECONDS=10 NOW_EPOCH=110 \
    bash "${RESERVE}"
)"
if ! jq -e '
  .status == "at_capacity"
  and .grants == []
  and .active_count == 2
  and .available_slots == 0
' <<<"${before_lease_expiry}" >/dev/null; then
  echo "expected preparing grants to stay claimed before lease expiry, got ${before_lease_expiry}" >&2
  exit 1
fi

# record must reject an expired token even if reserve has not yet performed the
# lease rollback. The rejected stale transition may not mutate either file.
expired_record_scheduler_before="$(jq -cS . "${LEASE_ROOT}/scheduler_state.json")"
expired_record_batch_before="$(jq -cS . "${LEASE_ROOT}/batches/L/state.json")"
set +e
expired_record_output="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=spawned \
    CLAIM_TOKEN="${lease_claim1_token}" \
    DRIVEN_PREPARING_LEASE_SECONDS=10 NOW_EPOCH=112 \
    bash "${RECORD}" 2>&1
)"
expired_record_status=$?
set -e
if [ "${expired_record_status}" -ne 3 ]; then
  echo "expected record to reject an expired preparing token with exit 3, got ${expired_record_status}: ${expired_record_output}" >&2
  exit 1
fi
[ "$(jq -cS . "${LEASE_ROOT}/scheduler_state.json")" = "${expired_record_scheduler_before}" ] || {
  echo "expected expired token rejection to leave scheduler state unchanged" >&2
  exit 1
}
[ "$(jq -cS . "${LEASE_ROOT}/batches/L/state.json")" = "${expired_record_batch_before}" ] || {
  echo "expected expired token rejection to leave batch state unchanged" >&2
  exit 1
}

after_lease_expiry="$(
  CONFIG_DIR="${CONFIG_DIR}" \
    DRIVEN_PREPARING_LEASE_SECONDS=10 NOW_EPOCH=112 \
    bash "${RESERVE}"
)"
expected_lease_replay="$(jq -c '.grants' <<<"${lease_first_reserve}")"
actual_lease_replay="$(jq -c '.grants' <<<"${after_lease_expiry}")"
if [ "${actual_lease_replay}" != "${expected_lease_replay}" ]; then
  echo "expected expired preparing grants to replay as ${expected_lease_replay}, got ${actual_lease_replay}" >&2
  exit 1
fi
lease_sequences_after="$(jq -c '
  [.active_jobs[] | {job_id,reservation_seq}] | sort_by(.reservation_seq)
' "${LEASE_ROOT}/scheduler_state.json")"
if [ "${lease_sequences_after}" != "${lease_sequences_before}" ]; then
  echo "expected preparing lease recovery to preserve reservation sequence ${lease_sequences_before}, got ${lease_sequences_after}" >&2
  exit 1
fi
jq -e '
  [.active_jobs[].status] == ["reserved","reserved"]
' "${LEASE_ROOT}/scheduler_state.json" >/dev/null
jq -e '
  [.memberships[].status] == ["reserved","reserved"]
' "${LEASE_ROOT}/batches/L/state.json" >/dev/null
jq -e --arg job_id "${lease_job_id}" '
  .active_jobs[$job_id].claim_generation == 1
  and .active_jobs[$job_id].claim_token == null
' "${LEASE_ROOT}/scheduler_state.json" >/dev/null

lease_claim2="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=preparing \
    NOW_EPOCH=113 bash "${RECORD}"
)"
if ! jq -e '
  .should_spawn == true
  and (.claim_token | type == "string" and length > 0)
' <<<"${lease_claim2}" >/dev/null; then
  echo "expected lease claim2 to return an actionable token, got ${lease_claim2}" >&2
  exit 1
fi
lease_claim2_token="$(jq -r '.claim_token' <<<"${lease_claim2}")"
if [ "${lease_claim2_token}" = "${lease_claim1_token}" ]; then
  echo "expected lease claim2 token to differ from claim1 token" >&2
  exit 1
fi
jq -e --arg job_id "${lease_job_id}" --arg token "${lease_claim2_token}" '
  .active_jobs[$job_id].claim_generation == 2
  and .active_jobs[$job_id].claim_token == $token
' "${LEASE_ROOT}/scheduler_state.json" >/dev/null

for stale_status in spawned launch_failed terminal; do
  stale_scheduler_before="$(jq -cS . "${LEASE_ROOT}/scheduler_state.json")"
  stale_batch_before="$(jq -cS . "${LEASE_ROOT}/batches/L/state.json")"
  set +e
  stale_output="$(
    CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS="${stale_status}" \
      CLAIM_TOKEN="${lease_claim1_token}" \
      DRIVEN_PREPARING_LEASE_SECONDS=10 NOW_EPOCH=114 \
      bash "${RECORD}" 2>&1
  )"
  stale_status_code=$?
  set -e
  if [ "${stale_status_code}" -ne 3 ]; then
    echo "expected stale claim1 ${stale_status} to exit 3, got ${stale_status_code}: ${stale_output}" >&2
    exit 1
  fi
  [ "$(jq -cS . "${LEASE_ROOT}/scheduler_state.json")" = "${stale_scheduler_before}" ] || {
    echo "expected stale claim1 ${stale_status} to leave scheduler state unchanged" >&2
    exit 1
  }
  [ "$(jq -cS . "${LEASE_ROOT}/batches/L/state.json")" = "${stale_batch_before}" ] || {
    echo "expected stale claim1 ${stale_status} to leave batch state unchanged" >&2
    exit 1
  }
done

claim2_spawned="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=spawned \
    CLAIM_TOKEN="${lease_claim2_token}" NOW_EPOCH=115 \
    bash "${RECORD}"
)"
jq -e '.job_status == "running"' <<<"${claim2_spawned}" >/dev/null
claim2_spawned_replay="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=spawned \
    CLAIM_TOKEN="${lease_claim2_token}" NOW_EPOCH=116 \
    bash "${RECORD}"
)"
jq -e '.job_status == "running"' <<<"${claim2_spawned_replay}" >/dev/null
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=terminal \
  CLAIM_TOKEN="${lease_claim2_token}" NOW_EPOCH=117 \
  bash "${RECORD}" >/dev/null
jq -e --arg job_id "${lease_job_id}" '
  (.active_jobs | has($job_id) | not)
' "${LEASE_ROOT}/scheduler_state.json" >/dev/null
jq -e '
  .memberships["0"].status == "terminal"
' "${LEASE_ROOT}/batches/L/state.json" >/dev/null

set +e
invalid_lease_output="$(
  CONFIG_DIR="${CONFIG_DIR}" \
    DRIVEN_PREPARING_LEASE_SECONDS=0 NOW_EPOCH=112 \
    bash "${RESERVE}" 2>&1
)"
invalid_lease_status=$?
set -e
if [ "${invalid_lease_status}" -ne 2 ]; then
  echo "expected zero preparing lease to exit 2, got ${invalid_lease_status}: ${invalid_lease_output}" >&2
  exit 1
fi

# Migrate an old version=1 normal state before strict schema validation. Old
# reserved work remains replayable, old preparing rolls back to reserved, and
# old running keeps its physical lock without becoming spawnable again.
MIGRATION_ROOT="${TEST_ROOT}/legacy-normal-scheduler"
CONFIG_DIR="${TEST_ROOT}/legacy-normal-config"
SCHEDULER_ROOT="${MIGRATION_ROOT}"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${MIGRATION_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_batch_fixture R '[31]'
create_batch_fixture P '[32]'
create_batch_fixture N '[33]'

for legacy_spec in 'R 31 reserved' 'P 32 preparing' 'N 33 running'; do
  legacy_batch_id="${legacy_spec%% *}"
  legacy_rest="${legacy_spec#* }"
  legacy_iid="${legacy_rest%% *}"
  legacy_status="${legacy_rest#* }"
  legacy_job_id="${legacy_batch_id}:snapshot-0"
  jq \
    --arg status "${legacy_status}" \
    --arg job_id "${legacy_job_id}" \
    --argjson iid "${legacy_iid}" '
    .status = "running"
    | .next_snapshot_index = 1
    | .memberships["0"] = {
        snapshot_index:0,
        iid:$iid,
        status:$status,
        job_id:$job_id
      }
  ' "${MIGRATION_ROOT}/batches/${legacy_batch_id}/state.json" \
    >"${MIGRATION_ROOT}/batches/${legacy_batch_id}/state.next.json"
  /bin/mv "${MIGRATION_ROOT}/batches/${legacy_batch_id}/state.next.json" \
    "${MIGRATION_ROOT}/batches/${legacy_batch_id}/state.json"
done

jq -cnS '{
  version:1,
  round_robin_cursor:"N",
  batch_order:["R","P","N"],
  active_jobs:{
    "R:snapshot-0":{
      job_id:"R:snapshot-0",physical_key:"group/repo#31",
      project:"group/repo",iid:31,branch:"main",entry_mode:"auto",
      force_rerun_pr:false,status:"reserved",reserved_at:100,updated_at:100,
      owner:{batch_id:"R",snapshot_index:0},
      memberships:[{batch_id:"R",snapshot_index:0}]
    },
    "P:snapshot-0":{
      job_id:"P:snapshot-0",physical_key:"group/repo#32",
      project:"group/repo",iid:32,branch:"main",entry_mode:"auto",
      force_rerun_pr:false,status:"preparing",reserved_at:100,updated_at:101,
      owner:{batch_id:"P",snapshot_index:0},
      memberships:[{batch_id:"P",snapshot_index:0}]
    },
    "N:snapshot-0":{
      job_id:"N:snapshot-0",physical_key:"group/repo#33",
      project:"group/repo",iid:33,branch:"main",entry_mode:"auto",
      force_rerun_pr:false,status:"running",reserved_at:90,updated_at:102,
      owner:{batch_id:"N",snapshot_index:0},
      memberships:[{batch_id:"N",snapshot_index:0}]
    }
  }
}' >"${MIGRATION_ROOT}/scheduler_state.json"

set +e
legacy_normal_output="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=200 bash "${RESERVE}" 2>&1
)"
legacy_normal_status=$?
set -e
if [ "${legacy_normal_status}" -ne 0 ]; then
  echo "expected legacy normal state migration to succeed, got ${legacy_normal_status}: ${legacy_normal_output}" >&2
  exit 1
fi
if ! jq -e '
  [.grants[] | {batch_id,iid}] == [
    {batch_id:"P",iid:32},
    {batch_id:"R",iid:31}
  ]
  and .active_count == 3
  and .available_slots == 0
' <<<"${legacy_normal_output}" >/dev/null; then
  echo "expected migrated legacy reserved grants in deterministic order, got ${legacy_normal_output}" >&2
  exit 1
fi
jq -e '
  (.pending_transaction | not)
  and .active_jobs["N:snapshot-0"].reservation_seq == 1
  and .active_jobs["N:snapshot-0"].status == "running"
  and .active_jobs["N:snapshot-0"].legacy_running == true
  and .active_jobs["N:snapshot-0"].claim_generation == 0
  and .active_jobs["N:snapshot-0"].claim_token == null
  and .active_jobs["P:snapshot-0"].reservation_seq == 2
  and .active_jobs["P:snapshot-0"].status == "reserved"
  and .active_jobs["P:snapshot-0"].claim_generation == 0
  and .active_jobs["P:snapshot-0"].claim_token == null
  and .active_jobs["R:snapshot-0"].reservation_seq == 3
  and .active_jobs["R:snapshot-0"].status == "reserved"
  and .active_jobs["R:snapshot-0"].claim_generation == 0
  and .active_jobs["R:snapshot-0"].claim_token == null
' "${MIGRATION_ROOT}/scheduler_state.json" >/dev/null
jq -e '.memberships["0"].status == "reserved"' \
  "${MIGRATION_ROOT}/batches/P/state.json" >/dev/null
jq -e '.memberships["0"].status == "running"' \
  "${MIGRATION_ROOT}/batches/N/state.json" >/dev/null

legacy_p_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID='P:snapshot-0' STATUS=preparing \
    NOW_EPOCH=201 bash "${RECORD}"
)"
jq -e '
  .should_spawn == true
  and (.claim_token | type == "string" and length > 0)
' <<<"${legacy_p_claim}" >/dev/null

legacy_running_scheduler_before="$(jq -cS . "${MIGRATION_ROOT}/scheduler_state.json")"
legacy_running_batch_before="$(jq -cS . "${MIGRATION_ROOT}/batches/N/state.json")"
for forbidden_legacy_status in spawned launch_failed; do
  set +e
  forbidden_legacy_output="$(
    CONFIG_DIR="${CONFIG_DIR}" JOB_ID='N:snapshot-0' STATUS="${forbidden_legacy_status}" \
      NOW_EPOCH=202 bash "${RECORD}" 2>&1
  )"
  forbidden_legacy_code=$?
  set -e
  if [ "${forbidden_legacy_code}" -ne 3 ]; then
    echo "expected legacy running ${forbidden_legacy_status} to exit 3, got ${forbidden_legacy_code}: ${forbidden_legacy_output}" >&2
    exit 1
  fi
  [ "$(jq -cS . "${MIGRATION_ROOT}/scheduler_state.json")" = "${legacy_running_scheduler_before}" ] || {
    echo "expected forbidden legacy running transition to leave scheduler state unchanged" >&2
    exit 1
  }
  [ "$(jq -cS . "${MIGRATION_ROOT}/batches/N/state.json")" = "${legacy_running_batch_before}" ] || {
    echo "expected forbidden legacy running transition to leave batch state unchanged" >&2
    exit 1
  }
done
CONFIG_DIR="${CONFIG_DIR}" JOB_ID='N:snapshot-0' STATUS=terminal \
  NOW_EPOCH=203 bash "${RECORD}" >/dev/null
jq -e '.active_jobs | has("N:snapshot-0") | not' \
  "${MIGRATION_ROOT}/scheduler_state.json" >/dev/null
jq -e '.memberships["0"].status == "terminal"' \
  "${MIGRATION_ROOT}/batches/N/state.json" >/dev/null

# Once importer installs a finalization fence, preparing-lease recovery must
# not mint a new claim or erase the claim identity carried by the handoff.
SCHEDULER_ROOT="${TEST_ROOT}/finalizing-preparing-scheduler"
CONFIG_DIR="${TEST_ROOT}/finalizing-preparing-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_batch_fixture FP '[88]'
jq '.batch_order = ["FP"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
finalizing_reserve="$(CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=1 bash "${RESERVE}")"
finalizing_job_id="$(jq -r '.grants[0].job_id' <<<"${finalizing_reserve}")"
finalizing_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${finalizing_job_id}" STATUS=preparing \
    NOW_EPOCH=2 bash "${RECORD}"
)"
finalizing_token="$(jq -r '.claim_token' <<<"${finalizing_claim}")"
finalizing_event="${finalizing_job_id}:claim-1:terminal-1"
jq \
  --arg job_id "${finalizing_job_id}" \
  --arg event_id "${finalizing_event}" \
  --arg token "${finalizing_token}" '
  .active_jobs[$job_id].finalization = {
    event_id:$event_id,
    claim_generation:1,
    claim_token:$token,
    membership_keys:["FP:snapshot-0"]
  }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.finalizing.json"
mv "${SCHEDULER_ROOT}/scheduler_state.finalizing.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

# Migration may need to complete inside an older pending transaction. The
# finalization fence is already current-schema data and must survive both the
# legacy field migration and transaction recovery byte-for-byte canonically.
finalization_before_recovery="$(jq -cS \
  --arg job_id "${finalizing_job_id}" \
  '.active_jobs[$job_id].finalization' \
  "${SCHEDULER_ROOT}/scheduler_state.json")"
jq --arg job_id "${finalizing_job_id}" '
  . as $persisted
  | .pending_transaction = {
      version:1,
      scheduler_state:($persisted
        | del(.pending_transaction)
        | del(.active_jobs[$job_id].reservation_seq)),
      batch_states:{}
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.pending-finalization.json"
mv "${SCHEDULER_ROOT}/scheduler_state.pending-finalization.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=3 \
DRIVEN_SCHEDULER_MIGRATION_ONLY=1 bash "${RESERVE}" >/dev/null
finalization_after_recovery="$(jq -cS \
  --arg job_id "${finalizing_job_id}" \
  '.active_jobs[$job_id].finalization' \
  "${SCHEDULER_ROOT}/scheduler_state.json")"
[ "${finalization_after_recovery}" = "${finalization_before_recovery}" ] || {
  echo "migration or transaction recovery rewrote finalization fence" >&2
  exit 1
}
jq -e \
  --arg job_id "${finalizing_job_id}" \
  --arg event_id "${finalizing_event}" \
  --arg token "${finalizing_token}" '
  (has("pending_transaction") | not)
  and .active_jobs[$job_id].reservation_seq == 1
  and .active_jobs[$job_id].finalization == {
    event_id:$event_id,
    claim_generation:1,
    claim_token:$token,
    membership_keys:["FP:snapshot-0"]
  }
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null || {
  echo "recovered finalization fence has an inconsistent schema" >&2
  exit 1
}
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/finalizing-preparing-before-expiry.json"
CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=5000 \
DRIVEN_PREPARING_LEASE_SECONDS=10 bash "${RESERVE}" >/dev/null
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/finalizing-preparing-before-expiry.json" \
  || {
    echo "preparing lease recovery rewrote a finalization claim" >&2
    exit 1
  }
jq -e \
  --arg job_id "${finalizing_job_id}" \
  --arg token "${finalizing_token}" '
  .active_jobs[$job_id].status == "preparing"
  and .active_jobs[$job_id].claim_generation == 1
  and .active_jobs[$job_id].claim_token == $token
  and .active_jobs[$job_id].finalization.event_id == (
    $job_id + ":claim-1:terminal-1")
' "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${finalizing_job_id}" STATUS=terminal \
  CLAIM_TOKEN="${finalizing_token}" \
  FINALIZATION_EVENT_ID="${finalizing_event}" \
  NOW_EPOCH=5001 DRIVEN_PREPARING_LEASE_SECONDS=10 \
  bash "${RECORD}" >/dev/null || {
    echo "expired preparing finalization could not complete terminal" >&2
    exit 1
  }
jq -e --arg job_id "${finalizing_job_id}" \
  '.active_jobs | has($job_id) | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

# A reserved claim-0 job may be finalized as a preflight skip. The fence must
# suppress grant replay, while terminal remains valid without CLAIM_TOKEN.
SCHEDULER_ROOT="${TEST_ROOT}/finalizing-reserved-scheduler"
CONFIG_DIR="${TEST_ROOT}/finalizing-reserved-config"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=3' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
create_batch_fixture FR '[89]'
jq '.batch_order = ["FR"]' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.next.json"
mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
finalizing_reserved="$(CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=1 bash "${RESERVE}")"
reserved_job_id="$(jq -r '.grants[0].job_id' <<<"${finalizing_reserved}")"
reserved_event="${reserved_job_id}:claim-0:terminal-1"
jq \
  --arg job_id "${reserved_job_id}" \
  --arg event_id "${reserved_event}" '
  .active_jobs[$job_id].finalization = {
    event_id:$event_id,
    claim_generation:0,
    claim_token:null,
    membership_keys:["FR:snapshot-0"]
  }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.finalizing.json"
mv "${SCHEDULER_ROOT}/scheduler_state.finalizing.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
reserved_fence_replay="$(
  CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=2 bash "${RESERVE}"
)"
jq -e '.grants == [] and .active_count == 1' \
  <<<"${reserved_fence_replay}" >/dev/null || {
    echo "reserved finalization job was replayed as a grant" >&2
    exit 1
  }
env -u CLAIM_TOKEN \
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${reserved_job_id}" STATUS=terminal \
  FINALIZATION_EVENT_ID="${reserved_event}" NOW_EPOCH=3 \
  bash "${RECORD}" >/dev/null
jq -e --arg job_id "${reserved_job_id}" \
  '.active_jobs | has($job_id) | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null

echo 'ok driven scheduler fairness'
