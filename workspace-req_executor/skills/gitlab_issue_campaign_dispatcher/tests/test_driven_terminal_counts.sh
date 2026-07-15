#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECORD="${SKILL_DIR}/scripts/record_driven_batch_launch.sh"
RECONCILE="${SKILL_DIR}/scripts/reconcile_driven_terminal_counts.sh"
RESERVE="${SKILL_DIR}/scripts/reserve_driven_batch_items.sh"

fail() {
  echo "test_driven_terminal_counts.sh: $*" >&2
  exit 1
}

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-terminal-counts.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
mkdir -p "${CONFIG_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}" \
  'EXECUTOR_MAX_CONCURRENCY=4' \
  >"${CONFIG_DIR}/campaign_defaults.env"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null

SCHEDULER_STATE='{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[]}'
reservation_seq=0
for terminal_status in done failed timeout skipped; do
  reservation_seq=$((reservation_seq + 1))
  batch_id="batch-${terminal_status}"
  job_id="${batch_id}:snapshot-0"
  claim_token="claim-${terminal_status}"
  batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"
  mkdir -p "${batch_dir}"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg job_id "${job_id}" \
    --argjson iid "${reservation_seq}" '{
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
          iid:$iid,
          status:"running",
          job_id:$job_id
        }
      }
    }' >"${batch_dir}/state.json"
  SCHEDULER_STATE="$(jq -c \
    --arg batch_id "${batch_id}" \
    --arg job_id "${job_id}" \
    --arg claim_token "${claim_token}" \
    --argjson iid "${reservation_seq}" \
    --argjson reservation_seq "${reservation_seq}" '
      .batch_order += [$batch_id]
      | .active_jobs[$job_id] = {
          job_id:$job_id,
          physical_key:("group/repo#" + ($iid | tostring)),
          project:"group/repo",
          iid:$iid,
          branch:"main",
          entry_mode:"auto",
          force_rerun_pr:false,
          auto_merge:false,
          merge_target_branch:null,
          status:"running",
          reservation_seq:$reservation_seq,
          claim_generation:1,
          claim_token:$claim_token,
          reserved_at:1,
          updated_at:2,
          owner:{batch_id:$batch_id,snapshot_index:0},
          memberships:[{batch_id:$batch_id,snapshot_index:0}]
        }
    ' <<<"${SCHEDULER_STATE}")"
done
printf '%s\n' "${SCHEDULER_STATE}" >"${SCHEDULER_ROOT}/scheduler_state.json"

cp "${SCHEDULER_ROOT}/scheduler_state.json" "${TEST_ROOT}/before-missing-status.json"
if CONFIG_DIR="${CONFIG_DIR}" \
  JOB_ID='batch-done:snapshot-0' \
  STATUS=terminal \
  CLAIM_TOKEN=claim-done \
  bash "${RECORD}" >"${TEST_ROOT}/missing-status.out" \
    2>"${TEST_ROOT}/missing-status.err"; then
  fail "terminal transition accepted a missing TERMINAL_STATUS"
fi
grep -Fq 'TERMINAL_STATUS must be done, failed, timeout, or skipped' \
  "${TEST_ROOT}/missing-status.err" \
  || fail "missing TERMINAL_STATUS did not fail with the contract error"
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/before-missing-status.json" \
  || fail "missing TERMINAL_STATUS mutated scheduler state"

for terminal_status in done failed timeout skipped; do
  batch_id="batch-${terminal_status}"
  job_id="${batch_id}:snapshot-0"
  CONFIG_DIR="${CONFIG_DIR}" \
    JOB_ID="${job_id}" \
    STATUS=terminal \
    TERMINAL_STATUS="${terminal_status}" \
    CLAIM_TOKEN="claim-${terminal_status}" \
    bash "${RECORD}" >/dev/null

  done_count=0
  failed_count=0
  timeout_count=0
  skipped_count=0
  case "${terminal_status}" in
    done) done_count=1 ;;
    failed) failed_count=1 ;;
    timeout) timeout_count=1 ;;
    skipped) skipped_count=1 ;;
  esac
  jq -e \
    --arg terminal_status "${terminal_status}" \
    --argjson done_count "${done_count}" \
    --argjson failed_count "${failed_count}" \
    --argjson timeout_count "${timeout_count}" \
    --argjson skipped_count "${skipped_count}" '
      .status == "completed"
      and .matched_count == 1
      and .terminal_count == 1
      and .done_count == $done_count
      and .failed_count == $failed_count
      and .timeout_count == $timeout_count
      and .skipped_count == $skipped_count
      and (.done_count + .failed_count + .timeout_count + .skipped_count
        == .terminal_count)
      and .memberships["0"].status == "terminal"
      and .memberships["0"].terminal_status == $terminal_status
    ' "${SCHEDULER_ROOT}/batches/${batch_id}/state.json" >/dev/null \
    || fail "${terminal_status} terminal outcome was not counted exactly once"
  jq -e --arg job_id "${job_id}" '.active_jobs | has($job_id) | not' \
    "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
    || fail "${terminal_status} terminal transition did not release its slot"
