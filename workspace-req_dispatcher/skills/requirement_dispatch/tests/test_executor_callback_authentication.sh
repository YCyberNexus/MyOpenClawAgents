#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-callback-auth.XXXXXX")"

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

FIXED_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
FIXED_NONCE_SHA256="$(printf '%s' "${FIXED_NONCE}" | sha256_text)"
QUIET_NOTIFY="${TEST_ROOT}/quiet-notify.sh"
TRANSPORT_LEAK_LOG="${TEST_ROOT}/callback-transport-env-leak.log"
cat >"${QUIET_NOTIFY}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
for name in CALLBACK_ENVELOPE_JSON callback_envelope WORKER_RESULT_JSON worker_result_json; do
  if [ -n "$(printenv "${name}" 2>/dev/null || true)" ]; then
    printf '%s\n' "${name}" >>"${TRANSPORT_LEAK_LOG:?}"
  fi
done
exit 0
FAKE
chmod +x "${QUIET_NOTIFY}"

# New batch intake must generate a high-entropy nonce, keep its plaintext only
# in the private durable outbox, and project only its digest into the mirror.
SUBMIT_ROOT="${TEST_ROOT}/submit-state"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
BATCH_ARGV_LOG="${TEST_ROOT}/batch-openclaw.argv"
BATCH_STDIN_LOG="${TEST_ROOT}/batch-openclaw.stdin"
cat >"${FAKE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
shift
message=""
printf '%s\n' "$*" >"${BATCH_ARGV_LOG:?}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent|--session-key|--timeout) shift 2 ;;
    --message-file)
      [ "$2" = /dev/stdin ] || exit 92
      message="$(cat)"
      shift 2
      ;;
    --message) exit 93 ;;
    *) exit 91 ;;
  esac
done
printf '%s' "${message}" >"${BATCH_STDIN_LOG:?}"
batch_id="$(awk -F= '$1 == "batch_id" {print $2; exit}' <<<"${message}")"
jq -nc --arg batch_id "${batch_id}" '{
  status:"success",
  batch_id:$batch_id,
  matched_count:1,
  snapshot_digest:("c" * 64),
  scheduler_status:"queued"
}'
FAKE
chmod +x "${FAKE_OPENCLAW}"

PREPARED='{
  "status":"success",
  "project":"group/subgroup/project",
  "iid":42,
  "selector":{"type":"single","iid":42},
  "force_rerun_pr":false,
  "target_branch":null,
  "issue_url":null,
  "request_text":"处理 group/subgroup/project issue #42",
  "reason":null
}'
submit_output="$(
  STATE_ROOT="${SUBMIT_ROOT}" \
  PREPARED_REQUEST_JSON="${PREPARED}" \
  ORIGIN_JSON=null \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  ROUTING_FILE="" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  BATCH_ARGV_LOG="${BATCH_ARGV_LOG}" \
  BATCH_STDIN_LOG="${BATCH_STDIN_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/submit_executor_batch.sh"
)"
if ! jq -e '
  .status == "accepted"
  and (keys | index("callback_nonce") | not)
' <<<"${submit_output}" >/dev/null; then
  echo "new batch submission did not return a nonce-free compact acceptance" >&2
  printf '%s\n' "${submit_output}" >&2
  exit 1
fi

