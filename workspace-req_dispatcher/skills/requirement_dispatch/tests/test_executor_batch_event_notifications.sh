#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-batch-event.XXXXXX")"
STATE_ROOT_PATH="${TEST_ROOT}/state"
MIRROR_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batches.json"
EVENT_LEDGER_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batch_events.jsonl"
NOTIFICATIONS_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batch_notifications.json"
ORIGIN='{"channel":"wecom","user":"event-user","conversation":"event-conversation","reply_agent":"reply-agent"}'

STATE_ROOT="${STATE_ROOT_PATH}" \
BATCH_ID="batch-events" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT="2" \
REQUEST_DIGEST="request-digest-events" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null

EVENT_ID="batch-events:snapshot-0:terminal-1"
EVENT_JSON="$(jq -cnS \
  --arg event_id "${EVENT_ID}" \
  --arg batch_id "batch-events" \
  --arg project "group/project" \
  --arg status "done" \
  --arg mr_url "https://gitlab.example/group/project/-/merge_requests/9" '{
    event_id:$event_id,
    batch_id:$batch_id,
    snapshot_index:0,
    project:$project,
    iid:42,
    status:$status,
    mr_url:$mr_url,
    reason:null
  }')"

apply_event() {
  STATE_ROOT="${STATE_ROOT_PATH}" \
  WORKER_RESULT_JSON="$1" \
    "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh"
}

accepted_output="$(apply_event "${EVENT_JSON}")"
if ! jq -e --arg event_id "${EVENT_ID}" '
  type == "object"
  and (keys | sort) == ["event_id","status"]
  and .status == "accepted"
  and .event_id == $event_id
' <<<"${accepted_output}" >/dev/null; then
  echo "expected first I3 event to return the executor-compatible accepted ack" >&2
  printf '%s\n' "${accepted_output}" >&2
  exit 1
fi

if ! jq -e '
  .batches["batch-events"].matched_count == 2
  and .batches["batch-events"].terminal_count == 1
  and .batches["batch-events"].status == "running"
' "${MIRROR_FILE}" >/dev/null; then
  echo "expected first terminal event to advance terminal_count once" >&2
  sed -n '1,80p' "${MIRROR_FILE}" >&2
  exit 1
fi

if [ "$(wc -l < "${EVENT_LEDGER_FILE}" | tr -d ' ')" -ne 1 ]; then
  echo "expected exactly one event ledger row after first apply" >&2
  sed -n '1,80p' "${EVENT_LEDGER_FILE}" >&2
  exit 1
fi

if ! jq -e --arg event_id "${EVENT_ID}" '
  .event_id == $event_id
  and .batch_id == "batch-events"
  and .snapshot_index == 0
  and .project == "group/project"
  and .iid == 42
  and .status == "done"
  and .mr_url == "https://gitlab.example/group/project/-/merge_requests/9"
  and .reason == null
  and (.received_at | type == "string" and length > 0)
' "${EVENT_LEDGER_FILE}" >/dev/null; then
  echo "expected the accepted public I3 event in the durable ledger" >&2
  sed -n '1,80p' "${EVENT_LEDGER_FILE}" >&2
  exit 1
fi

if ! jq -e --arg event_id "${EVENT_ID}" '
  (.notifications | length) == 1
  and (.notifications[0] | keys | sort) == [
    "attempts","delivered_at","event_id","iid","mr_url","origin",
    "project","reason","status"
  ]
  and .notifications[0] == {
    event_id:$event_id,
    origin:{
      channel:"wecom",
      user:"event-user",
      conversation:"event-conversation",
      reply_agent:"reply-agent"
    },
    project:"group/project",
    iid:42,
    status:"done",
    mr_url:"https://gitlab.example/group/project/-/merge_requests/9",
    reason:null,
    attempts:0,
    delivered_at:null
  }
' "${NOTIFICATIONS_FILE}" >/dev/null; then
  echo "expected one exact per-Issue notification item" >&2
  sed -n '1,120p' "${NOTIFICATIONS_FILE}" >&2
  exit 1
fi

