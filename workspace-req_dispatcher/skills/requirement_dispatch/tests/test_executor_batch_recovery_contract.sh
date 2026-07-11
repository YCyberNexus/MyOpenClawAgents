#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-batch-recovery.XXXXXX")"
ORIGIN='{"channel":"wecom","user":"recovery-user","conversation":"recovery-conversation","reply_agent":"reply-agent"}'

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# A durable receipt is a recovery boundary between an executor ack and the
# Task 8 mirror. Replaying it may advance scheduler_status, but immutable
# acceptance facts must conflict closed.
RECEIPT_ROOT="${TEST_ROOT}/receipt-state"
RECEIPT_BATCH_ID="batch-receipt-recovery"
RECEIPT_CORRELATION_ID="reqd-receipt-recovery"
RECEIPT_PAYLOAD="$(
  BATCH_ID="${RECEIPT_BATCH_ID}" \
  CORRELATION_ID="${RECEIPT_CORRELATION_ID}" \
  PROJECT="group/project" \
  SELECTOR_JSON='{"type":"single","iid":42}' \
  FORCE_RERUN_PR=false \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
    "${BASH}" "${SKILL_DIR}/scripts/build_executor_batch_payload.sh"
)"
RECEIPT_DIGEST="$(printf '%s' "${RECEIPT_PAYLOAD}" | sha256_text)"

STATE_ROOT="${RECEIPT_ROOT}" \
BATCH_ID="${RECEIPT_BATCH_ID}" \
CORRELATION_ID="${RECEIPT_CORRELATION_ID}" \
PROJECT="group/project" \
SELECTOR_JSON='{"type":"single","iid":42}' \
FORCE_RERUN_PR=false \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
PAYLOAD="${RECEIPT_PAYLOAD}" \
REQUEST_DIGEST="${RECEIPT_DIGEST}" \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_request.sh" >/dev/null

record_receipt() {
  STATE_ROOT="${RECEIPT_ROOT}" \
  BATCH_ID="${RECEIPT_BATCH_ID}" \
  EXECUTOR_AGENT="${1:-req_executor}" \
  MATCHED_COUNT="${2:-1}" \
  SNAPSHOT_DIGEST="${3:-snapshot-receipt-fixed}" \
  SCHEDULER_STATUS="${4:-queued}" \
    "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch_receipt.sh"
}

first_receipt="$(record_receipt)"
if ! jq -e '
  .status == "accepted"
  and .batch_id == "batch-receipt-recovery"
  and .scheduler_status == "queued"
' <<<"${first_receipt}" >/dev/null; then
  echo "expected the first compact receipt to become durable" >&2
  printf '%s\n' "${first_receipt}" >&2
  exit 1
fi

evolved_receipt="$(record_receipt req_executor 1 snapshot-receipt-fixed running)"
if ! jq -e '.status == "duplicate" and .scheduler_status == "running"' \
  <<<"${evolved_receipt}" >/dev/null; then
  echo "expected scheduler_status to evolve on an otherwise identical receipt" >&2
  printf '%s\n' "${evolved_receipt}" >&2
  exit 1
fi

receipt_before_conflicts="$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_batch_outbox.json")"
for conflict in executor matched snapshot; do
  set +e
  case "${conflict}" in
    executor) record_receipt other_executor 1 snapshot-receipt-fixed running >/dev/null 2>"${TEST_ROOT}/${conflict}.err" ;;
    matched) record_receipt req_executor 2 snapshot-receipt-fixed running >/dev/null 2>"${TEST_ROOT}/${conflict}.err" ;;
    snapshot) record_receipt req_executor 1 snapshot-conflict running >/dev/null 2>"${TEST_ROOT}/${conflict}.err" ;;
  esac
  conflict_rc=$?
  set -e
  if [ "${conflict_rc}" -eq 0 ]; then
    echo "receipt conflict did not fail closed: ${conflict}" >&2
    exit 1
  fi
  if [ "$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_batch_outbox.json")" != "${receipt_before_conflicts}" ]; then
    echo "receipt conflict changed durable state: ${conflict}" >&2
    exit 1
  fi