SUBMIT_OUTBOX="${SUBMIT_ROOT}/_dispatcher/executor_batch_outbox.json"
SUBMIT_MIRROR="${SUBMIT_ROOT}/_dispatcher/executor_batches.json"
generated_nonce="$(awk -F= '$1 == "callback_nonce" {print $2; exit}' "${BATCH_STDIN_LOG}")"
if ! [[ "${generated_nonce}" =~ ^[0-9a-f]{64}$ ]] \
  || ! jq -e '.requests | length == 0' "${SUBMIT_OUTBOX}" >/dev/null \
  || [ "$(find "${SUBMIT_ROOT}/_dispatcher/accepted_intents" -type f -name '*.json' | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "new batch I1 did not use a nonce and compact accepted hot state" >&2
  exit 1
fi
if grep -q -- "${generated_nonce}" "${BATCH_ARGV_LOG}" \
  || ! grep -q -- '--message-file /dev/stdin' "${BATCH_ARGV_LOG}" \
  || ! grep -qx "callback_nonce=${generated_nonce}" "${BATCH_STDIN_LOG}"; then
  echo "batch outbound transport exposed nonce in argv or lost stdin payload" >&2
  exit 1
fi
generated_nonce_sha256="$(printf '%s' "${generated_nonce}" | sha256_text)"
if ! jq -e --arg digest "${generated_nonce_sha256}" '
  (.batches | length) == 1
  and (.batches[]
    | .callback_auth_mode == "nonce_v1"
    and .project == "group/subgroup/project"
    and .executor_agent == "req_executor"
    and .callback_nonce_sha256 == $digest)
' "${SUBMIT_MIRROR}" >/dev/null; then
  echo "compact mirror did not persist project, executor, and nonce digest" >&2
  exit 1
fi
if grep -q -- "${generated_nonce}" "${SUBMIT_MIRROR}" \
  || grep -q -- "${generated_nonce}" <<<"${submit_output}"; then
  echo "batch nonce leaked outside the private durable I1 intent" >&2
  exit 1
fi

# A targeted submit/tick race must reconstruct the already durable acceptance
# instead of exposing a transient idle result or attempting I1 again.
submitted_batch_id="$(jq -r '.batch_id' <<<"${submit_output}")"
targeted_accepted_replay="$(
  STATE_ROOT="${SUBMIT_ROOT}" \
  BATCH_ID="${submitted_batch_id}" \
  OPENCLAW_BIN="${TEST_ROOT}/must-not-run-openclaw" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
if ! jq -e --arg batch_id "${submitted_batch_id}" '
  .status == "accepted"
  and .batch_id == $batch_id
  and .record_status == "duplicate"
  and (keys | index("callback_nonce") | not)
' <<<"${targeted_accepted_replay}" >/dev/null; then
  echo "targeted replay did not reconstruct the durable accepted state" >&2
  printf '%s\n' "${targeted_accepted_replay}" >&2
  exit 1
fi

# If another delivery owns the per-batch lock, a targeted caller still gets a
# durable retryable state rather than the internal lock word "busy".
LOCKED_ROOT="${TEST_ROOT}/locked-target-state"
LOCKED_BATCH_ID=batch-locked-target
LOCKED_CORRELATION_ID=reqd-locked-target
LOCKED_PAYLOAD="$(
  BATCH_ID="${LOCKED_BATCH_ID}" \
  CORRELATION_ID="${LOCKED_CORRELATION_ID}" \
  PROJECT=group/subgroup/project \
  SELECTOR_JSON='{"type":"single","iid":43}' \
  FORCE_RERUN_PR=false \
  EXECUTOR_AGENT=req_executor \
  CALLBACK_NONCE="${FIXED_NONCE}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
    "${BASH}" "${SKILL_DIR}/scripts/build_executor_batch_payload.sh"
)"
LOCKED_DIGEST="$(printf '%s' "${LOCKED_PAYLOAD}" | sha256_text)"
STATE_ROOT="${LOCKED_ROOT}" \
BATCH_ID="${LOCKED_BATCH_ID}" \
CORRELATION_ID="${LOCKED_CORRELATION_ID}" \
PROJECT=group/subgroup/project \
SELECTOR_JSON='{"type":"single","iid":43}' \
FORCE_RERUN_PR=false \
EXECUTOR_AGENT=req_executor \
CALLBACK_NONCE="${FIXED_NONCE}" \
ORIGIN_JSON=null \
PAYLOAD="${LOCKED_PAYLOAD}" \
REQUEST_DIGEST="${LOCKED_DIGEST}" \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_request.sh" >/dev/null
read -r locked_crc locked_length _locked_name \
  < <(printf '%s' "${LOCKED_BATCH_ID}" | cksum)
locked_batch_lock="${LOCKED_ROOT}/_dispatcher/executor_batch_outbox.${locked_crc}.${locked_length}.lock"
exec 8>"${locked_batch_lock}"
flock 8
locked_target_output="$(
  STATE_ROOT="${LOCKED_ROOT}" BATCH_ID="${LOCKED_BATCH_ID}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh" 8>&-
)"
flock -u 8
exec 8>&-
if ! jq -e --arg batch_id "${LOCKED_BATCH_ID}" --arg cid "${LOCKED_CORRELATION_ID}" '
  .status == "retryable_failure"
  and .reason == "delivery_in_progress"
  and .batch_id == $batch_id
  and .correlation_id == $cid
  and .attempts == 0
' <<<"${locked_target_output}" >/dev/null; then
  echo "targeted lock collision did not expose a durable retryable state" >&2
  printf '%s\n' "${locked_target_output}" >&2
  exit 1
fi

# Reproduce the narrower race where initial selection sees queued, another
# delivery commits accepted, and the targeted drain then acquires the batch
# lock. The post-lock read must win over the stale selected entry.
POST_LOCK_ROOT="${TEST_ROOT}/post-lock-accepted-state"
POST_LOCK_BATCH_ID=batch-post-lock-accepted
POST_LOCK_CORRELATION_ID=reqd-post-lock-accepted
POST_LOCK_PAYLOAD="$(
  BATCH_ID="${POST_LOCK_BATCH_ID}" \
  CORRELATION_ID="${POST_LOCK_CORRELATION_ID}" \
  PROJECT=group/subgroup/project \
  SELECTOR_JSON='{"type":"single","iid":44}' \
  FORCE_RERUN_PR=false \
  EXECUTOR_AGENT=req_executor \
  CALLBACK_NONCE="${FIXED_NONCE}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
    "${BASH}" "${SKILL_DIR}/scripts/build_executor_batch_payload.sh"
)"
POST_LOCK_DIGEST="$(printf '%s' "${POST_LOCK_PAYLOAD}" | sha256_text)"
STATE_ROOT="${POST_LOCK_ROOT}" \
BATCH_ID="${POST_LOCK_BATCH_ID}" \
CORRELATION_ID="${POST_LOCK_CORRELATION_ID}" \
PROJECT=group/subgroup/project \
SELECTOR_JSON='{"type":"single","iid":44}' \
FORCE_RERUN_PR=false \
EXECUTOR_AGENT=req_executor \
CALLBACK_NONCE="${FIXED_NONCE}" \
ORIGIN_JSON=null \
PAYLOAD="${POST_LOCK_PAYLOAD}" \
REQUEST_DIGEST="${POST_LOCK_DIGEST}" \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_request.sh" >/dev/null
REAL_FLOCK="$(command -v flock)"
RACE_BIN="${TEST_ROOT}/post-lock-race-bin"
mkdir -p "${RACE_BIN}"
cat >"${RACE_BIN}/flock" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -n ] && [ ! -e "${RACE_ONCE_FILE:?}" ]; then
  printf '%s\n' injected >"${RACE_ONCE_FILE}"
  candidate="${RACE_OUTBOX}.candidate.$$"
  jq --arg batch_id "${RACE_BATCH_ID:?}" --arg now '2026-07-11T00:00:00Z' '
    .requests |= map(
      if .batch_id == $batch_id then
        .status = "accepted"
        | .matched_count = 2
        | .snapshot_digest = ("d" * 64)
        | .scheduler_status = "queued"
        | .received_at = $now
        | .accepted_at = $now
        | .updated_at = $now
      else . end
    )
  ' "${RACE_OUTBOX:?}" >"${candidate}"
  mv "${candidate}" "${RACE_OUTBOX}"