duplicate_output="$(apply_event "${EVENT_JSON}")"
if ! jq -e --arg event_id "${EVENT_ID}" '
  type == "object"
  and (keys | sort) == ["event_id","status"]
  and .status == "duplicate"
  and .event_id == $event_id
' <<<"${duplicate_output}" >/dev/null; then
  echo "expected replayed I3 event to return duplicate with the same event_id" >&2
  printf '%s\n' "${duplicate_output}" >&2
  exit 1
fi

if ! jq -e '
  .batches["batch-events"].terminal_count == 1
' "${MIRROR_FILE}" >/dev/null \
  || [ "$(wc -l < "${EVENT_LEDGER_FILE}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '(.notifications | length) == 1' "${NOTIFICATIONS_FILE}" >/dev/null; then
  echo "duplicate I3 event must not advance or enqueue anything twice" >&2
  exit 1
fi

unknown_event="$(jq -c '
  .event_id = "missing-batch:snapshot-0:terminal-1"
  | .batch_id = "missing-batch"
' <<<"${EVENT_JSON}")"
set +e
unknown_output="$(apply_event "${unknown_event}" 2>"${TEST_ROOT}/unknown.err")"
unknown_rc=$?
set -e
if [ "${unknown_rc}" -eq 0 ] \
  || ! jq -e '
    (keys | sort) == ["event_id","status"]
    and .status == "unknown_batch"
    and .event_id == "missing-batch:snapshot-0:terminal-1"
  ' <<<"${unknown_output}" >/dev/null; then
  echo "expected an unknown batch to fail explicitly with its event_id" >&2
  printf 'rc=%s output=%s\n' "${unknown_rc}" "${unknown_output}" >&2
  exit 1
fi

mirror_before_invalid="$(jq -cS . "${MIRROR_FILE}")"
ledger_before_invalid="$(jq -scS . "${EVENT_LEDGER_FILE}")"
notifications_before_invalid="$(jq -cS . "${NOTIFICATIONS_FILE}")"

assert_invalid_event() {
  local label="$1"
  local invalid_json="$2"
  local rc
  set +e
  apply_event "${invalid_json}" >"${TEST_ROOT}/${label}.out" 2>"${TEST_ROOT}/${label}.err"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "expected invalid I3 event to be rejected: ${label}" >&2
    sed -n '1,40p' "${TEST_ROOT}/${label}.out" >&2
    exit 1
  fi
}

assert_invalid_event mismatched_event_id "$(jq -c '.event_id = "batch-events:snapshot-1:terminal-1"' <<<"${EVENT_JSON}")"
assert_invalid_event invalid_iid "$(jq -c '.iid = 0' <<<"${EVENT_JSON}")"
assert_invalid_event invalid_status "$(jq -c '.status = "running"' <<<"${EVENT_JSON}")"
assert_invalid_event out_of_range_snapshot "$(jq -c '
  .snapshot_index = 2
  | .event_id = "batch-events:snapshot-2:terminal-1"
' <<<"${EVENT_JSON}")"
assert_invalid_event extra_field "$(jq -c '.unexpected = true' <<<"${EVENT_JSON}")"

if [ "$(jq -cS . "${MIRROR_FILE}")" != "${mirror_before_invalid}" ] \
  || [ "$(jq -scS . "${EVENT_LEDGER_FILE}")" != "${ledger_before_invalid}" ] \
  || [ "$(jq -cS . "${NOTIFICATIONS_FILE}")" != "${notifications_before_invalid}" ]; then
  echo "invalid or unknown I3 events unexpectedly changed dispatcher state" >&2
  exit 1
fi

# Batch lifecycle gates are terminal/control-plane state. A callback must not
# submit a waiting batch or resurrect a failed batch, even on duplicate replay.
STATE_GUARD_ROOT="${TEST_ROOT}/state-guard"
STATE_ROOT="${STATE_GUARD_ROOT}" \
BATCH_ID="batch-waiting" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT="1" \
REQUEST_DIGEST="request-digest-waiting" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null

jq -c '.batches["batch-waiting"].status = "waiting_for_legacy_drain"' \
  "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json" \
  >"${TEST_ROOT}/state-guard-waiting.json"
mv "${TEST_ROOT}/state-guard-waiting.json" \
  "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json"