done

NO_NETWORK_OPENCLAW="${TEST_ROOT}/no-network-openclaw"
NO_NETWORK_LOG="${TEST_ROOT}/no-network.calls"
cat >"${NO_NETWORK_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' called >>"${NO_NETWORK_LOG:?NO_NETWORK_LOG required}"
exit 97
FAKE
chmod +x "${NO_NETWORK_OPENCLAW}"

repaired="$(
  STATE_ROOT="${RECEIPT_ROOT}" \
  OPENCLAW_BIN="${NO_NETWORK_OPENCLAW}" \
  NO_NETWORK_LOG="${NO_NETWORK_LOG}" \
  NOTIFY_USER_SCRIPT="${TEST_ROOT}/not-used-notifier" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
if ! jq -e '
  .status == "accepted"
  and .batch_id == "batch-receipt-recovery"
  and .matched_count == 1
  and .snapshot_digest == "snapshot-receipt-fixed"
  and .scheduler_status == "running"
' <<<"${repaired}" >/dev/null; then
  echo "expected a received I1 to repair its mirror without another network call" >&2
  printf '%s\n' "${repaired}" >&2
  exit 1
fi
if [ -s "${NO_NETWORK_LOG}" ]; then
  echo "receipt recovery unexpectedly resent I1" >&2
  exit 1
fi
if ! jq -e --arg batch_id "${RECEIPT_BATCH_ID}" '
  .batches[$batch_id].matched_count == 1
  and .batches[$batch_id].status == "queued"
' "${RECEIPT_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "receipt recovery did not create the compact Task 8 mirror" >&2
  exit 1
fi

# Simulate a zero-match process dying after its stable notification intent was
# written but before the received outbox row became accepted. Recovery must
# reuse that intent and never enqueue or deliver a second one.
ZERO_ROOT="${TEST_ROOT}/zero-receipt-state"
ZERO_BATCH_ID="batch-zero-receipt"
ZERO_PAYLOAD="$(
  BATCH_ID="${ZERO_BATCH_ID}" \
  CORRELATION_ID="reqd-zero-receipt" \
  PROJECT="group/project" \
  SELECTOR_JSON='{"type":"single","iid":99}' \
  FORCE_RERUN_PR=false \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
    "${BASH}" "${SKILL_DIR}/scripts/build_executor_batch_payload.sh"
)"
ZERO_DIGEST="$(printf '%s' "${ZERO_PAYLOAD}" | sha256_text)"
STATE_ROOT="${ZERO_ROOT}" \
BATCH_ID="${ZERO_BATCH_ID}" \
CORRELATION_ID="reqd-zero-receipt" \
PROJECT="group/project" \
SELECTOR_JSON='{"type":"single","iid":99}' \
FORCE_RERUN_PR=false \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON=null \
PAYLOAD="${ZERO_PAYLOAD}" \
REQUEST_DIGEST="${ZERO_DIGEST}" \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_request.sh" >/dev/null
STATE_ROOT="${ZERO_ROOT}" \
BATCH_ID="${ZERO_BATCH_ID}" \
EXECUTOR_AGENT="req_executor" \
MATCHED_COUNT=0 \
SNAPSHOT_DIGEST="snapshot-zero-fixed" \
SCHEDULER_STATUS=completed \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch_receipt.sh" >/dev/null
STATE_ROOT="${ZERO_ROOT}" \
BATCH_ID="${ZERO_BATCH_ID}" \
PROJECT="group/project" \
ORIGIN_JSON=null \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_empty_notification.sh" >/dev/null