fi
exec "${REAL_FLOCK:?}" "$@"
FAKE
chmod +x "${RACE_BIN}/flock"
post_lock_output="$(
  PATH="${RACE_BIN}:${PATH}" \
  REAL_FLOCK="${REAL_FLOCK}" \
  RACE_ONCE_FILE="${TEST_ROOT}/post-lock-race.once" \
  RACE_OUTBOX="${POST_LOCK_ROOT}/_dispatcher/executor_batch_outbox.json" \
  RACE_BATCH_ID="${POST_LOCK_BATCH_ID}" \
  STATE_ROOT="${POST_LOCK_ROOT}" \
  BATCH_ID="${POST_LOCK_BATCH_ID}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
if ! jq -e --arg batch_id "${POST_LOCK_BATCH_ID}" '
  .status == "accepted"
  and .batch_id == $batch_id
  and .correlation_id == "reqd-post-lock-accepted"
  and .matched_count == 2
  and .snapshot_digest == ("d" * 64)
  and .scheduler_status == "queued"
  and .record_status == "duplicate"
' <<<"${post_lock_output}" >/dev/null; then
  echo "targeted drain did not reconstruct accepted after its post-lock read" >&2
  printf '%s\n' "${post_lock_output}" >&2
  exit 1
fi

# Newly enqueued legacy-single work must also generate a distinct private nonce.
SINGLE_ROOT="${TEST_ROOT}/single-state"
for iid in 71 72; do
  STATE_ROOT="${SINGLE_ROOT}" \
  PROJECT="group/subgroup/project" \
  IID="${iid}" \
  EXECUTOR_AGENT="req_executor" \
    "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
done
if ! jq -e '
  (.queue | length) == 2
  and all(.queue[]; .callback_nonce | test("^[0-9a-f]{64}$"))
  and .queue[0].callback_nonce != .queue[1].callback_nonce
' "${SINGLE_ROOT}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "new single-Issue intents did not persist distinct high-entropy nonces" >&2
  exit 1
fi

SINGLE_OPENCLAW="${TEST_ROOT}/single-openclaw"
cat >"${SINGLE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' '{"status":"waiting_for_callbacks","chat_summary":"accepted"}'
FAKE
chmod +x "${SINGLE_OPENCLAW}"
single_launch_output="$(
  STATE_ROOT="${SINGLE_ROOT}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
  OPENCLAW_BIN="${SINGLE_OPENCLAW}" \
  EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS=0 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"
single_busy_output="$(
  STATE_ROOT="${SINGLE_ROOT}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
  OPENCLAW_BIN="${SINGLE_OPENCLAW}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"
active_correlation_id="$(jq -r '.active.correlation_id' \
  "${SINGLE_ROOT}/_dispatcher/executor_queue.json")"
single_queue_before_finish="$(jq -cS . \
  "${SINGLE_ROOT}/_dispatcher/executor_queue.json")"
single_pending_before_finish="$(jq -cS . \
  "${SINGLE_ROOT}/_dispatcher/pending.json")"
set +e
single_finish_output="$(
  STATE_ROOT="${SINGLE_ROOT}" CORRELATION_ID="${active_correlation_id}" \
    "${BASH}" "${SKILL_DIR}/scripts/finish_executor_queue_active.sh" 2>&1
)"
single_finish_rc=$?
set -e
if [ "${single_finish_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${SINGLE_ROOT}/_dispatcher/executor_queue.json")" \
    != "${single_queue_before_finish}" ] \
  || [ "$(jq -cS . "${SINGLE_ROOT}/_dispatcher/pending.json")" \
    != "${single_pending_before_finish}" ]; then
  echo "direct legacy finish did not reject nonce_v1 single-Issue state" >&2
  exit 1