WAITING_EVENT_JSON="$(jq -cnS '{
  event_id:"batch-waiting:snapshot-0:terminal-1",
  batch_id:"batch-waiting",
  snapshot_index:0,
  project:"group/project",
  iid:66,
  status:"done",
  mr_url:"https://gitlab.example/group/project/-/merge_requests/66",
  reason:null
}')"
waiting_before="$(jq -cS . "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json")"
set +e
STATE_ROOT="${STATE_GUARD_ROOT}" \
WORKER_RESULT_JSON="${WAITING_EVENT_JSON}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" \
  >"${TEST_ROOT}/waiting-event.out" 2>"${TEST_ROOT}/waiting-event.err"
waiting_event_rc=$?
set -e
if [ "${waiting_event_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json")" != "${waiting_before}" ] \
  || [ -s "${STATE_GUARD_ROOT}/_dispatcher/executor_batch_events.jsonl" ] \
  || ! jq -e '(.notifications | length) == 0' \
    "${STATE_GUARD_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "waiting_for_legacy_drain batch accepted or persisted an I3 event" >&2
  exit 1
fi

STATE_ROOT="${STATE_GUARD_ROOT}" \
BATCH_ID="batch-failed-duplicate" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT="1" \
REQUEST_DIGEST="request-digest-failed-duplicate" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null
FAILED_DUPLICATE_EVENT="$(jq -cnS '{
  event_id:"batch-failed-duplicate:snapshot-0:terminal-1",
  batch_id:"batch-failed-duplicate",
  snapshot_index:0,
  project:"group/project",
  iid:67,
  status:"failed",
  mr_url:null,
  reason:"terminal failure"
}')"
STATE_ROOT="${STATE_GUARD_ROOT}" \
WORKER_RESULT_JSON="${FAILED_DUPLICATE_EVENT}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null
jq -c '.batches["batch-failed-duplicate"].status = "failed"' \
  "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json" \
  >"${TEST_ROOT}/state-guard-failed.json"
mv "${TEST_ROOT}/state-guard-failed.json" \
  "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json"
failed_before="$(jq -cS . "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json")"
set +e
STATE_ROOT="${STATE_GUARD_ROOT}" \
WORKER_RESULT_JSON="${FAILED_DUPLICATE_EVENT}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" \
  >"${TEST_ROOT}/failed-duplicate.out" 2>"${TEST_ROOT}/failed-duplicate.err"
failed_duplicate_rc=$?
set -e
if [ "${failed_duplicate_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${STATE_GUARD_ROOT}/_dispatcher/executor_batches.json")" != "${failed_before}" ]; then
  echo "duplicate I3 event resurrected a failed batch" >&2
  exit 1
fi

# Crash consistency: the durable event ledger is the canonical commit. A
# process aborted immediately after its first atomic publish must leave that
# ledger row recoverable, and replay must repair both derived projections.
CRASH_STATE_ROOT="${TEST_ROOT}/crash-state"
STATE_ROOT="${CRASH_STATE_ROOT}" \
BATCH_ID="batch-crash" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT="1" \
REQUEST_DIGEST="request-digest-crash" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null

CRASH_EVENT_ID="batch-crash:snapshot-0:terminal-1"
CRASH_EVENT_JSON="$(jq -cnS \
  --arg event_id "${CRASH_EVENT_ID}" \
  --arg batch_id "batch-crash" \
  --arg project "group/project" '{
    event_id:$event_id,
    batch_id:$batch_id,
    snapshot_index:0,
    project:$project,
    iid:77,
    status:"failed",
    mr_url:null,
    reason:"crash recovery"
  }')"

FAKE_MV_BIN="${TEST_ROOT}/fake-mv-bin"
FAKE_MV_COUNT="${TEST_ROOT}/fake-mv.count"
mkdir -p "${FAKE_MV_BIN}"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' '/bin/mv "$@"'
  printf '%s\n' 'count=0'
  printf '%s\n' '[ ! -f "${FAKE_MV_COUNT}" ] || count="$(<"${FAKE_MV_COUNT}")"'
  printf '%s\n' 'count=$((count + 1))'
  printf '%s\n' 'printf "%s\n" "${count}" >"${FAKE_MV_COUNT}"'
  printf '%s\n' 'if [ "${count}" -eq 1 ]; then exit 99; fi'
} >"${FAKE_MV_BIN}/mv"
chmod +x "${FAKE_MV_BIN}/mv"

