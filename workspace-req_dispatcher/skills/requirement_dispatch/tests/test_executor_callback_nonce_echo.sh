#!/usr/bin/env bash
set -euo pipefail
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-nonce-echo.XXXXXX")"
CALLBACK_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
CALLBACK_NONCE_SHA256="$({
  printf '%s' "${CALLBACK_NONCE}"
} | if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi)"

initialize_batch_outbox() {
  local state_root="$1"
  STATE_ROOT="${state_root}" "${BASH}" -c '
    source "$1"
    ensure_state_dirs
  ' _ "${SKILL_DIR}/scripts/env_paths.sh"
  jq -cn --arg callback_nonce "${CALLBACK_NONCE}" '{
    version:1,
    requests:[{
      batch_id:"nonce-echo-batch",
      correlation_id:"reqd-nonce-echo",
      project:"group/project",
      selector:{type:"single",iid:42},
      force_rerun_pr:false,
      target_branch:null,
      executor_agent:"req_executor",
      callback_nonce:$callback_nonce,
      origin:null,
      payload:("RUN_DRIVEN_ISSUE_BATCH\nbatch_id=nonce-echo-batch"
        + "\nexecutor_agent=req_executor\ncallback_nonce=" + $callback_nonce),
      request_digest:("a" * 64),
      status:"queued",
      attempts:0,
      last_attempt_at:null,
      last_error:null,
      matched_count:null,
      snapshot_digest:null,
      scheduler_status:null,
      created_at:"2026-07-12T00:00:00Z",
      updated_at:"2026-07-12T00:00:00Z",
      received_at:null,
      accepted_at:null
    }]
  }' >"${state_root}/_dispatcher/executor_batch_outbox.json"
}

assert_nonce_absent_from_public_state() {
  local state_root="$1"
  shift
  if grep -R -F -q -- "${CALLBACK_NONCE}" \
      "${state_root}/_dispatcher/executor_batches.json" \
      "${state_root}/_dispatcher/executor_batch_events.jsonl" \
      "${state_root}/_dispatcher/executor_batch_notifications.json" \
      "${state_root}/_dispatcher/accepted_intents" \
      "${state_root}/_dispatcher/delivered_notifications" \
      "$@" 2>/dev/null; then
    echo "callback nonce escaped into public or compact state" >&2
    exit 1
  fi
}

DIRECT_RECEIPT_ROOT="${TEST_ROOT}/direct-receipt"
initialize_batch_outbox "${DIRECT_RECEIPT_ROOT}"
direct_before="$(jq -cS . "${DIRECT_RECEIPT_ROOT}/_dispatcher/executor_batch_outbox.json")"
set +e
STATE_ROOT="${DIRECT_RECEIPT_ROOT}" \
BATCH_ID=nonce-echo-batch \
EXECUTOR_AGENT=req_executor \
MATCHED_COUNT=1 \
SNAPSHOT_DIGEST="${CALLBACK_NONCE}" \
SCHEDULER_STATUS=completed \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch_receipt.sh" \
  >"${TEST_ROOT}/direct-receipt.out" 2>"${TEST_ROOT}/direct-receipt.err"
direct_rc=$?
set -e
if [ "${direct_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${DIRECT_RECEIPT_ROOT}/_dispatcher/executor_batch_outbox.json")" != "${direct_before}" ]; then
  echo "direct nonce_v1 receipt persisted a snapshot digest equal to the callback nonce" >&2
  exit 1
fi
assert_nonce_absent_from_public_state "${DIRECT_RECEIPT_ROOT}" \
  "${TEST_ROOT}/direct-receipt.out" "${TEST_ROOT}/direct-receipt.err"

FAKE_BATCH_OPENCLAW="${TEST_ROOT}/batch-openclaw"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'shift'
  printf '%s\n' 'while [ "$#" -gt 0 ]; do'
  printf '%s\n' '  case "$1" in'
  printf '%s\n' '    --agent|--session-key|--timeout) shift 2 ;;'
  printf '%s\n' '    --message-file) [ "$2" = /dev/stdin ] || exit 91; message="$(cat)"; shift 2 ;;'
  printf '%s\n' '    *) exit 92 ;;'
  printf '%s\n' '  esac'
  printf '%s\n' 'done'
  printf '%s\n' 'nonce="$(awk -F= '\''$1 == "callback_nonce" {print $2; exit}'\'' <<<"${message}")"'
  printf '%s\n' 'jq -nc '\''{status:"success",batch_id:"nonce-echo-batch",matched_count:1,snapshot_digest:("b" * 64),scheduler_status:"completed"}'\'''
  printf '%s\n' 'printf "summary=%s\n" "${nonce}"'
} >"${FAKE_BATCH_OPENCLAW}"
chmod +x "${FAKE_BATCH_OPENCLAW}"

