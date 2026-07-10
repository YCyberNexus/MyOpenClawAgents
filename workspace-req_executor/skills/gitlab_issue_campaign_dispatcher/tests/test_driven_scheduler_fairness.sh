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
first_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=preparing \
    bash "${RECORD}"
)"
if ! jq -e '.job_status == "preparing" and .should_spawn == true' \
  <<<"${first_claim}" >/dev/null; then
  echo "expected first preparing claim to set should_spawn=true, got ${first_claim}" >&2
  exit 1
fi
duplicate_claim="$(
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=preparing \
    bash "${RECORD}"
)"
if ! jq -e '.job_status == "preparing" and .should_spawn == false' \
  <<<"${duplicate_claim}" >/dev/null; then
  echo "expected duplicate preparing claim to set should_spawn=false, got ${duplicate_claim}" >&2
  exit 1
fi
while IFS= read -r reserved_job_id; do
  CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${reserved_job_id}" STATUS=preparing \
    bash "${RECORD}" >/dev/null
done < <(jq -r --arg a1_job_id "${a1_job_id}" \
  '.grants[].job_id | select(. != $a1_job_id)' <<<"${first_reserve}")
CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${a1_job_id}" STATUS=spawned \
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
while IFS= read -r lease_job_id; do
  lease_claim="$(
    CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${lease_job_id}" STATUS=preparing \
      NOW_EPOCH=101 bash "${RECORD}"
  )"
  jq -e '.should_spawn == true' <<<"${lease_claim}" >/dev/null
done < <(jq -r '.grants[].job_id' <<<"${lease_first_reserve}")

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

echo 'ok driven scheduler fairness'
