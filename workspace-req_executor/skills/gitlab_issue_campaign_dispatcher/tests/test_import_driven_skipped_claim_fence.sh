#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMPORT_SKIP="${SKILL_DIR}/scripts/import_driven_skipped.sh"
SCHEDULER_ENV="${SKILL_DIR}/scripts/scheduler_env.sh"

fail() {
  echo "test_import_driven_skipped_claim_fence.sh: $*" >&2
  exit 1
}

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-skip-claim.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/scheduler"
FAKE_IMPORT="${TEST_ROOT}/fake-import.sh"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF
CONFIG_DIR="${CONFIG_DIR}" bash "${SCHEDULER_ENV}" >/dev/null

cat >"${FAKE_IMPORT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
handoff="$(jq -ce . "${HANDOFF_FILE:?}")"
jq -e \
  --arg job_id "${EXPECTED_JOB_ID:?}" \
  --argjson generation "${EXPECTED_CLAIM_GENERATION:?}" \
  --argjson token "${EXPECTED_CLAIM_TOKEN_JSON:?}" '
  .job_id == $job_id
  and .event_id == ($job_id + ":claim-" + ($generation|tostring) + ":terminal-1")
  and .claim_generation == $generation
  and .claim_token == $token
  and .status == "skipped"
' <<<"${handoff}" >/dev/null
jq -cn --arg job_id "${EXPECTED_JOB_ID}" '{
  status:"imported",job_id:$job_id,terminal_recorded:true
}'
EOF
chmod +x "${FAKE_IMPORT}"

write_scheduler_job() {
  local job_id="$1" status="$2" generation="$3" token_json="$4"
  jq -cnS \
    --arg job_id "${job_id}" \
    --arg status "${status}" \
    --argjson generation "${generation}" \
    --argjson token "${token_json}" '{
    version:1,
    round_robin_cursor:"batch-A",
    batch_order:["batch-A"],
    active_jobs:{($job_id):{
      job_id:$job_id,
      project:"group/repo",
      iid:42,
      status:$status,
      claim_generation:$generation,
      claim_token:$token,
      legacy_running:false
    }}
  }' >"${SCHEDULER_ROOT}/scheduler_state.next.json"
  mv "${SCHEDULER_ROOT}/scheduler_state.next.json" \
    "${SCHEDULER_ROOT}/scheduler_state.json"
}

ENTRY='{
  "job_id":"batch-A:snapshot-0",
  "batch_id":"batch-A",
  "snapshot_index":0,
  "project":"group/repo",
  "iid":42,
  "status":"skipped",
  "reason":"closed"
}'

# A blocked retry can drain project pending while the physical scheduler job
# remains running. Its terminal skip must carry the current positive claim
# fence; claim-0 is stale and the real importer rejects it.
write_scheduler_job "batch-A:snapshot-0" running 2 '"running-private-claim"'
running_output="$(printf '%s' "${ENTRY}" | \
  CONFIG_DIR="${CONFIG_DIR}" \
  IMPORT_HANDOFF_CMD="${FAKE_IMPORT}" \
  EXPECTED_JOB_ID="batch-A:snapshot-0" \
  EXPECTED_CLAIM_GENERATION=2 \
  EXPECTED_CLAIM_TOKEN_JSON='"running-private-claim"' \
  bash "${IMPORT_SKIP}")" || fail "running skip did not use the active claim fence"
jq -e '
  .status == "imported"
  and .job_id == "batch-A:snapshot-0"
  and .event_id == "batch-A:snapshot-0:claim-2:terminal-1"
' <<<"${running_output}" >/dev/null || fail "running skip acknowledgement is invalid"
if grep -Fq 'running-private-claim' <<<"${running_output}"; then
  fail "running skip acknowledgement exposed the private claim token"
fi

# A newly reserved job has no physical claim yet and retains the original
# claim-0 synthetic terminal behavior.
write_scheduler_job "batch-A:snapshot-1" reserved 0 null
reserved_entry="$(jq -c '
  .job_id = "batch-A:snapshot-1"
  | .snapshot_index = 1
' <<<"${ENTRY}")"
reserved_output="$(printf '%s' "${reserved_entry}" | \
  CONFIG_DIR="${CONFIG_DIR}" \
  IMPORT_HANDOFF_CMD="${FAKE_IMPORT}" \
  EXPECTED_JOB_ID="batch-A:snapshot-1" \
  EXPECTED_CLAIM_GENERATION=0 \
  EXPECTED_CLAIM_TOKEN_JSON=null \
  bash "${IMPORT_SKIP}")" || fail "reserved skip no longer used claim-0"
jq -e '
  .status == "imported"
  and .event_id == "batch-A:snapshot-1:claim-0:terminal-1"
' <<<"${reserved_output}" >/dev/null || fail "reserved skip acknowledgement is invalid"