BATCH_SUMMARY_ROOT="${TEST_ROOT}/batch-summary"
initialize_batch_outbox "${BATCH_SUMMARY_ROOT}"
batch_summary_result="$(
  STATE_ROOT="${BATCH_SUMMARY_ROOT}" \
  OPENCLAW_BIN="${FAKE_BATCH_OPENCLAW}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS=60 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh" \
    2>"${TEST_ROOT}/batch-summary.err"
)"
if ! jq -e '
    .status == "retryable_failure"
    and .reason == "callback_nonce_echo"
  ' <<<"${batch_summary_result}" >/dev/null \
  || ! jq -e '
    .requests[0].status == "queued"
    and .requests[0].matched_count == null
    and .requests[0].snapshot_digest == null
  ' "${BATCH_SUMMARY_ROOT}/_dispatcher/executor_batch_outbox.json" >/dev/null; then
  echo "batch acceptance did not reject a nonce echoed through downstream summary output" >&2
  exit 1
fi
assert_nonce_absent_from_public_state "${BATCH_SUMMARY_ROOT}" \
  "${TEST_ROOT}/batch-summary.err"
if grep -F -q -- "${CALLBACK_NONCE}" <<<"${batch_summary_result}"; then
  echo "batch nonce echo appeared in the public retry result" >&2
  exit 1
fi

EVENT_ROOT="${TEST_ROOT}/event"
STATE_ROOT="${EVENT_ROOT}" \
BATCH_ID=nonce-event-batch \
PROJECT=group/project \
EXECUTOR_AGENT=req_executor \
CALLBACK_AUTH_MODE=nonce_v1 \
CALLBACK_NONCE_SHA256="${CALLBACK_NONCE_SHA256}" \
ORIGIN_JSON=null \
MATCHED_COUNT=1 \
REQUEST_DIGEST=nonce-event-request \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null
event_mirror_before="$(jq -cS . "${EVENT_ROOT}/_dispatcher/executor_batches.json")"
event_ledger_before="$(jq -scS . "${EVENT_ROOT}/_dispatcher/executor_batch_events.jsonl")"
event_notifications_before="$(jq -cS . "${EVENT_ROOT}/_dispatcher/executor_batch_notifications.json")"

assert_event_echo_rejected() {
  local label="$1"
  local event_json="$2"
  local envelope rc
  envelope="$(jq -cn \
    --arg nonce "${CALLBACK_NONCE}" \
    --argjson event "${event_json}" '{
      callback_nonce:$nonce,
      executor_agent:"req_executor",
      worker_result_json:$event
    }')"
  set +e
  STATE_ROOT="${EVENT_ROOT}" CALLBACK_ENVELOPE_JSON="${envelope}" \
    "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" \
    >"${TEST_ROOT}/${label}.out" 2>"${TEST_ROOT}/${label}.err"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ] \
    || [ "$(jq -cS . "${EVENT_ROOT}/_dispatcher/executor_batches.json")" != "${event_mirror_before}" ] \
    || [ "$(jq -scS . "${EVENT_ROOT}/_dispatcher/executor_batch_events.jsonl")" != "${event_ledger_before}" ] \
    || [ "$(jq -cS . "${EVENT_ROOT}/_dispatcher/executor_batch_notifications.json")" != "${event_notifications_before}" ]; then
    echo "I3 nonce echo did not fail closed: ${label}" >&2
    exit 1
  fi
  assert_nonce_absent_from_public_state "${EVENT_ROOT}" \
    "${TEST_ROOT}/${label}.out" "${TEST_ROOT}/${label}.err"
}