ZERO_NOTIFY="${TEST_ROOT}/zero-notify.sh"
ZERO_NOTIFY_LOG="${TEST_ROOT}/zero-notify.calls"
cat >"${ZERO_NOTIFY}" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${EVENT}:${REASON}" >>"${ZERO_NOTIFY_LOG:?}"
exit 0
FAKE
chmod +x "${ZERO_NOTIFY}"
zero_repaired="$(
  STATE_ROOT="${ZERO_ROOT}" \
  OPENCLAW_BIN="${NO_NETWORK_OPENCLAW}" \
  NO_NETWORK_LOG="${NO_NETWORK_LOG}" \
  NOTIFY_USER_SCRIPT="${ZERO_NOTIFY}" \
  ZERO_NOTIFY_LOG="${ZERO_NOTIFY_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
STATE_ROOT="${ZERO_ROOT}" \
NOTIFY_USER_SCRIPT="${ZERO_NOTIFY}" \
ZERO_NOTIFY_LOG="${ZERO_NOTIFY_LOG}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh" >/dev/null
if ! jq -e '.status == "accepted" and .matched_count == 0' \
  <<<"${zero_repaired}" >/dev/null \
  || ! jq -e '
    [.notifications[] | select(.event_id == "batch-zero-receipt:no-matches")] | length == 1
  ' "${ZERO_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null \
  || [ "$(wc -l <"${ZERO_NOTIFY_LOG}" | tr -d ' ')" -ne 1 ]; then
  echo "zero-match receipt recovery duplicated its stable notification intent" >&2
  exit 1
fi

# A notification attempt may fail, but the I3 handler stdout must remain one
# strict ack. Replaying the same event must drain the retained notification.
FAIL_NOTIFY="${TEST_ROOT}/fail-notify.sh"
FAIL_NOTIFY_LOG="${TEST_ROOT}/fail-notify.calls"
SUCCESS_NOTIFY="${TEST_ROOT}/success-notify.sh"
SUCCESS_NOTIFY_LOG="${TEST_ROOT}/success-notify.calls"
cat >"${FAIL_NOTIFY}" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' 'noisy notify stdout must not pollute callback ack'
printf '%s\n' "${EVENT}:${STATUS}:${IID}" >>"${FAIL_NOTIFY_LOG:?FAIL_NOTIFY_LOG required}"
exit 23
FAKE
cat >"${SUCCESS_NOTIFY}" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${EVENT}:${STATUS}:${IID}" >>"${SUCCESS_NOTIFY_LOG:?SUCCESS_NOTIFY_LOG required}"
exit 0
FAKE
chmod +x "${FAIL_NOTIFY}" "${SUCCESS_NOTIFY}"

RECEIPT_EVENT="$(jq -cn --arg batch_id "${RECEIPT_BATCH_ID}" '{
  event_id:($batch_id + ":snapshot-0:terminal-1"),
  batch_id:$batch_id,
  snapshot_index:0,
  project:"group/project",
  iid:42,
  status:"done",
  mr_url:"https://gitlab.example/group/project/-/merge_requests/42",
  reason:null
}')"
RECEIPT_TRIGGER="$(printf 'RUN_DRIVEN_BATCH_RESULT\nworker_result_json=%s\n' "${RECEIPT_EVENT}")"
accepted_ack="$(
  printf '%s\n' "${RECEIPT_TRIGGER}" | \
    env \
      STATE_ROOT="${RECEIPT_ROOT}" \
      NOTIFY_USER_SCRIPT="${FAIL_NOTIFY}" \
      FAIL_NOTIFY_LOG="${FAIL_NOTIFY_LOG}" \
      "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if [ "$(wc -l <<<"${accepted_ack}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '
    (keys | sort) == ["event_id","status"]
    and .status == "accepted"
    and .event_id == "batch-receipt-recovery:snapshot-0:terminal-1"
  ' <<<"${accepted_ack}" >/dev/null; then
  echo "notification failure polluted or suppressed the accepted I3 ack" >&2
  printf '%s\n' "${accepted_ack}" >&2
  exit 1
fi
if ! jq -e '
  .notifications[0].attempts == 1
  and .notifications[0].delivered_at == null
' "${RECEIPT_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "failed notification was not retained after accepted ack" >&2
  exit 1
fi

duplicate_ack="$(
  STATE_ROOT="${RECEIPT_ROOT}" \
  WORKER_RESULT_JSON="${RECEIPT_EVENT}" \
  NOTIFY_USER_SCRIPT="${SUCCESS_NOTIFY}" \
  SUCCESS_NOTIFY_LOG="${SUCCESS_NOTIFY_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if [ "$(wc -l <<<"${duplicate_ack}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '.status == "duplicate"' <<<"${duplicate_ack}" >/dev/null \
  || [ "$(wc -l <"${FAIL_NOTIFY_LOG}" | tr -d ' ')" -ne 1 ] \
  || [ "$(wc -l <"${SUCCESS_NOTIFY_LOG}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '.notifications[0].delivered_at != null' \
    "${RECEIPT_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "duplicate I3 did not drain the retained notification exactly once" >&2
  printf '%s\n' "${duplicate_ack}" >&2
  exit 1
fi

callback_mirror_before="$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_batches.json")"
callback_ledger_before="$(jq -scS . "${RECEIPT_ROOT}/_dispatcher/executor_batch_events.jsonl")"
callback_notifications_before="$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_batch_notifications.json")"
callback_queue_before="$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_queue.json")"
callback_pending_before="$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/pending.json")"