set +e
PATH="${FAKE_MV_BIN}:${PATH}" \
FAKE_MV_COUNT="${FAKE_MV_COUNT}" \
STATE_ROOT="${CRASH_STATE_ROOT}" \
WORKER_RESULT_JSON="${CRASH_EVENT_JSON}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" \
  >"${TEST_ROOT}/crash-apply.out" 2>"${TEST_ROOT}/crash-apply.err"
crash_apply_rc=$?
set -e
if [ "${crash_apply_rc}" -eq 0 ]; then
  echo "expected crash injection to kill event apply after its first publish" >&2
  exit 1
fi

if ! jq -e --arg event_id "${CRASH_EVENT_ID}" \
  'select(.event_id == $event_id)' \
  "${CRASH_STATE_ROOT}/_dispatcher/executor_batch_events.jsonl" >/dev/null; then
  echo "first event publish was not the canonical ledger commit" >&2
  exit 1
fi
if ! jq -e '
  .batches["batch-crash"].terminal_count == 0
' "${CRASH_STATE_ROOT}/_dispatcher/executor_batches.json" >/dev/null \
  || ! jq -e '(.notifications | length) == 0' \
    "${CRASH_STATE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "crash immediately after ledger commit unexpectedly published a partial projection" >&2
  exit 1
fi

crash_replay_output="$(
  STATE_ROOT="${CRASH_STATE_ROOT}" \
  WORKER_RESULT_JSON="${CRASH_EVENT_JSON}" \
    "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh"
)"
if ! jq -e --arg event_id "${CRASH_EVENT_ID}" '
  .status == "duplicate" and .event_id == $event_id
' <<<"${crash_replay_output}" >/dev/null; then
  echo "expected replay after a committed ledger row to return duplicate" >&2
  printf '%s\n' "${crash_replay_output}" >&2
  exit 1
fi
if ! jq -e '
  .batches["batch-crash"].terminal_count == 1
  and .batches["batch-crash"].status == "completed"
' "${CRASH_STATE_ROOT}/_dispatcher/executor_batches.json" >/dev/null \
  || ! jq -e --arg event_id "${CRASH_EVENT_ID}" '
    (.notifications | length) == 1
    and .notifications[0].event_id == $event_id
    and .notifications[0].attempts == 0
    and .notifications[0].delivered_at == null
  ' "${CRASH_STATE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "duplicate replay did not repair mirror and notification projections" >&2
  exit 1
fi

# Concurrent drains must not call notify twice for the same event. The first
# fake notifier blocks outside LOCK_FILE while the second drain races it.
CONCURRENT_STATE_ROOT="${TEST_ROOT}/concurrent-state"
STATE_ROOT="${CONCURRENT_STATE_ROOT}" \
BATCH_ID="batch-concurrent" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT="1" \
REQUEST_DIGEST="request-digest-concurrent" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null

CONCURRENT_EVENT_JSON="$(jq -cnS '{
  event_id:"batch-concurrent:snapshot-0:terminal-1",
  batch_id:"batch-concurrent",
  snapshot_index:0,
  project:"group/project",
  iid:88,
  status:"timeout",
  mr_url:null,
  reason:"concurrent drain"
}')"
STATE_ROOT="${CONCURRENT_STATE_ROOT}" \
WORKER_RESULT_JSON="${CONCURRENT_EVENT_JSON}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null