# Exercise the generated positive claim against the real handoff importer and
# scheduler terminal recorder, not only the handoff-shape boundary above.
REAL_CONFIG_DIR="${TEST_ROOT}/real-config"
REAL_SCHEDULER_ROOT="${TEST_ROOT}/real-scheduler"
REAL_BATCH_ID="real-batch"
REAL_JOB_ID="${REAL_BATCH_ID}:snapshot-0"
REAL_NONCE='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
mkdir -p "${REAL_CONFIG_DIR}"
cat >"${REAL_CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${REAL_SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EXECUTOR_RUNNING_LEASE_SECONDS=21600
EXECUTOR_AGENT=req_executor
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:main
DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0
EOF
CONFIG_DIR="${REAL_CONFIG_DIR}" bash "${SCHEDULER_ENV}" >/dev/null
mkdir -p "${REAL_SCHEDULER_ROOT}/batches/${REAL_BATCH_ID}"
jq -cnS --arg batch_id "${REAL_BATCH_ID}" --arg nonce "${REAL_NONCE}" '{
  version:1,batch_id:$batch_id,correlation_id:"real-correlation",
  project:"group/repo",selector:{type:"single",iid:42},force_rerun_pr:false,
  dispatcher_callback_target:"agent:req_dispatcher:main",
  executor_agent:"req_executor",callback_nonce:$nonce,branch:"main"
}' >"${REAL_SCHEDULER_ROOT}/batches/${REAL_BATCH_ID}/request.json"
jq -cnS '{version:1,project:"group/repo",iids:[42]}' \
  >"${REAL_SCHEDULER_ROOT}/batches/${REAL_BATCH_ID}/snapshot.json"
jq -cnS --arg batch_id "${REAL_BATCH_ID}" --arg job_id "${REAL_JOB_ID}" '{
  version:1,batch_id:$batch_id,status:"running",matched_count:1,
  terminal_count:0,done_count:0,failed_count:0,timeout_count:0,skipped_count:0,
  next_snapshot_index:1,request_digest:"fixture",snapshot_digest:"fixture",
  memberships:{"0":{snapshot_index:0,iid:42,status:"running",job_id:$job_id}}
}' >"${REAL_SCHEDULER_ROOT}/batches/${REAL_BATCH_ID}/state.json"
jq -cnS --arg batch_id "${REAL_BATCH_ID}" --arg job_id "${REAL_JOB_ID}" '{
  version:1,round_robin_cursor:$batch_id,batch_order:[$batch_id],
  active_jobs:{($job_id):{
    job_id:$job_id,physical_key:"group/repo#42",project:"group/repo",iid:42,
    branch:"main",entry_mode:"auto",force_rerun_pr:false,status:"running",
    reservation_seq:1,claim_generation:2,claim_token:"real-running-private-claim",
    reserved_at:1,updated_at:2,owner:{batch_id:$batch_id,snapshot_index:0},
    memberships:[{batch_id:$batch_id,snapshot_index:0}]
  }}
}' >"${REAL_SCHEDULER_ROOT}/scheduler_state.json"
real_entry="$(jq -c \
  --arg job_id "${REAL_JOB_ID}" \
  --arg batch_id "${REAL_BATCH_ID}" '
  .job_id = $job_id | .batch_id = $batch_id
' <<<"${ENTRY}")"
real_output="$(printf '%s' "${real_entry}" | \
  CONFIG_DIR="${REAL_CONFIG_DIR}" NOW_EPOCH=10 \
  bash "${IMPORT_SKIP}")" || fail "real importer rejected the running claim-fenced skip"
jq -e \
  --arg job_id "${REAL_JOB_ID}" '
  .status == "imported"
  and .job_id == $job_id
  and .event_id == ($job_id + ":claim-2:terminal-1")
' <<<"${real_output}" >/dev/null || fail "real importer returned an invalid skip result"
if grep -Fq 'real-running-private-claim' <<<"${real_output}"; then
  fail "real importer acknowledgement exposed the private claim token"
fi
jq -e '.active_jobs == {}' \
  "${REAL_SCHEDULER_ROOT}/scheduler_state.json" >/dev/null \
  || fail "real importer did not release the running physical scheduler slot"
jq -e '
  .status == "completed"
  and .terminal_count == 1
  and .memberships["0"].status == "terminal"
' "${REAL_SCHEDULER_ROOT}/batches/${REAL_BATCH_ID}/state.json" >/dev/null \
  || fail "real importer did not terminalize the batch membership as skipped"
jq -e \
  --arg nonce "${REAL_NONCE}" '
  .body.status == "skipped"
  and .callback_auth_mode == "nonce_v1"
  and .executor_agent == "req_executor"
  and .callback_nonce == $nonce
  and (.ready_at | type == "number" and . == floor and . >= 0)
' "${REAL_SCHEDULER_ROOT}/callback_outbox/${REAL_BATCH_ID}:snapshot-0:terminal-1.json" \
  >/dev/null || fail "real importer did not publish the authenticated skipped outbox"

echo "ok driven skip imports the exact active scheduler claim"