assert_callback_trigger_rejected() {
  local name="$1"
  local trigger_text="$2"
  local callback_output
  local callback_rc

  set +e
  callback_output="$(
    printf '%s\n' "${trigger_text}" | \
      env \
        STATE_ROOT="${RECEIPT_ROOT}" \
        NOTIFY_USER_SCRIPT="${SUCCESS_NOTIFY}" \
        SUCCESS_NOTIFY_LOG="${SUCCESS_NOTIFY_LOG}" \
        "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh" \
        2>"${TEST_ROOT}/${name}.err"
  )"
  callback_rc=$?
  set -e

  if [ "${callback_rc}" -eq 0 ] || [ -n "${callback_output}" ]; then
    echo "invalid RUN_DRIVEN_BATCH_RESULT was acknowledged: ${name}" >&2
    printf '%s\n' "${callback_output}" >&2
    exit 1
  fi
  if [ "$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_batches.json")" != "${callback_mirror_before}" ] \
    || [ "$(jq -scS . "${RECEIPT_ROOT}/_dispatcher/executor_batch_events.jsonl")" != "${callback_ledger_before}" ] \
    || [ "$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_batch_notifications.json")" != "${callback_notifications_before}" ] \
    || [ "$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/executor_queue.json")" != "${callback_queue_before}" ] \
    || [ "$(jq -cS . "${RECEIPT_ROOT}/_dispatcher/pending.json")" != "${callback_pending_before}" ]; then
    echo "invalid RUN_DRIVEN_BATCH_RESULT changed dispatcher state: ${name}" >&2
    exit 1
  fi
}

assert_callback_trigger_rejected extra_callback_line \
  "${RECEIPT_TRIGGER}"$'\n''unexpected=true'
assert_callback_trigger_rejected duplicate_worker_result \
  "RUN_DRIVEN_BATCH_RESULT"$'\n'"worker_result_json=${RECEIPT_EVENT}"$'\n'"worker_result_json=${RECEIPT_EVENT}"
assert_callback_trigger_rejected non_object_worker_result \
  "RUN_DRIVEN_BATCH_RESULT"$'\n''worker_result_json=[]'
assert_callback_trigger_rejected missing_i3_field \
  "RUN_DRIVEN_BATCH_RESULT"$'\n'"worker_result_json=$(jq -c 'del(.reason)' <<<"${RECEIPT_EVENT}")"
assert_callback_trigger_rejected extra_i3_field \
  "RUN_DRIVEN_BATCH_RESULT"$'\n'"worker_result_json=$(jq -c '.extra = true' <<<"${RECEIPT_EVENT}")"