done

# Non-terminal record actions must not stamp the current counter version onto
# an arithmetically self-consistent state whose categories disagree with the
# actual memberships.
CORRUPT_BATCH_ID='batch-record-counter-corrupt'
CORRUPT_JOB_ID="${CORRUPT_BATCH_ID}:snapshot-1"
CORRUPT_BATCH_DIR="${SCHEDULER_ROOT}/batches/${CORRUPT_BATCH_ID}"
mkdir -p "${CORRUPT_BATCH_DIR}"
jq -cnS --arg batch_id "${CORRUPT_BATCH_ID}" --arg job_id "${CORRUPT_JOB_ID}" '{
  version:1,
  batch_id:$batch_id,
  status:"running",
  matched_count:2,
  terminal_count:1,
  done_count:0,
  failed_count:1,
  timeout_count:0,
  skipped_count:0,
  next_snapshot_index:2,
  request_digest:"fixture-request",
  snapshot_digest:"fixture-snapshot",
  memberships:{
    "0":{
      snapshot_index:0,
      iid:90,
      status:"terminal",
      terminal_status:"done",
      job_id:"batch-record-counter-corrupt:snapshot-0"
    },
    "1":{
      snapshot_index:1,
      iid:91,
      status:"reserved",
      job_id:$job_id
    }
  }
}' >"${CORRUPT_BATCH_DIR}/state.json"
jq --arg batch_id "${CORRUPT_BATCH_ID}" --arg job_id "${CORRUPT_JOB_ID}" '
  .batch_order += [$batch_id]
  | .active_jobs[$job_id] = {
      job_id:$job_id,
      physical_key:"group/repo#91",
      project:"group/repo",
      iid:91,
      branch:"main",
      entry_mode:"auto",
      force_rerun_pr:false,
      auto_merge:false,
      merge_target_branch:null,
      status:"reserved",
      reservation_seq:5,
      claim_generation:0,
      claim_token:null,
      reserved_at:1,
      updated_at:2,
      owner:{batch_id:$batch_id,snapshot_index:1},
      memberships:[{batch_id:$batch_id,snapshot_index:1}]
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.counter-corrupt.json"
mv "${SCHEDULER_ROOT}/scheduler_state.counter-corrupt.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
cp "${CORRUPT_BATCH_DIR}/state.json" "${TEST_ROOT}/counter-corrupt.before.json"
cp "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/counter-corrupt.scheduler.before.json"
if CONFIG_DIR="${CONFIG_DIR}" JOB_ID="${CORRUPT_JOB_ID}" STATUS=preparing \
  NOW_EPOCH=10 bash "${RECORD}" >"${TEST_ROOT}/counter-corrupt.out" \
    2>"${TEST_ROOT}/counter-corrupt.err"; then
  fail "record action stamped version 1 onto membership-inconsistent counters"
fi
grep -Fq 'inconsistent terminal outcomes' "${TEST_ROOT}/counter-corrupt.err" \
  || fail "record action did not report membership-inconsistent counters"
cmp -s "${CORRUPT_BATCH_DIR}/state.json" \
  "${TEST_ROOT}/counter-corrupt.before.json" \
  || fail "rejected counter corruption mutated the batch state"
cmp -s "${SCHEDULER_ROOT}/scheduler_state.json" \
  "${TEST_ROOT}/counter-corrupt.scheduler.before.json" \
  || fail "rejected counter corruption mutated scheduler state"
jq '
  .terminal_counts_version = 1
  | .done_count = 1
  | .failed_count = 0
' "${CORRUPT_BATCH_DIR}/state.json" >"${CORRUPT_BATCH_DIR}/state.current.json"
mv "${CORRUPT_BATCH_DIR}/state.current.json" "${CORRUPT_BATCH_DIR}/state.json"
jq --arg batch_id "${CORRUPT_BATCH_ID}" --arg job_id "${CORRUPT_JOB_ID}" '
  .batch_order -= [$batch_id]
  | del(.active_jobs[$job_id])
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.after-counter-test.json"
mv "${SCHEDULER_ROOT}/scheduler_state.after-counter-test.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"

GLOBAL_RECONCILE="$(CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=100 bash "${RECONCILE}")"
jq -e '
  .status == "reconciled"
  and .scanned == 0
  and .repaired == 0
  and .unresolved == 0
' <<<"${GLOBAL_RECONCILE}" >/dev/null \
  || fail "global migration did not recognize current-format terminal states"
jq -e '
  .version == 1
  and .status == "complete"
  and .pending_batch_ids == []
  and .updated_at == 100
' "${SCHEDULER_ROOT}/terminal-count-reconcile-v1.json" >/dev/null \
  || fail "global migration did not persist a strict completion marker"
GLOBAL_REPLAY="$(CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=101 bash "${RECONCILE}")"
jq -e '
  .status == "reconciled"
  and .scanned == 0
  and .repaired == 0
  and .unresolved == 0
' <<<"${GLOBAL_REPLAY}" >/dev/null \
  || fail "completed migration marker did not make later heartbeat scans constant-time"

MIXED_BATCH_DIR="${SCHEDULER_ROOT}/batches/batch-mixed"
mkdir -p "${MIXED_BATCH_DIR}"
jq -cnS '{
  version:1,
  batch_id:"batch-mixed",
  status:"running",
  matched_count:2,
  terminal_count:1,
  done_count:0,
  failed_count:0,
  timeout_count:0,
  skipped_count:0,
  next_snapshot_index:2,
  request_digest:"fixture-request",
  snapshot_digest:"fixture-snapshot",
  memberships:{
    "0":{
      snapshot_index:0,
      iid:101,
      status:"terminal",
      job_id:"batch-mixed:snapshot-0"
    },
    "1":{
      snapshot_index:1,
      iid:102,
      status:"running",
      job_id:"batch-mixed:snapshot-1"
    }
  }
}' >"${MIXED_BATCH_DIR}/state.json"
jq '
  .batch_order += ["batch-mixed"]
  | .active_jobs["batch-mixed:snapshot-1"] = {
      job_id:"batch-mixed:snapshot-1",
      physical_key:"group/repo#102",
      project:"group/repo",
      iid:102,
      branch:"main",
      entry_mode:"auto",
      force_rerun_pr:false,
      auto_merge:false,
      merge_target_branch:null,
      status:"running",
      reservation_seq:5,
      claim_generation:1,
      claim_token:"claim-mixed",
      reserved_at:1,
      updated_at:2,
      owner:{batch_id:"batch-mixed",snapshot_index:1},
      memberships:[{batch_id:"batch-mixed",snapshot_index:1}]
    }
' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.mixed.json"
mv "${SCHEDULER_ROOT}/scheduler_state.mixed.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
jq -cnS '{
  version:1,
  event_id:"batch-mixed:snapshot-0:terminal-1",
  body:{
    batch_id:"batch-mixed",
    event_id:"batch-mixed:snapshot-0:terminal-1",
    snapshot_index:0,
    iid:101,
    status:"failed"
  }
}' >"${SCHEDULER_ROOT}/callback_archive/batch-mixed:snapshot-0:terminal-1.json"

MIXED_RECONCILE="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-mixed"]' \
  bash "${RECONCILE}"
)"
jq -e '
  .status == "reconciled"
  and .scanned == 1
  and .repaired == 1
  and .unresolved == 0
' <<<"${MIXED_RECONCILE}" >/dev/null \
  || fail "rolling-upgrade terminal outcome was not reconciled"
jq -e '
  .terminal_count == 1
  and .done_count == 0
  and .failed_count == 1
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].terminal_status == "failed"
' "${MIXED_BATCH_DIR}/state.json" >/dev/null \
  || fail "legacy failed membership was not backfilled from callback evidence"

CONFIG_DIR="${CONFIG_DIR}" \
  JOB_ID='batch-mixed:snapshot-1' \
  STATUS=terminal \
  TERMINAL_STATUS=done \
  CLAIM_TOKEN=claim-mixed \
  bash "${RECORD}" >/dev/null
jq -e '
  .status == "completed"
  and .terminal_count == 2
  and .done_count == 1
  and .failed_count == 1
  and .timeout_count == 0
  and .skipped_count == 0
  and (.done_count + .failed_count + .timeout_count + .skipped_count
    == .terminal_count)
  and .memberships["0"].terminal_status == "failed"
  and .memberships["1"].terminal_status == "done"
' "${MIXED_BATCH_DIR}/state.json" >/dev/null \
  || fail "mixed legacy/new terminal outcomes were counted inconsistently"

create_legacy_terminal_batch() {
  local batch_id="$1" iid="$2" batch_dir
  batch_dir="${SCHEDULER_ROOT}/batches/${batch_id}"
  mkdir -p "${batch_dir}"
  jq -cnS --arg batch_id "${batch_id}" --argjson iid "${iid}" '{
    version:1,
    batch_id:$batch_id,
    status:"completed",
    matched_count:1,
    terminal_count:1,
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
        iid:$iid,
        status:"terminal",
        job_id:($batch_id + ":snapshot-0")
      }
    }
  }' >"${batch_dir}/state.json"
}