fi
if grep -q 'callback_nonce' <<<"${single_launch_output}${single_busy_output}${single_finish_output}" \
  || grep -Eq '[0-9a-f]{64}' <<<"${single_launch_output}${single_busy_output}${single_finish_output}"; then
  echo "legacy-single public status output leaked callback nonce material" >&2
  exit 1
fi

# A failing downstream may echo the complete I1. Redact the actual bearer
# nonce before persisting launch_error, and omit private error text from every
# public active projection.
ECHO_FAILURE_ROOT="${TEST_ROOT}/single-echo-failure-state"
STATE_ROOT="${ECHO_FAILURE_ROOT}" \
PROJECT=group/subgroup/project \
IID=73 \
EXECUTOR_AGENT=req_executor \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
echoed_nonce="$(jq -r '.queue[0].callback_nonce' \
  "${ECHO_FAILURE_ROOT}/_dispatcher/executor_queue.json")"
ECHO_FAILURE_OPENCLAW="${TEST_ROOT}/echo-failure-openclaw"
ECHO_FAILURE_ARGV_LOG="${TEST_ROOT}/echo-failure-openclaw.argv"
cat >"${ECHO_FAILURE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
shift
message=""
printf '%s\n' "$*" >"${ECHO_FAILURE_ARGV_LOG:?}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent|--session-key|--timeout) shift 2 ;;
    --message-file)
      [ "$2" = /dev/stdin ] || exit 92
      message="$(cat)"
      shift 2
      ;;
    --message) exit 93 ;;
    *) exit 91 ;;
  esac
done
printf 'executor rejected echoed I1:\n%s\n' "${message}"
exit 31
FAKE
chmod +x "${ECHO_FAILURE_OPENCLAW}"
STATE_ROOT="${ECHO_FAILURE_ROOT}" \
DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
OPENCLAW_BIN="${ECHO_FAILURE_OPENCLAW}" \
ECHO_FAILURE_ARGV_LOG="${ECHO_FAILURE_ARGV_LOG}" \
EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS=1 \
EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS=0 \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_queue.sh" >/dev/null
persisted_launch_error="$(jq -r '.active.launch_error // ""' \
  "${ECHO_FAILURE_ROOT}/_dispatcher/executor_queue.json")"
echo_failure_public="$(
  STATE_ROOT="${ECHO_FAILURE_ROOT}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
  OPENCLAW_BIN="${ECHO_FAILURE_OPENCLAW}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"
if grep -q -- "${echoed_nonce}" <<<"${persisted_launch_error}${echo_failure_public}" \
  || grep -q -- "${echoed_nonce}" "${ECHO_FAILURE_ARGV_LOG}" \
  || ! grep -q -- '--message-file /dev/stdin' "${ECHO_FAILURE_ARGV_LOG}" \
  || [ "${persisted_launch_error}" \
    != "executor response contains callback authentication material" ] \
  || ! jq -e '.active | has("launch_error") | not' <<<"${echo_failure_public}" >/dev/null; then
  echo "echoed legacy-single I1 nonce or sensitive launch error escaped redaction" >&2
  exit 1
fi

single_payload="$(
  PROJECT='group/subgroup/project' \
  IID=71 \
  CORRELATION_ID=reqd-auth-71 \
  EXECUTOR_AGENT=req_executor \
  CALLBACK_NONCE="${FIXED_NONCE}" \
  DISPATCHER_CALLBACK_TARGET='agent:req_dispatcher:main' \
    "${BASH}" "${SKILL_DIR}/scripts/build_executor_payload.sh"
)"
if ! grep -qx 'executor_agent=req_executor' <<<"${single_payload}" \
  || ! grep -qx "callback_nonce=${FIXED_NONCE}" <<<"${single_payload}"; then
  echo "new RUN_SINGLE_ISSUE did not carry the callback authentication fields" >&2
  exit 1
fi

# A nonce_v1 mirror must reject every unauthenticated or mismatched transport
# without changing any durable projection, then accept the exact envelope once.
AUTH_ROOT="${TEST_ROOT}/authenticated-state"
set +e
STATE_ROOT="${AUTH_ROOT}" \
BATCH_ID='batch-auth-required' \
PROJECT='group/subgroup/project' \
EXECUTOR_AGENT='req_executor' \
ORIGIN_JSON=null \
MATCHED_COUNT=1 \
REQUEST_DIGEST='request-auth-required' \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" \
  >"${TEST_ROOT}/missing-hash.out" 2>"${TEST_ROOT}/missing-hash.err"
missing_hash_rc=$?
set -e
if [ "${missing_hash_rc}" -eq 0 ]; then
  echo "new mirror creation downgraded to unauthenticated mode without a nonce digest" >&2
  exit 1
fi

STATE_ROOT="${AUTH_ROOT}" \
BATCH_ID='batch-authenticated' \
PROJECT='group/subgroup/project' \
EXECUTOR_AGENT='req_executor' \
CALLBACK_AUTH_MODE=nonce_v1 \
CALLBACK_NONCE_SHA256="${FIXED_NONCE_SHA256}" \
ORIGIN_JSON=null \
MATCHED_COUNT=1 \
REQUEST_DIGEST='request-authenticated' \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null