# The old FIFO RUN_SINGLE_ISSUE now receives driven I3, not old I2. Its compact
# acceptance must attach a bridge before the mirror becomes callback-visible.
# A skipped terminal event clears the old active item and advances the next
# item; a zero-match acceptance clears that second active item without I3.
LEGACY_ROOT="${TEST_ROOT}/legacy-state"
LEGACY_OPENCLAW="${TEST_ROOT}/legacy-openclaw"
LEGACY_OPENCLAW_LOG="${TEST_ROOT}/legacy-openclaw.calls.jsonl"
LEGACY_NOTIFY="${TEST_ROOT}/legacy-notify.sh"
LEGACY_NOTIFY_LOG="${TEST_ROOT}/legacy-notify.calls.jsonl"
SINGLE_BATCH_A="single-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SINGLE_BATCH_B="single-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cat >"${LEGACY_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
shift
message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent|--session-key|--timeout) shift 2 ;;
    --message) message="$2"; shift 2 ;;
    *) exit 91 ;;
  esac
done
iid="$(awk -F= '$1 == "iid" {print $2; exit}' <<<"${message}")"
jq -nc --arg iid "${iid}" --arg message "${message}" \
  '{iid:$iid,message:$message}' >>"${LEGACY_OPENCLAW_LOG:?LEGACY_OPENCLAW_LOG required}"
case "${iid}" in
  700)
    jq -nc --arg batch_id "${SINGLE_BATCH_A:?}" '{
      status:"success",batch_id:$batch_id,matched_count:1,
      snapshot_digest:"legacy-snapshot-a",scheduler_status:"queued"
    }'
    ;;
  701)
    jq -nc --arg batch_id "${SINGLE_BATCH_B:?}" '{
      status:"success",batch_id:$batch_id,matched_count:0,
      snapshot_digest:"legacy-snapshot-b",scheduler_status:"completed"
    }'
    ;;
  *) exit 92 ;;
esac
FAKE
cat >"${LEGACY_NOTIFY}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
jq -nc --arg event "${EVENT:-}" --arg status "${STATUS:-}" \
  --arg iid "${IID:-}" --arg reason "${REASON:-}" \
  '{event:$event,status:$status,iid:$iid,reason:$reason}' \
  >>"${LEGACY_NOTIFY_LOG:?LEGACY_NOTIFY_LOG required}"
FAKE
chmod +x "${LEGACY_OPENCLAW}" "${LEGACY_NOTIFY}"

for iid in 700 701; do
  STATE_ROOT="${LEGACY_ROOT}" \
  PROJECT="group/project" \
  IID="${iid}" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${ORIGIN}" \
  REQ_DIGEST="legacy ${iid}" \
    "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
done

legacy_first="$(
  STATE_ROOT="${LEGACY_ROOT}" \
  OPENCLAW_BIN="${LEGACY_OPENCLAW}" \
  LEGACY_OPENCLAW_LOG="${LEGACY_OPENCLAW_LOG}" \
  SINGLE_BATCH_A="${SINGLE_BATCH_A}" \
  SINGLE_BATCH_B="${SINGLE_BATCH_B}" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS=0 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"
if ! jq -e '.status == "launched" and .iid == 700' <<<"${legacy_first}" >/dev/null \
  || ! jq -e --arg batch_id "${SINGLE_BATCH_A}" '
    .active.driven_batch_id == $batch_id
    and .active.launch_state == "launched"
  ' "${LEGACY_ROOT}/_dispatcher/executor_queue.json" >/dev/null \
  || ! jq -e --arg batch_id "${SINGLE_BATCH_A}" '
    .batches[$batch_id].matched_count == 1
  ' "${LEGACY_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "legacy single acceptance did not attach a durable I3 bridge and mirror" >&2
  printf '%s\n' "${legacy_first}" >&2
  exit 1
fi