CONCURRENT_NOTIFY="${TEST_ROOT}/concurrent_notify.sh"
CONCURRENT_NOTIFY_LOG="${TEST_ROOT}/concurrent_notify.jsonl"
CONCURRENT_NOTIFY_STARTED="${TEST_ROOT}/concurrent_notify.started"
CONCURRENT_NOTIFY_RELEASE="${TEST_ROOT}/concurrent_notify.release"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'exec 8>"${LOCK_FILE}"'
  printf '%s\n' 'flock -n 8 || exit 91'
  printf '%s\n' 'flock -u 8'
  printf '%s\n' 'jq -cn --arg iid "${IID:-}" '\''{iid:$iid}'\'' >>"${CONCURRENT_NOTIFY_LOG}"'
  printf '%s\n' 'printf "%s\n" started >"${CONCURRENT_NOTIFY_STARTED}"'
  printf '%s\n' 'for _wait in {1..500}; do'
  printf '%s\n' '  [ ! -f "${CONCURRENT_NOTIFY_RELEASE}" ] || exit 0'
  printf '%s\n' '  sleep 0.01'
  printf '%s\n' 'done'
  printf '%s\n' 'exit 92'
} >"${CONCURRENT_NOTIFY}"
chmod +x "${CONCURRENT_NOTIFY}"

run_concurrent_drain() {
  STATE_ROOT="${CONCURRENT_STATE_ROOT}" \
  NOTIFY_USER_SCRIPT="${CONCURRENT_NOTIFY}" \
  CONCURRENT_NOTIFY_LOG="${CONCURRENT_NOTIFY_LOG}" \
  CONCURRENT_NOTIFY_STARTED="${CONCURRENT_NOTIFY_STARTED}" \
  CONCURRENT_NOTIFY_RELEASE="${CONCURRENT_NOTIFY_RELEASE}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh"
}

run_concurrent_drain >"${TEST_ROOT}/concurrent-drain-1.out" \
  2>"${TEST_ROOT}/concurrent-drain-1.err" &
concurrent_pid_1=$!
notify_started=0
for _wait in {1..500}; do
  if [ -f "${CONCURRENT_NOTIFY_STARTED}" ]; then
    notify_started=1
    break
  fi
  sleep 0.01
done
if [ "${notify_started}" -ne 1 ]; then
  echo "first concurrent drain never entered the lock-free notifier" >&2
  exit 1
fi

run_concurrent_drain >"${TEST_ROOT}/concurrent-drain-2.out" \
  2>"${TEST_ROOT}/concurrent-drain-2.err" &
concurrent_pid_2=$!
second_observed=0
for _wait in {1..500}; do
  concurrent_lines=0
  [ ! -f "${CONCURRENT_NOTIFY_LOG}" ] \
    || concurrent_lines="$(wc -l <"${CONCURRENT_NOTIFY_LOG}" | tr -d ' ')"
  if [ "${concurrent_lines}" -ge 2 ] || ! kill -0 "${concurrent_pid_2}" 2>/dev/null; then
    second_observed=1
    break
  fi
  sleep 0.01
done
if [ "${second_observed}" -ne 1 ]; then
  echo "second concurrent drain neither returned nor exposed a duplicate call" >&2
  exit 1
fi

printf '%s\n' release >"${CONCURRENT_NOTIFY_RELEASE}"
set +e
wait "${concurrent_pid_1}"
concurrent_rc_1=$?
wait "${concurrent_pid_2}"
concurrent_rc_2=$?
set -e
if [ "${concurrent_rc_1}" -ne 0 ] || [ "${concurrent_rc_2}" -ne 0 ]; then
  echo "concurrent notification drains did not both exit cleanly" >&2
  printf 'first=%s second=%s\n' "${concurrent_rc_1}" "${concurrent_rc_2}" >&2
  exit 1
fi

if [ "$(wc -l <"${CONCURRENT_NOTIFY_LOG}" | tr -d ' ')" -ne 1 ]; then
  echo "concurrent drains called notify more than once for one event" >&2
  sed -n '1,20p' "${CONCURRENT_NOTIFY_LOG}" >&2
  exit 1
fi
if ! jq -e '
  .notifications[0].attempts == 1
  and (.notifications[0].delivered_at | type == "string" and length > 0)
' "${CONCURRENT_STATE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "single concurrent notification owner did not commit delivery" >&2
  exit 1
fi

# The production notify_user.sh is best-effort and exits zero even when its
# openclaw call fails. The drain must inspect its durable outcome rather than
# treating that zero as delivery success.
STRICT_STATE_ROOT="${TEST_ROOT}/strict-notify-state"
STATE_ROOT="${STRICT_STATE_ROOT}" \
BATCH_ID="batch-strict-notify" \
EXECUTOR_AGENT="req_executor" \
ORIGIN_JSON="${ORIGIN}" \
MATCHED_COUNT="1" \
REQUEST_DIGEST="request-digest-strict-notify" \
  "${BASH}" "${SKILL_DIR}/scripts/record_executor_batch.sh" >/dev/null