EVENT_JSON="$(jq -cn '{
  event_id:"batch-authenticated:snapshot-0:terminal-1",
  batch_id:"batch-authenticated",
  snapshot_index:0,
  project:"group/subgroup/project",
  iid:42,
  status:"done",
  mr_url:null,
  reason:null
}')"
make_envelope() {
  local nonce="$1"
  local executor_agent="$2"
  local event_json="$3"
  jq -cn --arg nonce "${nonce}" --arg executor_agent "${executor_agent}" \
    --argjson event "${event_json}" '{
      callback_nonce:$nonce,
      executor_agent:$executor_agent,
      worker_result_json:$event
    }'
}
VALID_ENVELOPE="$(make_envelope "${FIXED_NONCE}" req_executor "${EVENT_JSON}")"

mirror_before="$(jq -cS . "${AUTH_ROOT}/_dispatcher/executor_batches.json")"
ledger_before="$(jq -scS . "${AUTH_ROOT}/_dispatcher/executor_batch_events.jsonl")"
notifications_before="$(jq -cS . "${AUTH_ROOT}/_dispatcher/executor_batch_notifications.json")"

assert_rejected_unchanged() {
  local name="$1"
  local mode="$2"
  local input="$3"
  local output
  local rc

  set +e
  if [ "${mode}" = direct_raw ]; then
    output="$(
      STATE_ROOT="${AUTH_ROOT}" WORKER_RESULT_JSON="${input}" \
      NOTIFY_USER_SCRIPT="${QUIET_NOTIFY}" TRANSPORT_LEAK_LOG="${TRANSPORT_LEAK_LOG}" \
        "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" \
        2>"${TEST_ROOT}/${name}.err"
    )"
  elif [ "${mode}" = raw ]; then
    output="$(
      STATE_ROOT="${AUTH_ROOT}" WORKER_RESULT_JSON="${input}" \
        "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh" \
        2>"${TEST_ROOT}/${name}.err"
    )"
  else
    output="$(
      STATE_ROOT="${AUTH_ROOT}" CALLBACK_ENVELOPE_JSON="${input}" \
      NOTIFY_USER_SCRIPT="${QUIET_NOTIFY}" TRANSPORT_LEAK_LOG="${TRANSPORT_LEAK_LOG}" \
        "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh" \
        2>"${TEST_ROOT}/${name}.err"
    )"
  fi
  rc=$?
  set -e

  if [ "${rc}" -eq 0 ] || [ -n "${output}" ]; then
    echo "authenticated callback rejection failed: ${name}" >&2
    printf 'rc=%s output=%s\n' "${rc}" "${output}" >&2
    exit 1
  fi
  if [ "$(jq -cS . "${AUTH_ROOT}/_dispatcher/executor_batches.json")" != "${mirror_before}" ] \
    || [ "$(jq -scS . "${AUTH_ROOT}/_dispatcher/executor_batch_events.jsonl")" != "${ledger_before}" ] \
    || [ "$(jq -cS . "${AUTH_ROOT}/_dispatcher/executor_batch_notifications.json")" != "${notifications_before}" ]; then
    echo "rejected authenticated callback changed state: ${name}" >&2
    exit 1
  fi
  if grep -q -- "${FIXED_NONCE}" "${TEST_ROOT}/${name}.err"; then
    echo "callback rejection logged the secret nonce: ${name}" >&2
    exit 1
  fi
}

assert_rejected_unchanged raw_public_i3 raw "${EVENT_JSON}"
assert_rejected_unchanged direct_apply_raw direct_raw "${EVENT_JSON}"
assert_rejected_unchanged wrong_nonce envelope \
  "$(make_envelope 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' req_executor "${EVENT_JSON}")"
assert_rejected_unchanged wrong_executor envelope \
  "$(make_envelope "${FIXED_NONCE}" other_executor "${EVENT_JSON}")"
assert_rejected_unchanged wrong_project envelope \
  "$(make_envelope "${FIXED_NONCE}" req_executor "$(jq -c '.project="group/other"' <<<"${EVENT_JSON}")")"
assert_rejected_unchanged extra_envelope_field envelope \
  "$(jq -c '.extra=true' <<<"${VALID_ENVELOPE}")"

TRIGGER="$(printf 'RUN_DRIVEN_BATCH_RESULT\ncallback_envelope=%s\n' "${VALID_ENVELOPE}")"
accepted_ack="$(
  STATE_ROOT="${AUTH_ROOT}" \
  CALLBACK_ENVELOPE_JSON="${VALID_ENVELOPE}" \
  NOTIFY_USER_SCRIPT="${QUIET_NOTIFY}" \
  TRANSPORT_LEAK_LOG="${TRANSPORT_LEAK_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if ! jq -e '
  (keys | sort) == ["event_id","status"]
  and .status == "accepted"
  and .event_id == "batch-authenticated:snapshot-0:terminal-1"
' <<<"${accepted_ack}" >/dev/null; then
  echo "valid authenticated callback did not return the strict public ack" >&2
  printf '%s\n' "${accepted_ack}" >&2
  exit 1