LEGACY_EVENT="$(jq -cn --arg batch_id "${SINGLE_BATCH_A}" '{
  event_id:($batch_id + ":snapshot-0:terminal-1"),
  batch_id:$batch_id,
  snapshot_index:0,
  project:"group/project",
  iid:700,
  status:"skipped",
  mr_url:null,
  reason:"already terminal"
}')"
legacy_ack="$(
  STATE_ROOT="${LEGACY_ROOT}" \
  WORKER_RESULT_JSON="${LEGACY_EVENT}" \
  NOTIFY_USER_SCRIPT="${LEGACY_NOTIFY}" \
  LEGACY_NOTIFY_LOG="${LEGACY_NOTIFY_LOG}" \
  OPENCLAW_BIN="${LEGACY_OPENCLAW}" \
  LEGACY_OPENCLAW_LOG="${LEGACY_OPENCLAW_LOG}" \
  SINGLE_BATCH_A="${SINGLE_BATCH_A}" \
  SINGLE_BATCH_B="${SINGLE_BATCH_B}" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS=0 \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if [ "$(wc -l <<<"${legacy_ack}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '.status == "accepted"' <<<"${legacy_ack}" >/dev/null; then
  echo "legacy bridge handler did not preserve the strict I3 ack" >&2
  printf '%s\n' "${legacy_ack}" >&2
  exit 1
fi
if ! jq -e '.active == null and (.queue | length) == 0' \
  "${LEGACY_ROOT}/_dispatcher/executor_queue.json" >/dev/null \
  || ! jq -e '.pending | length == 0' \
    "${LEGACY_ROOT}/_dispatcher/pending.json" >/dev/null \
  || [ "$(wc -l <"${LEGACY_OPENCLAW_LOG}" | tr -d ' ')" -ne 2 ]; then
  echo "legacy I3 did not clear active, advance, and clear the zero-match successor" >&2
  sed -n '1,160p' "${LEGACY_ROOT}/_dispatcher/executor_queue.json" >&2
  exit 1
fi
if ! jq -e --arg batch_a "${SINGLE_BATCH_A}" --arg batch_b "${SINGLE_BATCH_B}" '
  .batches[$batch_a].terminal_count == 1
  and .batches[$batch_a].status == "completed"
  and .batches[$batch_b].matched_count == 0
  and .batches[$batch_b].status == "completed"
' "${LEGACY_ROOT}/_dispatcher/executor_batches.json" >/dev/null; then
  echo "legacy bridge mirrors did not reach their durable terminal states" >&2
  exit 1
fi
if [ "$(wc -l <"${LEGACY_NOTIFY_LOG}" | tr -d ' ')" -ne 2 ] \
  || ! jq -s -e '
    .[0].status == "skipped"
    and .[1].event == "failure"
    and .[1].reason == "无匹配 OPEN Issue"
  ' "${LEGACY_NOTIFY_LOG}" >/dev/null; then
  echo "legacy skipped and zero-match notifications were not emitted once each" >&2
  sed -n '1,120p' "${LEGACY_NOTIFY_LOG}" >&2
  exit 1
fi

legacy_duplicate="$(
  STATE_ROOT="${LEGACY_ROOT}" \
  WORKER_RESULT_JSON="${LEGACY_EVENT}" \
  NOTIFY_USER_SCRIPT="${LEGACY_NOTIFY}" \
  LEGACY_NOTIFY_LOG="${LEGACY_NOTIFY_LOG}" \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${legacy_duplicate}" >/dev/null \
  || [ "$(wc -l <"${LEGACY_NOTIFY_LOG}" | tr -d ' ')" -ne 2 ]; then
  echo "legacy duplicate I3 repeated a terminal notification" >&2
  exit 1
fi

# A production notify can durably log success and then crash before the shared
# delivered_at projection commits. The event-specific log must repair that
# projection on restart without a second OpenClaw call.
CRASH_ROOT="${TEST_ROOT}/notify-crash-state"
CRASH_BATCH_ID="batch-notify-crash"
STATE_ROOT="${CRASH_ROOT}" \
BATCH_ID="${CRASH_BATCH_ID}" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT=1 \
REQUEST_DIGEST="notify-crash-request" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null
CRASH_EVENT="$(jq -cn --arg batch_id "${CRASH_BATCH_ID}" '{
  event_id:($batch_id + ":snapshot-0:terminal-1"),
  batch_id:$batch_id,
  snapshot_index:0,
  project:"group/project",
  iid:88,
  status:"done",
  mr_url:"https://gitlab.example/group/project/-/merge_requests/88",
  reason:null
}')"
STATE_ROOT="${CRASH_ROOT}" WORKER_RESULT_JSON="${CRASH_EVENT}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null