STRICT_EVENT_JSON="$(jq -cnS '{
  event_id:"batch-strict-notify:snapshot-0:terminal-1",
  batch_id:"batch-strict-notify",
  snapshot_index:0,
  project:"group/project",
  iid:99,
  status:"failed",
  mr_url:null,
  reason:"strict delivery"
}')"
STATE_ROOT="${STRICT_STATE_ROOT}" \
WORKER_RESULT_JSON="${STRICT_EVENT_JSON}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null

STRICT_OPENCLAW_BIN="${TEST_ROOT}/strict-openclaw-bin"
STRICT_OPENCLAW_LOG="${TEST_ROOT}/strict-openclaw.log"
STRICT_OPENCLAW_SUCCESS="${TEST_ROOT}/strict-openclaw.success"
mkdir -p "${STRICT_OPENCLAW_BIN}"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\n" "$*" >>"${STRICT_OPENCLAW_LOG}"'
  printf '%s\n' '[ -f "${STRICT_OPENCLAW_SUCCESS}" ] || exit 17'
  printf '%s\n' 'exit 0'
} >"${STRICT_OPENCLAW_BIN}/openclaw"
chmod +x "${STRICT_OPENCLAW_BIN}/openclaw"

run_strict_notify_drain() {
  PATH="${STRICT_OPENCLAW_BIN}:${PATH}" \
  STRICT_OPENCLAW_LOG="${STRICT_OPENCLAW_LOG}" \
  STRICT_OPENCLAW_SUCCESS="${STRICT_OPENCLAW_SUCCESS}" \
  STATE_ROOT="${STRICT_STATE_ROOT}" \
  REPLY_GATEWAY_URL="ws://example.invalid:8080" \
  REPLY_GATEWAY_TOKEN="reply-token" \
  DEFAULT_REPLY_AGENT="fallback-agent" \
  REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh"
}

strict_failed_drain="$(run_strict_notify_drain 2>"${TEST_ROOT}/strict-notify-failed.err")"
if ! jq -e '
  .attempted == 1 and .delivered == 0 and .failed == 1
' <<<"${strict_failed_drain}" >/dev/null \
  || ! jq -e '
    .notifications[0].attempts == 1
    and .notifications[0].delivered_at == null
  ' "${STRICT_STATE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "production notify_user failure was incorrectly marked delivered" >&2
  printf '%s\n' "${strict_failed_drain}" >&2
  exit 1
fi

printf '%s\n' success >"${STRICT_OPENCLAW_SUCCESS}"
strict_success_drain="$(run_strict_notify_drain 2>"${TEST_ROOT}/strict-notify-success.err")"
if ! jq -e '
  .attempted == 1 and .delivered == 1 and .failed == 0
' <<<"${strict_success_drain}" >/dev/null \
  || ! jq -e '
    .notifications[0].attempts == 2
    and (.notifications[0].delivered_at | type == "string" and length > 0)
  ' "${STRICT_STATE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "production notify_user success did not mark the retained item delivered" >&2
  printf '%s\n' "${strict_success_drain}" >&2
  exit 1
fi
if [ "$(wc -l <"${STRICT_OPENCLAW_LOG}" | tr -d ' ')" -ne 2 ]; then
  echo "expected one failed and one successful production notify attempt" >&2
  exit 1
fi