fi
if grep -R -q -- "${FIXED_NONCE}" "${AUTH_ROOT}" \
  || grep -q -- "${FIXED_NONCE}" <<<"${accepted_ack}"; then
  echo "callback nonce leaked into mirror, ledger, notification, or ack state" >&2
  exit 1
fi
if [ -s "${TRANSPORT_LEAK_LOG}" ]; then
  echo "callback transport environment leaked into the notification process" >&2
  exit 1
fi
direct_duplicate_ack="$(
  printf '%s\n' "${TRIGGER}" | \
    STATE_ROOT="${AUTH_ROOT}" \
    NOTIFY_USER_SCRIPT="${QUIET_NOTIFY}" \
    TRANSPORT_LEAK_LOG="${TRANSPORT_LEAK_LOG}" \
      "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${direct_duplicate_ack}" >/dev/null \
  || [ -s "${TRANSPORT_LEAK_LOG}" ]; then
  echo "direct callback envelope leaked its transport environment downstream" >&2
  exit 1
fi

# Only an explicitly marked pre-upgrade mirror may consume a plain public I3.
LEGACY_ROOT="${TEST_ROOT}/legacy-pre-upgrade-state"
STATE_ROOT="${LEGACY_ROOT}" \
BATCH_ID='batch-legacy-pre-upgrade' \
PROJECT='group/legacy' \
EXECUTOR_AGENT='req_executor' \
CALLBACK_AUTH_MODE=legacy_pre_upgrade \
ALLOW_LEGACY_PRE_UPGRADE=true \
ORIGIN_JSON=null \
MATCHED_COUNT=1 \
REQUEST_DIGEST='request-legacy-pre-upgrade' \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null
LEGACY_EVENT="$(jq -cn '{
  event_id:"batch-legacy-pre-upgrade:snapshot-0:terminal-1",
  batch_id:"batch-legacy-pre-upgrade",
  snapshot_index:0,
  project:"group/legacy",
  iid:9,
  status:"skipped",
  mr_url:null,
  reason:"pre-upgrade callback"
}')"
legacy_ack="$(
  STATE_ROOT="${LEGACY_ROOT}" WORKER_RESULT_JSON="${LEGACY_EVENT}" \
  NOTIFY_USER_SCRIPT="${QUIET_NOTIFY}" TRANSPORT_LEAK_LOG="${TRANSPORT_LEAK_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if ! jq -e '.status == "accepted"' <<<"${legacy_ack}" >/dev/null \
  || ! jq -e '
    .batches["batch-legacy-pre-upgrade"].callback_auth_mode == "legacy_pre_upgrade"
  ' "${LEGACY_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "explicit pre-upgrade mirror did not preserve narrow raw-I3 compatibility" >&2
  exit 1
fi

# A mirror row already on disk before deployment has no auth marker. The first
# old callback must atomically mark it pre-upgrade and retain the event project;
# this is the only implicit-to-explicit compatibility migration.
assert_pre_upgrade_apply_rejected_unchanged() {
  local case_name="$1"
  local mirror_fixture="$2"
  local callback_value="$3"
  local callback_mode="$4"
  local case_root="${TEST_ROOT}/pre-upgrade-reject-${case_name}"
  local mirror_file="${case_root}/_dispatcher/executor_batches.json"
  local ledger_file="${case_root}/_dispatcher/executor_batch_events.jsonl"
  local notifications_file="${case_root}/_dispatcher/executor_batch_notifications.json"
  local before_mirror before_ledger before_notifications apply_rc

  STATE_ROOT="${case_root}" "${BASH}" -c '
    source "$1"
    ensure_state_dirs
  ' _ "${SKILL_DIR}/scripts/env_paths.sh"
  printf '%s\n' "${mirror_fixture}" >"${mirror_file}"
  before_mirror="$(jq -cS . "${mirror_file}")"
  before_ledger="$(jq -scS . "${ledger_file}")"
  before_notifications="$(jq -cS . "${notifications_file}")"

  set +e
  if [ "${callback_mode}" = envelope ]; then
    STATE_ROOT="${case_root}" CALLBACK_ENVELOPE_JSON="${callback_value}" \
      "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null 2>&1
  else
    STATE_ROOT="${case_root}" WORKER_RESULT_JSON="${callback_value}" \
      "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null 2>&1
  fi
  apply_rc=$?
  set -e

  if [ "${apply_rc}" -eq 0 ] \
    || [ "$(jq -cS . "${mirror_file}")" != "${before_mirror}" ] \
    || [ "$(jq -scS . "${ledger_file}")" != "${before_ledger}" ] \
    || [ "$(jq -cS . "${notifications_file}")" != "${before_notifications}" ]; then
    echo "rejected pre-upgrade callback changed state before validation: ${case_name}" >&2
    exit 1
  fi
}

OLD_ROW_BASE='{"batch_id":"batch-old-target","executor_agent":"req_executor","origin":null,"matched_count":1,"terminal_count":0,"status":"queued","request_digest":"old-request","created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"}'
UNKNOWN_OLD_EVENT="$(jq -cn '{
  event_id:"batch-missing:snapshot-0:terminal-1",
  batch_id:"batch-missing",snapshot_index:0,project:"group/pre-upgrade",
  iid:90,status:"done",mr_url:null,reason:null
}')"
assert_pre_upgrade_apply_rejected_unchanged unknown_batch \
  "$(jq -cn --argjson row "${OLD_ROW_BASE}" '{batches:{"batch-old-target":$row}}')" \
  "${UNKNOWN_OLD_EVENT}" raw