write_terminal_evidence() {
  local target_dir="$1" batch_id="$2" iid="$3" status="$4"
  local event_id="${batch_id}:snapshot-0:terminal-1"
  jq -cnS \
    --arg batch_id "${batch_id}" \
    --arg event_id "${event_id}" \
    --argjson iid "${iid}" \
    --arg status "${status}" '{
      version:1,
      event_id:$event_id,
      body:{
        batch_id:$batch_id,
        event_id:$event_id,
        snapshot_index:0,
        iid:$iid,
        status:$status
      }
  }' >"${target_dir}/${event_id}.json"
}

# A complete global marker is observational only. If a rolling old writer later
# republishes a state without the embedded version, the next global pass must
# discover and repair it instead of skipping history forever.
create_legacy_terminal_batch batch-late-after-marker 199
write_terminal_evidence "${SCHEDULER_ROOT}/callback_archive" \
  batch-late-after-marker 199 failed
LATE_GLOBAL_RECONCILE="$(CONFIG_DIR="${CONFIG_DIR}" NOW_EPOCH=102 bash "${RECONCILE}")"
jq -e '
  .status == "reconciled"
  and .scanned == 1
  and .repaired == 1
  and .unresolved == 0
' <<<"${LATE_GLOBAL_RECONCILE}" >/dev/null \
  || fail "complete marker hid a late old-format batch state"
jq -e '
  .terminal_counts_version == 1
  and .terminal_count == 1
  and .failed_count == 1
  and .memberships["0"].terminal_status == "failed"
' "${SCHEDULER_ROOT}/batches/batch-late-after-marker/state.json" >/dev/null \
  || fail "late old-format state was not classified after a complete marker"

# A version marker and an arithmetically self-consistent total are not enough:
# every aggregate must equal the outcome categories derived from memberships.
# Otherwise a corrupt state could be skipped by every future heartbeat.
create_legacy_terminal_batch batch-wrong-derived-counts 197
WRONG_COUNTS_BATCH_DIR="${SCHEDULER_ROOT}/batches/batch-wrong-derived-counts"
jq '
  .terminal_counts_version = 1
  | .memberships["0"].terminal_status = "done"
' "${WRONG_COUNTS_BATCH_DIR}/state.json" \
  >"${WRONG_COUNTS_BATCH_DIR}/state.current.json"
mv "${WRONG_COUNTS_BATCH_DIR}/state.current.json" \
  "${WRONG_COUNTS_BATCH_DIR}/state.json"
WRONG_COUNTS_RECONCILE="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  NOW_EPOCH=102 \
  bash "${RECONCILE}"
)"
jq -e '
  .status == "reconciled"
  and .scanned == 1
  and .repaired == 1
  and .unresolved == 0
' <<<"${WRONG_COUNTS_RECONCILE}" >/dev/null \
  || fail "versioned counters that disagreed with memberships were skipped"
jq -e '
  .terminal_counts_version == 1
  and .terminal_count == 1
  and .done_count == 1
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
' "${WRONG_COUNTS_BATCH_DIR}/state.json" >/dev/null \
  || fail "membership-derived counters were not repaired"

# Simulate a rolling old transaction that exists after a complete marker. The
# first phase sees only the current-format outer state; migration then
# republishes legacy terminal bytes. The helper must notice pending_transaction,
# recover outside the lock, rescan, and repair the newly published state.
create_legacy_terminal_batch batch-pending-recovery 198
PENDING_BATCH_DIR="${SCHEDULER_ROOT}/batches/batch-pending-recovery"
cp "${PENDING_BATCH_DIR}/state.json" "${TEST_ROOT}/pending-recovered-state.json"
jq '
  .terminal_counts_version = 1
  | .done_count = 1
  | .memberships["0"].terminal_status = "done"
' "${PENDING_BATCH_DIR}/state.json" >"${PENDING_BATCH_DIR}/state.current.json"
mv "${PENDING_BATCH_DIR}/state.current.json" "${PENDING_BATCH_DIR}/state.json"
write_terminal_evidence "${SCHEDULER_ROOT}/callback_archive" \
  batch-pending-recovery 198 failed
jq '.pending_transaction = {version:1}' \
  "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.pending.json"
mv "${SCHEDULER_ROOT}/scheduler_state.pending.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
PENDING_MIGRATION="${TEST_ROOT}/recover-pending.sh"
cat >"${PENDING_MIGRATION}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec {LOCK_FD}>"${SCHEDULER_ROOT}/scheduler.lock"
flock -x "${LOCK_FD}"
cp "${PENDING_BATCH_STATE}" \
  "${SCHEDULER_ROOT}/batches/batch-pending-recovery/state.recovered.json"
mv "${SCHEDULER_ROOT}/batches/batch-pending-recovery/state.recovered.json" \
  "${SCHEDULER_ROOT}/batches/batch-pending-recovery/state.json"
jq 'del(.pending_transaction)' "${SCHEDULER_ROOT}/scheduler_state.json" \
  >"${SCHEDULER_ROOT}/scheduler_state.recovered.json"