FAKE_NOTIFY="${TEST_ROOT}/fake_notify.sh"
FAKE_NOTIFY_LOG="${TEST_ROOT}/fake_notify.jsonl"
FAKE_NOTIFY_MARKER="${TEST_ROOT}/fake_notify.first-attempt"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'exec 8>"${LOCK_FILE}"'
  printf '%s\n' 'if ! flock -n 8; then'
  printf '%s\n' '  printf "%s\n" "LOCK_HELD" >> "${FAKE_NOTIFY_LOG}"'
  printf '%s\n' '  exit 91'
  printf '%s\n' 'fi'
  printf '%s\n' 'flock -u 8'
  printf '%s\n' 'jq -cn --arg event "${EVENT:-}" --arg status "${STATUS:-}" --arg iid "${IID:-}" --arg mr_url "${MR_URL:-}" --arg reason "${REASON:-}" --argjson origin "${ORIGIN_JSON:-null}" '\''{event:$event,status:$status,iid:$iid,mr_url:$mr_url,reason:$reason,origin:$origin}'\'' >> "${FAKE_NOTIFY_LOG}"'
  printf '%s\n' 'if [ ! -f "${FAKE_NOTIFY_MARKER}" ]; then'
  printf '%s\n' '  printf "%s\n" first > "${FAKE_NOTIFY_MARKER}"'
  printf '%s\n' '  exit 23'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 0'
} >"${FAKE_NOTIFY}"
chmod +x "${FAKE_NOTIFY}"

drain_notifications() {
  STATE_ROOT="${STATE_ROOT_PATH}" \
  NOTIFY_USER_SCRIPT="${FAKE_NOTIFY}" \
  FAKE_NOTIFY_LOG="${FAKE_NOTIFY_LOG}" \
  FAKE_NOTIFY_MARKER="${FAKE_NOTIFY_MARKER}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh"
}

first_drain="$(drain_notifications 2>"${TEST_ROOT}/fake-notify-failed.err")"
if ! jq -e '
  .status == "drained"
  and .scanned == 1
  and .attempted == 1
  and .delivered == 0
  and .failed == 1
' <<<"${first_drain}" >/dev/null; then
  echo "expected first notification drain to retain the failed item" >&2
  printf '%s\n' "${first_drain}" >&2
  exit 1
fi
if ! jq -e '
  .notifications[0].attempts == 1
  and .notifications[0].delivered_at == null
' "${NOTIFICATIONS_FILE}" >/dev/null; then
  echo "expected failed notification to remain pending with one attempt" >&2
  sed -n '1,120p' "${NOTIFICATIONS_FILE}" >&2
  exit 1
fi

second_drain="$(drain_notifications 2>"${TEST_ROOT}/fake-notify-success.err")"
if ! jq -e '
  .status == "drained"
  and .scanned == 1
  and .attempted == 1
  and .delivered == 1
  and .failed == 0
' <<<"${second_drain}" >/dev/null; then
  echo "expected second notification drain to mark the item delivered" >&2
  printf '%s\n' "${second_drain}" >&2
  exit 1
fi
if ! jq -e '
  .notifications[0].attempts == 2
  and (.notifications[0].delivered_at | type == "string" and length > 0)
' "${NOTIFICATIONS_FILE}" >/dev/null; then
  echo "expected successful retry to set delivered_at by event_id" >&2
  sed -n '1,120p' "${NOTIFICATIONS_FILE}" >&2
  exit 1
fi

third_drain="$(drain_notifications 2>"${TEST_ROOT}/fake-notify-final.err")"
if ! jq -e '
  .status == "drained"
  and .scanned == 1
  and .attempted == 0
  and .delivered == 0
  and .failed == 0
' <<<"${third_drain}" >/dev/null; then
  echo "expected a delivered notification to be skipped on later drains" >&2
  printf '%s\n' "${third_drain}" >&2
  exit 1
fi

if grep -q '^LOCK_HELD$' "${FAKE_NOTIFY_LOG}"; then
  echo "notify_user was called while the shared dispatcher lock was held" >&2
  exit 1
fi
if ! jq -s -e '
  length == 2
  and all(.[];
    .event == "result"
    and .status == "done"
    and .iid == "42"
    and .mr_url == "https://gitlab.example/group/project/-/merge_requests/9"
    and .reason == ""
    and .origin.reply_agent == "reply-agent"
  )
' "${FAKE_NOTIFY_LOG}" >/dev/null; then
  echo "expected two lock-free notify attempts with the persisted item fields" >&2
  sed -n '1,80p' "${FAKE_NOTIFY_LOG}" >&2
  exit 1
fi

echo "ok executor batch events are deduplicated and notifications retry outside the lock"