FAKE_MV_BIN="${TEST_ROOT}/notify-fake-mv-bin"
FAKE_OPENCLAW_BIN="${TEST_ROOT}/notify-fake-openclaw-bin"
FAKE_MV_COUNT="${TEST_ROOT}/notify-fake-mv.count"
CRASH_OPENCLAW_LOG="${TEST_ROOT}/notify-openclaw.calls"
mkdir -p "${FAKE_MV_BIN}" "${FAKE_OPENCLAW_BIN}"
cat >"${FAKE_MV_BIN}/mv" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
destination="${!#}"
if [ "${destination}" = "${EXECUTOR_BATCH_NOTIFICATIONS_FILE:?}" ]; then
  count=0
  [ ! -f "${FAKE_MV_COUNT:?}" ] || count="$(<"${FAKE_MV_COUNT}")"
  count=$((count + 1))
  printf '%s\n' "${count}" >"${FAKE_MV_COUNT}"
  [ "${count}" -ne 2 ] || exit 99
fi
/bin/mv "$@"
FAKE
cat >"${FAKE_OPENCLAW_BIN}/openclaw" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CRASH_OPENCLAW_LOG:?}"
exit 0
FAKE
chmod +x "${FAKE_MV_BIN}/mv" "${FAKE_OPENCLAW_BIN}/openclaw"

set +e
PATH="${FAKE_MV_BIN}:${FAKE_OPENCLAW_BIN}:${PATH}" \
FAKE_MV_COUNT="${FAKE_MV_COUNT}" \
CRASH_OPENCLAW_LOG="${CRASH_OPENCLAW_LOG}" \
STATE_ROOT="${CRASH_ROOT}" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="reply-token" \
DEFAULT_REPLY_AGENT="reply-agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS=1 \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh" \
  >"${TEST_ROOT}/notify-crash-first.out" 2>"${TEST_ROOT}/notify-crash-first.err"
first_crash_rc=$?
set -e
if [ "${first_crash_rc}" -eq 0 ] \
  || [ "$(wc -l <"${CRASH_OPENCLAW_LOG}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '
    .notifications[0].attempts == 1
    and .notifications[0].delivered_at == null
  ' "${CRASH_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null \
  || ! find "${CRASH_ROOT}/_dispatcher/executor_batch_notification_attempts" \
    -name user_notify.jsonl -type f -exec jq -e \
      'select(.kind == "user_notify" and .delivered == true)' {} \; >/dev/null; then
  echo "failed to establish notify-success-before-delivery-commit crash fixture" >&2
  exit 1
fi

recovered_notify="$(
  PATH="${FAKE_OPENCLAW_BIN}:${PATH}" \
  CRASH_OPENCLAW_LOG="${CRASH_OPENCLAW_LOG}" \
  STATE_ROOT="${CRASH_ROOT}" \
  REPLY_GATEWAY_URL="ws://example.invalid:8080" \
  REPLY_GATEWAY_TOKEN="reply-token" \
  DEFAULT_REPLY_AGENT="reply-agent" \
  REPLY_NOTIFY_TIMEOUT_SECONDS=1 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh"
)"
if ! jq -e '.attempted == 0 and .delivered == 1 and .failed == 0' \
  <<<"${recovered_notify}" >/dev/null \
  || [ "$(wc -l <"${CRASH_OPENCLAW_LOG}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '.notifications[0].delivered_at != null' \
    "${CRASH_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "durable notify success was not recovered without a duplicate OpenClaw call" >&2
  printf '%s\n' "${recovered_notify}" >&2
  exit 1
fi

echo "ok executor batch receipts, legacy bridge, I3 ack, and notify recovery are durable"