mv "${SCHEDULER_ROOT}/scheduler_state.recovered.json" \
  "${SCHEDULER_ROOT}/scheduler_state.json"
printf '%s\n' recovered >>"${MIGRATION_LOG}"
flock -u "${LOCK_FD}"
exec {LOCK_FD}>&-
EOF
chmod +x "${PENDING_MIGRATION}"
: >"${TEST_ROOT}/pending-migration.log"
PENDING_RECONCILE="$(
  SCHEDULER_ROOT="${SCHEDULER_ROOT}" \
  PENDING_BATCH_STATE="${TEST_ROOT}/pending-recovered-state.json" \
  MIGRATION_LOG="${TEST_ROOT}/pending-migration.log" \
  DRIVEN_MIGRATION_SCRIPT="${PENDING_MIGRATION}" \
  CONFIG_DIR="${CONFIG_DIR}" \
  NOW_EPOCH=103 \
  bash "${RECONCILE}"
)"
jq -e '
  .status == "reconciled"
  and .scanned == 1
  and .repaired == 1
  and .unresolved == 0
' <<<"${PENDING_RECONCILE}" >/dev/null \
  || fail "pending transaction recovery was not followed by a fresh migration scan"
[ "$(cat "${TEST_ROOT}/pending-migration.log")" = recovered ] \
  || fail "terminal-count migration did not invoke pending transaction recovery exactly once"
jq -e '
  .terminal_counts_version == 1
  and .terminal_count == 1
  and .done_count == 0
  and .failed_count == 1
  and .memberships["0"].terminal_status == "failed"
' "${PENDING_BATCH_DIR}/state.json" >/dev/null \
  || fail "recovered legacy transaction overwrote the reconciled outcome"
jq -e 'has("pending_transaction") | not' \
  "${SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "pending transaction remained after bounded reconciliation recovery"

# retry_wait is a canonical non-terminal scheduler membership. Migration adds
# the embedded counter version without misclassifying or rejecting it.
RETRY_BATCH_DIR="${SCHEDULER_ROOT}/batches/batch-retry-wait"
mkdir -p "${RETRY_BATCH_DIR}"
jq -cnS '{
  version:1,
  batch_id:"batch-retry-wait",
  status:"queued",
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
      iid:200,
      status:"retry_wait"
    }
  }
}' >"${RETRY_BATCH_DIR}/state.json"
RETRY_RECONCILE="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-retry-wait"]' \
  bash "${RECONCILE}"
)"
jq -e '.status == "reconciled" and .scanned == 1 and .repaired == 1 and .unresolved == 0' \
  <<<"${RETRY_RECONCILE}" >/dev/null \
  || fail "canonical retry_wait membership was rejected by counter migration"
jq -e '
  .terminal_counts_version == 1
  and .terminal_count == 0
  and .done_count == 0
  and .failed_count == 0
  and .timeout_count == 0
  and .skipped_count == 0
  and .memberships["0"].status == "retry_wait"
  and (.memberships["0"] | has("terminal_status") | not)
' "${RETRY_BATCH_DIR}/state.json" >/dev/null \
  || fail "retry_wait migration changed non-terminal outcome semantics"

# Hold the canonical event lock while moving the only evidence from hot outbox
# to archive. The reconciler must wait, then locate and read the stable archive
# path rather than reporting a transient missing event.
create_legacy_terminal_batch batch-moving 201
write_terminal_evidence "${SCHEDULER_ROOT}/callback_outbox" batch-moving 201 done
MOVING_EVENT_ID='batch-moving:snapshot-0:terminal-1'
MOVING_LOCK_DIGEST="$(printf '%s' "${MOVING_EVENT_ID}" | shasum -a 256 | awk '{print $1}')"
exec {MOVING_LOCK_FD}>"${SCHEDULER_ROOT}/callback_locks/${MOVING_LOCK_DIGEST}.lock"
flock -x "${MOVING_LOCK_FD}"
(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-moving"]' \
  bash "${RECONCILE}"
) >"${TEST_ROOT}/moving-reconcile.out" 2>"${TEST_ROOT}/moving-reconcile.err" &
MOVING_PID=$!
sleep 0.1
mv "${SCHEDULER_ROOT}/callback_outbox/${MOVING_EVENT_ID}.json" \
  "${SCHEDULER_ROOT}/callback_archive/${MOVING_EVENT_ID}.json"
flock -u "${MOVING_LOCK_FD}"
exec {MOVING_LOCK_FD}>&-
wait "${MOVING_PID}" \
  || fail "hot-to-archive event move made reconciliation fail: $(cat "${TEST_ROOT}/moving-reconcile.err")"
jq -e '
  .status == "reconciled"
  and .scanned == 1
  and .repaired == 1
  and .unresolved == 0
' "${TEST_ROOT}/moving-reconcile.out" >/dev/null \
  || fail "outbox-only evidence was not reconciled after its atomic archive move"
