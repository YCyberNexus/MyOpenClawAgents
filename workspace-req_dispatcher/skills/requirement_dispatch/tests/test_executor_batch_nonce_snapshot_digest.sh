#!/usr/bin/env bash
set -euo pipefail
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-nonce-digest.XXXXXX")"
STATE_ROOT_PATH="${TEST_ROOT}/state"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
CALLBACK_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

cat >"${FAKE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = agent ] || exit 90
shift
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent|--session-key|--timeout) shift 2 ;;
    --message-file) message_file="${2:-}"; shift 2 ;;
    *) exit 91 ;;
  esac
done
[ "${message_file}" = /dev/stdin ] || exit 92
message="$(cat)"
batch_id="$(awk -F= '$1 == "batch_id" {print $2; exit}' <<<"${message}")"
jq -nc --arg batch_id "${batch_id}" '{
  status:"success",
  batch_id:$batch_id,
  matched_count:1,
  snapshot_digest:"not-a-sha256-digest",
  scheduler_status:"completed"
}'
FAKE
chmod +x "${FAKE_OPENCLAW}"

STATE_ROOT="${STATE_ROOT_PATH}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"

payload="$(printf '%s\n' \
  'RUN_DRIVEN_ISSUE_BATCH' \
  'batch_id=digest-contract' \
  'project=group/project' \
  'selector_type=single' \
  'iid=1' \
  'force_rerun_pr=false' \
  'executor_agent=req_executor' \
  "callback_nonce=${CALLBACK_NONCE}")"
jq -cn \
  --arg payload "${payload}" \
  --arg callback_nonce "${CALLBACK_NONCE}" '{
  version:1,
  requests:[{
    batch_id:"digest-contract",
    correlation_id:"reqd-digest-contract",
    project:"group/project",
    selector:{type:"single",iid:1},
    force_rerun_pr:false,
    target_branch:null,
    executor_agent:"req_executor",
    callback_nonce:$callback_nonce,
    origin:null,
    payload:$payload,
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
}' >"${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json"

result="$(
  STATE_ROOT="${STATE_ROOT_PATH}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS=60 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"

if ! jq -e '
  .status == "retryable_failure"
  and .batch_id == "digest-contract"
  and .reason == "invalid_executor_acceptance"
' <<<"${result}" >/dev/null; then
  echo "nonce_v1 accepted a snapshot digest that was not 64 lowercase hexadecimal characters" >&2
  printf '%s\n' "${result}" >&2
  exit 1
fi

if ! jq -e '
  .requests == [(.requests[0])]
  and .requests[0].batch_id == "digest-contract"
  and .requests[0].status == "queued"
  and .requests[0].last_error == "invalid_executor_acceptance"
' "${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json" >/dev/null; then
  echo "rejected nonce_v1 acceptance did not remain retryable in hot state" >&2
  exit 1
fi

receipt_before="$(jq -cS . "${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json")"
set +e
STATE_ROOT="${STATE_ROOT_PATH}" \
BATCH_ID="digest-contract" \
EXECUTOR_AGENT="req_executor" \
MATCHED_COUNT=1 \
SNAPSHOT_DIGEST="not-a-sha256-digest" \
SCHEDULER_STATUS="completed" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch_receipt.sh" \
  >"${TEST_ROOT}/direct-receipt.out" 2>"${TEST_ROOT}/direct-receipt.err"
direct_receipt_rc=$?
set -e
if [ "${direct_receipt_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json")" != "${receipt_before}" ]; then
  echo "direct nonce_v1 receipt wrote an invalid snapshot digest into hot state" >&2
  exit 1
fi

if ! STATE_ROOT="${STATE_ROOT_PATH}" "${BASH}" -c '
  source "$1"
  source "$2"
  ensure_state_dirs
  exec 9>"${LOCK_FILE}"
  flock 9
  load_executor_batch_outbox_locked >/dev/null
' _ "${SKILL_DIR}/scripts/env_paths.sh" \
  "${SKILL_DIR}/scripts/_executor_batch_outbox_lib.sh"; then
  echo "rejected direct nonce_v1 receipt left hot state unloadable" >&2
  exit 1
fi

echo "ok nonce_v1 executor acceptance requires a lowercase SHA-256 snapshot digest"