INVALID_SCHEMA_EVENT="$(jq -cn '{
  event_id:"batch-old-schema:snapshot-0:terminal-1",
  batch_id:"batch-old-schema",snapshot_index:0,project:"group/pre-upgrade",
  iid:91,status:"done",mr_url:null,reason:null
}')"
assert_pre_upgrade_apply_rejected_unchanged invalid_schema \
  '{"batches":{"batch-old-schema":{"batch_id":"batch-old-schema","executor_agent":"req_executor","origin":null,"matched_count":"1","terminal_count":0,"status":"queued","request_digest":"old-request","created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"}}}' \
  "${INVALID_SCHEMA_EVENT}" raw

OUT_OF_RANGE_OLD_EVENT="$(jq -cn '{
  event_id:"batch-old-range:snapshot-1:terminal-1",
  batch_id:"batch-old-range",snapshot_index:1,project:"group/pre-upgrade",
  iid:92,status:"done",mr_url:null,reason:null
}')"
assert_pre_upgrade_apply_rejected_unchanged snapshot_out_of_range \
  "$(jq -cn --argjson row "$(jq -c '.batch_id="batch-old-range"' <<<"${OLD_ROW_BASE}")" '{batches:{"batch-old-range":$row}}')" \
  "${OUT_OF_RANGE_OLD_EVENT}" raw

AUTH_INCOMPATIBLE_OLD_EVENT="$(jq -cn '{
  event_id:"batch-old-auth:snapshot-0:terminal-1",
  batch_id:"batch-old-auth",snapshot_index:0,project:"group/pre-upgrade",
  iid:93,status:"done",mr_url:null,reason:null
}')"
assert_pre_upgrade_apply_rejected_unchanged incompatible_auth \
  "$(jq -cn --argjson row "$(jq -c '.batch_id="batch-old-auth"' <<<"${OLD_ROW_BASE}")" '{batches:{"batch-old-auth":$row}}')" \
  "$(make_envelope "${FIXED_NONCE}" req_executor "${AUTH_INCOMPATIBLE_OLD_EVENT}")" envelope

MIGRATION_ROOT="${TEST_ROOT}/pre-upgrade-migration-state"
STATE_ROOT="${MIGRATION_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
printf '%s\n' '{"batches":{"batch-before-auth":{"batch_id":"batch-before-auth","executor_agent":"req_executor","origin":null,"matched_count":1,"terminal_count":0,"status":"queued","request_digest":"old-request","created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"}}}' \
  >"${MIGRATION_ROOT}/_dispatcher/executor_batches.json"
MIGRATION_EVENT="$(jq -cn '{
  event_id:"batch-before-auth:snapshot-0:terminal-1",
  batch_id:"batch-before-auth",
  snapshot_index:0,
  project:"group/pre-upgrade",
  iid:10,
  status:"done",
  mr_url:null,
  reason:null
}')"
migration_ack="$(
  STATE_ROOT="${MIGRATION_ROOT}" WORKER_RESULT_JSON="${MIGRATION_EVENT}" \
  NOTIFY_USER_SCRIPT="${QUIET_NOTIFY}" TRANSPORT_LEAK_LOG="${TRANSPORT_LEAK_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if ! jq -e '.status == "accepted"' <<<"${migration_ack}" >/dev/null \
  || ! jq -e '
    .batches["batch-before-auth"].callback_auth_mode == "legacy_pre_upgrade"
    and .batches["batch-before-auth"].callback_nonce_sha256 == null
    and .batches["batch-before-auth"].project == "group/pre-upgrade"
  ' "${MIGRATION_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "pre-upgrade mirror was not explicitly and atomically migrated" >&2
  exit 1
fi

# A pre-upgrade single receipt can already be attached to active state. Its
# replay must add an explicit legacy marker instead of failing or inventing a
# nonce-protected identity.
OLD_RECEIPT_ROOT="${TEST_ROOT}/old-single-receipt-state"
STATE_ROOT="${OLD_RECEIPT_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
printf '%s\n' '{"next_id":2,"active":{"queue_id":"execq-1","correlation_id":"reqd-old","run_id":"executor-execq-1","project":"group/old-single","iid":17,"executor_agent":"req_executor","driven_batch_id":"single-old","driven_request_digest":"old-digest","driven_executor_agent":"req_executor","driven_matched_count":1,"driven_snapshot_digest":"old-snapshot","driven_scheduler_status":"queued"},"queue":[]}' \
  >"${OLD_RECEIPT_ROOT}/_dispatcher/executor_queue.json"