jq -e '
  .terminal_count == 1
  and .done_count == 1
  and .memberships["0"].terminal_status == "done"
' "${SCHEDULER_ROOT}/batches/batch-moving/state.json" >/dev/null \
  || fail "moved callback evidence did not classify the legacy membership"
MOVING_REPLAY="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-moving"]' \
  bash "${RECONCILE}"
)"
jq -e '.status == "reconciled" and .scanned == 1 and .repaired == 0 and .unresolved == 0' \
  <<<"${MOVING_REPLAY}" >/dev/null \
  || fail "scoped reconciliation was not idempotent"

# A scheduler writer can atomically publish only a batch state while leaving
# scheduler_state.json unchanged. Reconciliation must compare against the same
# byte snapshot it parsed and must never overwrite that newer batch-only write.
create_legacy_terminal_batch batch-concurrent-writer 204
write_terminal_evidence "${SCHEDULER_ROOT}/callback_archive" \
  batch-concurrent-writer 204 done
CONCURRENT_EVENT_ID='batch-concurrent-writer:snapshot-0:terminal-1'
CONCURRENT_LOCK_DIGEST="$(printf '%s' "${CONCURRENT_EVENT_ID}" | shasum -a 256 | awk '{print $1}')"
exec {CONCURRENT_LOCK_FD}>"${SCHEDULER_ROOT}/callback_locks/${CONCURRENT_LOCK_DIGEST}.lock"
flock -x "${CONCURRENT_LOCK_FD}"
(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-concurrent-writer"]' \
  bash "${RECONCILE}"
) >"${TEST_ROOT}/concurrent-reconcile.out" \
  2>"${TEST_ROOT}/concurrent-reconcile.err" &
CONCURRENT_PID=$!
sleep 0.1
CONCURRENT_BATCH_STATE="${SCHEDULER_ROOT}/batches/batch-concurrent-writer/state.json"
jq '
  .terminal_counts_version = 1
  | .status = "queued"
  | .terminal_count = 0
  | .done_count = 0
  | .failed_count = 0
  | .timeout_count = 0
  | .skipped_count = 0
  | .memberships["0"].status = "retry_wait"
  | del(.memberships["0"].terminal_status)
' "${CONCURRENT_BATCH_STATE}" >"${CONCURRENT_BATCH_STATE}.new"
mv "${CONCURRENT_BATCH_STATE}.new" "${CONCURRENT_BATCH_STATE}"
flock -u "${CONCURRENT_LOCK_FD}"
exec {CONCURRENT_LOCK_FD}>&-
wait "${CONCURRENT_PID}" \
  || fail "batch-only concurrent writer made reconciliation fail: $(cat "${TEST_ROOT}/concurrent-reconcile.err")"
jq -e '
  .status == "reconciled"
  and .scanned == 1
  and .repaired == 0
  and .unresolved == 0
' "${TEST_ROOT}/concurrent-reconcile.out" >/dev/null \
  || fail "batch-only state change was not retried against a fresh snapshot"
jq -e '
  .terminal_counts_version == 1
  and .status == "queued"
  and .terminal_count == 0
  and .memberships["0"].status == "retry_wait"
  and (.memberships["0"] | has("terminal_status") | not)
' "${CONCURRENT_BATCH_STATE}" >/dev/null \
  || fail "reconciliation overwrote a newer batch-only state"

# Missing evidence is reported as partial and must leave the batch byte-for-byte
# unchanged so a later durable callback can be retried safely.
create_legacy_terminal_batch batch-missing 202
cp "${SCHEDULER_ROOT}/batches/batch-missing/state.json" \
  "${TEST_ROOT}/batch-missing.before.json"
MISSING_RECONCILE="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-missing"]' \
  bash "${RECONCILE}"
)"
jq -e '.status == "partial" and .scanned == 1 and .repaired == 0 and .unresolved == 1' \
  <<<"${MISSING_RECONCILE}" >/dev/null \
  || fail "missing terminal evidence did not return a strict partial result"
cmp -s "${TEST_ROOT}/batch-missing.before.json" \
  "${SCHEDULER_ROOT}/batches/batch-missing/state.json" \
  || fail "partial reconciliation mutated a batch without terminal evidence"

# Conflicting hot/archive evidence is corruption, never a last-writer-wins
# choice. The helper must fail closed and preserve the legacy batch state.
create_legacy_terminal_batch batch-conflict 203
write_terminal_evidence "${SCHEDULER_ROOT}/callback_archive" batch-conflict 203 done
write_terminal_evidence "${SCHEDULER_ROOT}/callback_outbox" batch-conflict 203 failed
cp "${SCHEDULER_ROOT}/batches/batch-conflict/state.json" \
  "${TEST_ROOT}/batch-conflict.before.json"