BASE_EVENT='{
  "event_id":"nonce-event-batch:snapshot-0:terminal-1",
  "batch_id":"nonce-event-batch",
  "snapshot_index":0,
  "project":"group/project",
  "iid":42,
  "status":"failed",
  "mr_url":null,
  "reason":null
}'
assert_event_echo_rejected reason-echo \
  "$(jq -c --arg nonce "${CALLBACK_NONCE}" '.reason=("echo " + $nonce)' <<<"${BASE_EVENT}")"
assert_event_echo_rejected mr-url-echo \
  "$(jq -c --arg nonce "${CALLBACK_NONCE}" '.mr_url=("https://gitlab.invalid/" + $nonce)' <<<"${BASE_EVENT}")"

LEGACY_SCHEMA_ROOT="${TEST_ROOT}/legacy-schema"
STATE_ROOT="${LEGACY_SCHEMA_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
jq -cn --arg nonce "${CALLBACK_NONCE}" '{
  next_id:2,
  active:{
    queue_id:"execq-1",
    correlation_id:"reqd-1",
    run_id:"executor-execq-1",
    project:"group/project",
    iid:42,
    executor_agent:"req_executor",
    callback_nonce:$nonce
  },
  queue:[]
}' >"${LEGACY_SCHEMA_ROOT}/_dispatcher/executor_queue.json"
legacy_schema_before="$(jq -cS . "${LEGACY_SCHEMA_ROOT}/_dispatcher/executor_queue.json")"
set +e
STATE_ROOT="${LEGACY_SCHEMA_ROOT}" \
QUEUE_ID=execq-1 \
CORRELATION_ID=reqd-1 \
BATCH_ID=legacy-invalid-snapshot \
EXECUTOR_AGENT=req_executor \
MATCHED_COUNT=1 \
SNAPSHOT_DIGEST=not-a-lowercase-sha256 \
SCHEDULER_STATUS=completed \
REQUEST_DIGEST=legacy-request \
  "${BASH}" "${SKILL_DIR}/scripts/record_legacy_executor_batch_receipt.sh" \
  >"${TEST_ROOT}/legacy-schema.out" 2>"${TEST_ROOT}/legacy-schema.err"
legacy_schema_rc=$?
set -e
if [ "${legacy_schema_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${LEGACY_SCHEMA_ROOT}/_dispatcher/executor_queue.json")" != "${legacy_schema_before}" ]; then
  echo "nonce_v1 legacy receipt accepted a non-SHA-256 snapshot digest" >&2
  exit 1
fi

LEGACY_RECEIPT_ROOT="${TEST_ROOT}/legacy-receipt"
STATE_ROOT="${LEGACY_RECEIPT_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
jq -cn --arg nonce "${CALLBACK_NONCE}" '{
  next_id:2,
  active:{
    queue_id:"execq-1",
    correlation_id:"reqd-1",
    run_id:"executor-execq-1",
    project:"group/project",
    iid:42,
    executor_agent:"req_executor",
    callback_nonce:$nonce
  },
  queue:[]
}' >"${LEGACY_RECEIPT_ROOT}/_dispatcher/executor_queue.json"
legacy_before="$(jq -cS . "${LEGACY_RECEIPT_ROOT}/_dispatcher/executor_queue.json")"
set +e
STATE_ROOT="${LEGACY_RECEIPT_ROOT}" \
QUEUE_ID=execq-1 \
CORRELATION_ID=reqd-1 \
BATCH_ID=legacy-nonce-echo \
EXECUTOR_AGENT=req_executor \
MATCHED_COUNT=1 \
SNAPSHOT_DIGEST="${CALLBACK_NONCE}" \
SCHEDULER_STATUS=completed \
REQUEST_DIGEST=legacy-request \
  "${BASH}" "${SKILL_DIR}/scripts/record_legacy_executor_batch_receipt.sh" \
  >"${TEST_ROOT}/legacy-receipt.out" 2>"${TEST_ROOT}/legacy-receipt.err"
legacy_receipt_rc=$?
set -e
if [ "${legacy_receipt_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${LEGACY_RECEIPT_ROOT}/_dispatcher/executor_queue.json")" != "${legacy_before}" ]; then
  echo "legacy single receipt persisted a snapshot digest equal to its callback nonce" >&2
  exit 1
fi

echo "ok nonce_v1 rejects callback nonce echoes before public projection"