old_receipt_replay="$(
  STATE_ROOT="${OLD_RECEIPT_ROOT}" \
  QUEUE_ID=execq-1 \
  CORRELATION_ID=reqd-old \
  BATCH_ID=single-old \
  EXECUTOR_AGENT=req_executor \
  MATCHED_COUNT=1 \
  SNAPSHOT_DIGEST=old-snapshot \
  SCHEDULER_STATUS=queued \
  REQUEST_DIGEST=old-digest \
    "${BASH}" "${SKILL_DIR}/scripts/record_legacy_executor_batch_receipt.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${old_receipt_replay}" >/dev/null \
  || ! jq -e '
    .active.driven_project == "group/old-single"
    and .active.driven_callback_auth_mode == "legacy_pre_upgrade"
    and .active.driven_callback_nonce_sha256 == null
  ' "${OLD_RECEIPT_ROOT}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "pre-upgrade single receipt did not migrate to an explicit legacy marker" >&2
  exit 1
fi

OLD_BATCH_ROOT="${TEST_ROOT}/old-batch-receipt-state"
STATE_ROOT="${OLD_BATCH_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
printf '%s\n' '{"batches":{"batch-old-receipt":{"batch_id":"batch-old-receipt","executor_agent":"req_executor","origin":null,"matched_count":0,"terminal_count":0,"status":"completed","request_digest":"old-batch-digest","created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"}}}' \
  >"${OLD_BATCH_ROOT}/_dispatcher/executor_batches.json"
old_batch_replay="$(
  STATE_ROOT="${OLD_BATCH_ROOT}" \
  BATCH_ID=batch-old-receipt \
  PROJECT=group/old-batch \
  EXECUTOR_AGENT=req_executor \
  CALLBACK_AUTH_MODE=legacy_pre_upgrade \
  ALLOW_LEGACY_PRE_UPGRADE=true \
  ORIGIN_JSON=null \
  MATCHED_COUNT=0 \
  REQUEST_DIGEST=old-batch-digest \
    "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${old_batch_replay}" >/dev/null \
  || ! jq -e '
    .batches["batch-old-receipt"].project == "group/old-batch"
    and .batches["batch-old-receipt"].callback_auth_mode == "legacy_pre_upgrade"
    and .batches["batch-old-receipt"].callback_nonce_sha256 == null
  ' "${OLD_BATCH_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "pre-upgrade batch receipt did not migrate to an explicit legacy mirror" >&2
  exit 1
fi

CONFLICT_MIGRATION_ROOT="${TEST_ROOT}/old-batch-conflict-state"
STATE_ROOT="${CONFLICT_MIGRATION_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
printf '%s\n' '{"batches":{"batch-old-conflict":{"batch_id":"batch-old-conflict","executor_agent":"req_executor","origin":null,"matched_count":0,"terminal_count":0,"status":"completed","request_digest":"original-digest","created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"}}}' \
  >"${CONFLICT_MIGRATION_ROOT}/_dispatcher/executor_batches.json"
conflict_mirror_before="$(<"${CONFLICT_MIGRATION_ROOT}/_dispatcher/executor_batches.json")"
set +e
STATE_ROOT="${CONFLICT_MIGRATION_ROOT}" \
BATCH_ID=batch-old-conflict \
PROJECT=group/must-not-publish \
EXECUTOR_AGENT=req_executor \
CALLBACK_AUTH_MODE=legacy_pre_upgrade \
ALLOW_LEGACY_PRE_UPGRADE=true \
ORIGIN_JSON=null \
MATCHED_COUNT=0 \
REQUEST_DIGEST=conflicting-digest \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null 2>&1
conflict_migration_rc=$?
set -e
conflict_mirror_after="$(<"${CONFLICT_MIGRATION_ROOT}/_dispatcher/executor_batches.json")"
if [ "${conflict_migration_rc}" -eq 0 ] \
  || [ "${conflict_mirror_after}" != "${conflict_mirror_before}" ]; then
  echo "conflicting pre-upgrade receipt published migration fields before validation" >&2
  exit 1
fi

NULL_PROJECT_ROOT="${TEST_ROOT}/legacy-null-project-state"
STATE_ROOT="${NULL_PROJECT_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
printf '%s\n' '{"batches":{"batch-null-project":{"batch_id":"batch-null-project","project":null,"executor_agent":"req_executor","callback_auth_mode":"legacy_pre_upgrade","callback_nonce_sha256":null,"origin":null,"matched_count":0,"terminal_count":0,"status":"completed","request_digest":"null-project-digest","created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"}}}' \
  >"${NULL_PROJECT_ROOT}/_dispatcher/executor_batches.json"
null_project_replay="$(
  STATE_ROOT="${NULL_PROJECT_ROOT}" \
  BATCH_ID=batch-null-project \
  PROJECT=group/recovered-project \
  EXECUTOR_AGENT=req_executor \
  CALLBACK_AUTH_MODE=legacy_pre_upgrade \
  ALLOW_LEGACY_PRE_UPGRADE=true \
  ORIGIN_JSON=null \
  MATCHED_COUNT=0 \
  REQUEST_DIGEST=null-project-digest \
    "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${null_project_replay}" >/dev/null \
  || ! jq -e '
    .batches["batch-null-project"].project == "group/recovered-project"
  ' "${NULL_PROJECT_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "legacy mirror crash window with null project was not recoverable" >&2
  exit 1
fi

echo "ok executor callbacks require per-batch nonce authentication"