if CONFIG_DIR="${CONFIG_DIR}" \
  BATCH_IDS_JSON='["batch-conflict"]' \
  bash "${RECONCILE}" >"${TEST_ROOT}/batch-conflict.out" \
    2>"${TEST_ROOT}/batch-conflict.err"; then
  fail "conflicting hot/archive terminal evidence was accepted"
fi
grep -Fq 'terminal outcome evidence conflicts' "${TEST_ROOT}/batch-conflict.err" \
  || fail "conflicting evidence did not report the corruption reason"
cmp -s "${TEST_ROOT}/batch-conflict.before.json" \
  "${SCHEDULER_ROOT}/batches/batch-conflict/state.json" \
  || fail "conflicting evidence mutated the legacy batch"

# After the one-day rolling-upgrade compatibility window, a 5-minute heartbeat
# scans only the hot scheduler index plus unresolved marker entries. A daily
# full audit still detects corruption in retained cold history.
SCALE_ROOT="${TEST_ROOT}/incremental-scale"
SCALE_CONFIG="${SCALE_ROOT}/config"
SCALE_SCHEDULER="${SCALE_ROOT}/scheduler"
mkdir -p "${SCALE_CONFIG}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${SCALE_SCHEDULER}" \
  'EXECUTOR_MAX_CONCURRENCY=1' \
  'DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0' \
  'DRIVEN_TERMINAL_COUNT_COMPAT_SECONDS=0' \
  >"${SCALE_CONFIG}/campaign_defaults.env"
CONFIG_DIR="${SCALE_CONFIG}" \
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0 \
bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
for cold_index in $(seq 1 300); do
  cold_batch_id="cold-${cold_index}"
  cold_batch_dir="${SCALE_SCHEDULER}/batches/${cold_batch_id}"
  mkdir -p "${cold_batch_dir}"
  printf '%s\n' \
    "{\"version\":1,\"terminal_counts_version\":1,\"batch_id\":\"${cold_batch_id}\",\"status\":\"completed\",\"matched_count\":0,\"terminal_count\":0,\"done_count\":0,\"failed_count\":0,\"timeout_count\":0,\"skipped_count\":0,\"next_snapshot_index\":0,\"memberships\":{}}" \
    >"${cold_batch_dir}/state.json"
done
SCALE_INITIAL="$(
  CONFIG_DIR="${SCALE_CONFIG}" \
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0 \
  DRIVEN_TERMINAL_COUNT_COMPAT_SECONDS=0 \
  NOW_EPOCH=1000 \
  bash "${RECONCILE}"
)"
jq -e '.status == "reconciled" and .scanned == 0 and .unresolved == 0' \
  <<<"${SCALE_INITIAL}" >/dev/null \
  || fail "initial scaled full audit did not skip current-format cold states"
jq -e '.last_full_scan_at == 1000 and .status == "complete"' \
  "${SCALE_SCHEDULER}/terminal-count-reconcile-v1.json" >/dev/null \
  || fail "scaled full audit did not persist its audit watermark"
printf '%s\n' '{broken-json' \
  >"${SCALE_SCHEDULER}/batches/cold-300/state.json"
HOT_SCALE_BATCH='hot-legacy'
HOT_SCALE_DIR="${SCALE_SCHEDULER}/batches/${HOT_SCALE_BATCH}"
mkdir -p "${HOT_SCALE_DIR}"
jq -cnS --arg batch_id "${HOT_SCALE_BATCH}" '{
  version:1,
  batch_id:$batch_id,
  status:"queued",
  matched_count:1,
  terminal_count:0,
  done_count:0,
  failed_count:0,
  timeout_count:0,
  skipped_count:0,
  next_snapshot_index:0,
  memberships:{}
}' >"${HOT_SCALE_DIR}/state.json"
jq --arg batch_id "${HOT_SCALE_BATCH}" '.batch_order = [$batch_id]' \
  "${SCALE_SCHEDULER}/scheduler_state.json" \
  >"${SCALE_SCHEDULER}/scheduler_state.hot.json"
mv "${SCALE_SCHEDULER}/scheduler_state.hot.json" \
  "${SCALE_SCHEDULER}/scheduler_state.json"
SCALE_INCREMENTAL="$(
  CONFIG_DIR="${SCALE_CONFIG}" \
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0 \
  DRIVEN_TERMINAL_COUNT_COMPAT_SECONDS=0 \
  NOW_EPOCH=1001 \
  bash "${RECONCILE}"
)" || fail "incremental scaled heartbeat opened corrupt cold history"
jq -e '.status == "reconciled" and .scanned == 1 and .repaired == 1 and .unresolved == 0' \
  <<<"${SCALE_INCREMENTAL}" >/dev/null \
  || fail "incremental scaled heartbeat did not limit reconciliation to the hot index"
jq -e '.terminal_counts_version == 1' "${HOT_SCALE_DIR}/state.json" >/dev/null \
  || fail "incremental scaled heartbeat did not repair its hot legacy state"
if CONFIG_DIR="${SCALE_CONFIG}" \
  DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0 \
  DRIVEN_TERMINAL_COUNT_COMPAT_SECONDS=0 \
  NOW_EPOCH=87400 \
  bash "${RECONCILE}" >"${SCALE_ROOT}/daily-audit.out" \
    2>"${SCALE_ROOT}/daily-audit.err"; then
  fail "daily full audit ignored corrupt retained cold history"
fi
grep -Fq 'failed to classify terminal count batch states' \
  "${SCALE_ROOT}/daily-audit.err" \
  || fail "daily full audit did not report cold-state corruption"

# Seal the generation window after reconciliation: a rolling old transaction
# can be recovered by the next normal reservation call. That same call must
# reject the republished legacy state instead of granting work from it.
FENCE_ROOT="${TEST_ROOT}/generation-fence"
FENCE_CONFIG="${FENCE_ROOT}/config"
FENCE_SCHEDULER="${FENCE_ROOT}/scheduler"
FENCE_BATCH_ID='batch-generation-fence'
FENCE_BATCH_DIR="${FENCE_SCHEDULER}/batches/${FENCE_BATCH_ID}"
mkdir -p "${FENCE_CONFIG}" "${FENCE_BATCH_DIR}"
printf '%s\n' \
  'REPO_PARENT_PATH=/data' \
  "EXECUTOR_SCHEDULER_ROOT=${FENCE_SCHEDULER}" \
  'EXECUTOR_MAX_CONCURRENCY=1' \
  >"${FENCE_CONFIG}/campaign_defaults.env"
CONFIG_DIR="${FENCE_CONFIG}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
jq -cnS --arg batch_id "${FENCE_BATCH_ID}" '{
  version:1,
  batch_id:$batch_id,
  project:"group/repo",
  force_rerun_pr:false,
  branch:null
}' >"${FENCE_BATCH_DIR}/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[301]}' \
  >"${FENCE_BATCH_DIR}/snapshot.json"
jq -cnS --arg batch_id "${FENCE_BATCH_ID}" '{
  version:1,
  batch_id:$batch_id,
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
}' >"${FENCE_BATCH_DIR}/legacy-state.json"
cp "${FENCE_BATCH_DIR}/legacy-state.json" "${FENCE_BATCH_DIR}/state.json"
jq -cnS \
  --arg batch_id "${FENCE_BATCH_ID}" \
  --slurpfile legacy_state "${FENCE_BATCH_DIR}/legacy-state.json" '{
    version:1,
    round_robin_cursor:null,
    active_jobs:{},
    batch_order:[$batch_id],
    pending_transaction:{
      version:1,
      scheduler_state:{
        version:1,
        round_robin_cursor:null,
        active_jobs:{},
        batch_order:[$batch_id]
      },
      batch_states:{($batch_id):$legacy_state[0]}
    }
  }' >"${FENCE_SCHEDULER}/scheduler_state.json"
if CONFIG_DIR="${FENCE_CONFIG}" NOW_EPOCH=104 \
  bash "${RESERVE}" >"${FENCE_ROOT}/legacy-reserve.out" \
    2>"${FENCE_ROOT}/legacy-reserve.err"; then
  fail "normal reservation granted work from a recovered legacy counter state"
fi
grep -Fq 'batch state is invalid: batch-generation-fence' \
  "${FENCE_ROOT}/legacy-reserve.err" \
  || fail "normal reservation did not report the legacy counter fence"
jq -e 'has("pending_transaction") | not' \
  "${FENCE_SCHEDULER}/scheduler_state.json" >/dev/null \
  || fail "reservation did not durably recover the pending transaction"
jq -e 'has("terminal_counts_version") | not' \
  "${FENCE_BATCH_DIR}/state.json" >/dev/null \
  || fail "legacy pending state was unexpectedly rewritten before reconciliation"
FENCE_RECONCILE="$(
  CONFIG_DIR="${FENCE_CONFIG}" \
  BATCH_IDS_JSON='["batch-generation-fence"]' \
  NOW_EPOCH=105 \
  bash "${RECONCILE}"
)"
jq -e '.status == "reconciled" and .scanned == 1 and .repaired == 1 and .unresolved == 0' \
  <<<"${FENCE_RECONCILE}" >/dev/null \
  || fail "recovered legacy state was not reconciled on the next heartbeat"
FENCE_RESERVE="$(CONFIG_DIR="${FENCE_CONFIG}" NOW_EPOCH=106 bash "${RESERVE}")" \
  || fail "reservation remained blocked after counter reconciliation"
jq -e '
  .status == "ready"
  and (.grants | length) == 1
  and .grants[0].batch_id == "batch-generation-fence"
' <<<"${FENCE_RESERVE}" >/dev/null \
  || fail "reconciled generation fence batch did not produce its grant"

echo "ok driven terminal outcome counters"
