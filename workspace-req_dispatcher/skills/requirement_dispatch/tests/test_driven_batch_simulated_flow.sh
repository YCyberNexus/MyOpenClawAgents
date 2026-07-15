#!/usr/bin/env bash
set -euo pipefail
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-driven-flow.XXXXXX")"
STATE_ROOT_PATH="${TEST_ROOT}/state"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls.jsonl"
DRIVEN_COUNT_FILE="${TEST_ROOT}/driven.count"
FAKE_NOTIFY="${TEST_ROOT}/notify.sh"
FAKE_EVICT="${TEST_ROOT}/evict.sh"
NOTIFY_LOG="${TEST_ROOT}/notify.calls.jsonl"
ORIGIN='{"channel":"wecom","user":"batch-user","conversation":"batch-conversation","reply_agent":"reply-agent"}'
export EXECUTOR_AGENT=req_executor
export CALLBACK_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

make_callback_envelope() {
  local nonce="$1"
  local event_json="$2"
  jq -cn --arg nonce "${nonce}" --argjson event "${event_json}" '{
    callback_nonce:$nonce,
    executor_agent:"req_executor",
    worker_result_json:$event
  }'
}

cat >"${FAKE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = agent ] || exit 91
shift
target_agent=""
message=""
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) target_agent="$2"; shift 2 ;;
    --session-key) shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --message-file) message_file="$2"; shift 2 ;;
    --timeout) shift 2 ;;
    *) exit 92 ;;
  esac
done
[ -z "${message_file}" ] || [ "${message_file}" = /dev/stdin ] || exit 93
[ -z "${message_file}" ] || message="$(cat)"

trigger="$(sed -n '1p' <<<"${message}")"
token_env_present=false
for token_name in GITLAB_TOKEN GLAB_TOKEN GITLAB_PRIVATE_TOKEN PRIVATE_TOKEN WIKI_GITLAB_TOKEN; do
  if [ -n "$(printenv "${token_name}" 2>/dev/null || true)" ]; then
    token_env_present=true
  fi
done

persisted_before_call=false
batch_id=""
if [ "${trigger}" = RUN_DRIVEN_ISSUE_BATCH ]; then
  batch_id="$(awk -F= '$1 == "batch_id" {print substr($0, index($0, "=") + 1); exit}' <<<"${message}")"
  outbox_file="${STATE_ROOT:?STATE_ROOT required}/_dispatcher/executor_batch_outbox.json"
  if jq -e --arg batch_id "${batch_id}" --arg payload "${message}" '
    any(.requests[];
      .batch_id == $batch_id
      and .payload == $payload
      and .attempts >= 1
      and (.status == "queued" or .status == "waiting_for_legacy_drain"))
  ' "${outbox_file}" >/dev/null 2>&1; then
    persisted_before_call=true
  fi
fi

redacted_message="$(sed -E 's/^callback_nonce=.*/callback_nonce=<redacted>/' <<<"${message}")"

jq -nc \
  --arg agent "${target_agent}" \
  --arg run_id "${OPENCLAW_RUN_ID:-}" \
  --arg trigger "${trigger}" \
  --arg message "${redacted_message}" \
  --argjson token_env_present "${token_env_present}" \
  --argjson persisted_before_call "${persisted_before_call}" '{
    agent:$agent,
    run_id:$run_id,
    trigger:$trigger,
    message:$message,
    token_env_present:$token_env_present,
    persisted_before_call:$persisted_before_call
  }' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"

case "${trigger}" in
  RUN_SINGLE_ISSUE)
    jq -nc '{
      status:"success",
      batch_id:"single-legacy-gate-fixture",
      matched_count:0,
      snapshot_digest:("d" * 64),
      scheduler_status:"completed"
    }'
    ;;
  RUN_DRIVEN_ISSUE_BATCH)
    if grep -qx 'iid=99' <<<"${message}"; then
      jq -nc --arg batch_id "${batch_id}" '{
        status:"success",
        batch_id:$batch_id,
        matched_count:0,
        snapshot_digest:("a" * 64),
        scheduler_status:"completed"
      }'
      exit 0
    fi

    driven_count=0
    [ ! -f "${DRIVEN_COUNT_FILE:?DRIVEN_COUNT_FILE required}" ] \
      || driven_count="$(<"${DRIVEN_COUNT_FILE}")"
    driven_count=$((driven_count + 1))
    printf '%s\n' "${driven_count}" >"${DRIVEN_COUNT_FILE}"
    if [ "${driven_count}" -eq 1 ]; then
      printf '%s\n' 'executor accepted but gateway ack was lost' >&2
      exit 23
    fi
    jq -nc --arg batch_id "${batch_id}" '{
      status:"success",
      batch_id:$batch_id,
      matched_count:3,
      snapshot_digest:("b" * 64),
      scheduler_status:"queued"
    }'
    ;;
  *)
    echo "unexpected trigger: ${trigger}" >&2
    exit 93
    ;;
esac
FAKE
chmod +x "${FAKE_OPENCLAW}"

cat >"${FAKE_EVICT}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
exit 0
FAKE
chmod +x "${FAKE_EVICT}"
export EVICT_STUCK_SCRIPT="${FAKE_EVICT}"

cat >"${FAKE_NOTIFY}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
exec 8>"${LOCK_FILE:?LOCK_FILE required}"
flock -n 8 || exit 94
flock -u 8
token_env_present=false
for token_name in GITLAB_TOKEN GLAB_TOKEN GITLAB_PRIVATE_TOKEN PRIVATE_TOKEN WIKI_GITLAB_TOKEN; do
  if [ -n "$(printenv "${token_name}" 2>/dev/null || true)" ]; then
    token_env_present=true
  fi
done
jq -nc \
  --arg event "${EVENT:-}" \
  --arg status "${STATUS:-}" \
  --arg project "${PROJECT:-}" \
  --arg iid "${IID:-}" \
  --arg reason "${REASON:-}" \
  --argjson token_env_present "${token_env_present}" '{
    event:$event,
    status:$status,
    project:$project,
    iid:$iid,
    reason:$reason,
    token_env_present:$token_env_present
  }' >>"${NOTIFY_LOG:?NOTIFY_LOG required}"
FAKE
chmod +x "${FAKE_NOTIFY}"

common_env=(
  STATE_ROOT="${STATE_ROOT_PATH}"
  DEFAULT_EXECUTOR_AGENT="req_executor"
  ROUTING_FILE=""
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main"
  OPENCLAW_BIN="${FAKE_OPENCLAW}"
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}"
  DRIVEN_COUNT_FILE="${DRIVEN_COUNT_FILE}"
  NOTIFY_USER_SCRIPT="${FAKE_NOTIFY}"
  NOTIFY_LOG="${NOTIFY_LOG}"
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600"
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="600"
  EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS="0"
  GITLAB_TOKEN="dispatcher-token"
  WIKI_GITLAB_TOKEN="dispatcher-wiki-token"
)

EMPTY_CALLBACK_STATE="${TEST_ROOT}/empty-callback-state"
EMPTY_CALLBACK_LOG="${TEST_ROOT}/empty-callback.calls.jsonl"
set +e
empty_callback_output="$(
  env "${common_env[@]}" \
    STATE_ROOT="${EMPTY_CALLBACK_STATE}" \
    OPENCLAW_CALL_LOG="${EMPTY_CALLBACK_LOG}" \
    DRIVEN_COUNT_FILE="${TEST_ROOT}/empty-callback.count" \
    DISPATCHER_CALLBACK_TARGET="" \
    MESSAGE='处理 group/project issue #9' \
    ORIGIN_JSON="${ORIGIN}" \
    "${BASH}" "${SKILL_DIR}/scripts/submit_executor_batch.sh" 2>&1
)"
empty_callback_rc=$?
set -e
if [ "${empty_callback_rc}" -eq 0 ]; then
  echo "empty dispatcher_callback_target must fail before persisting or sending I1" >&2
  printf '%s\n' "${empty_callback_output}" >&2
  exit 1
fi
if [ -f "${EMPTY_CALLBACK_STATE}/_dispatcher/executor_batch_outbox.json" ] \
  && ! jq -e '.requests | length == 0' \
    "${EMPTY_CALLBACK_STATE}/_dispatcher/executor_batch_outbox.json" >/dev/null; then
  echo "empty callback target persisted a batch intent" >&2
  exit 1
fi
if [ -s "${EMPTY_CALLBACK_LOG}" ]; then
  echo "empty callback target reached the executor" >&2
  exit 1
fi

# submit_executor_batch must report the batch it just enqueued even when older
# retryable and receipt-recovery work already exists in the global outbox.
TARGETED_STATE_ROOT="${TEST_ROOT}/targeted-submit-state"
TARGETED_CALL_LOG="${TEST_ROOT}/targeted-submit.calls.jsonl"
TARGETED_NOTIFY_LOG="${TEST_ROOT}/targeted-submit.notify.jsonl"
TARGETED_OUTBOX="${TARGETED_STATE_ROOT}/_dispatcher/executor_batch_outbox.json"

enqueue_prior_batch() {
  local batch_id="$1"
  local correlation_id="$2"
  local iid="$3"
  local payload
  local digest

  payload="$(
    BATCH_ID="${batch_id}" \
    CORRELATION_ID="${correlation_id}" \
    PROJECT="group/project" \
    SELECTOR_JSON="{\"type\":\"single\",\"iid\":${iid}}" \
    FORCE_RERUN_PR="false" \
    DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
      "${BASH}" "${SKILL_DIR}/scripts/build_executor_batch_payload.sh"
  )"
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "${payload}" | sha256sum | awk '{print $1}')"
  else
    digest="$(printf '%s' "${payload}" | shasum -a 256 | awk '{print $1}')"
  fi
  STATE_ROOT="${TARGETED_STATE_ROOT}" \
  BATCH_ID="${batch_id}" \
  CORRELATION_ID="${correlation_id}" \
  PROJECT="group/project" \
  SELECTOR_JSON="{\"type\":\"single\",\"iid\":${iid}}" \
  FORCE_RERUN_PR="false" \
  TARGET_BRANCH="" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${ORIGIN}" \
  PAYLOAD="${payload}" \
  REQUEST_DIGEST="${digest}" \
    "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_request.sh" >/dev/null
}

enqueue_prior_batch "older-retryable" "older-correlation-retryable" 91
enqueue_prior_batch "older-received" "older-correlation-received" 92
jq -c '
  .requests |= map(
    if .batch_id == "older-retryable" then
      .attempts = 1
      | .last_attempt_at = .updated_at
      | .last_error = "ambiguous_ack"
    elif .batch_id == "older-received" then
      .status = "received"
      | .attempts = 1
      | .last_attempt_at = .updated_at
      | .matched_count = 1
      | .snapshot_digest = ("c" * 64)
      | .scheduler_status = "queued"
      | .received_at = .updated_at
    else . end
  )
' "${TARGETED_OUTBOX}" >"${TEST_ROOT}/targeted-submit.outbox.next.json"
mv "${TEST_ROOT}/targeted-submit.outbox.next.json" "${TARGETED_OUTBOX}"

targeted_output="$(
  env "${common_env[@]}" \
    STATE_ROOT="${TARGETED_STATE_ROOT}" \
    OPENCLAW_CALL_LOG="${TARGETED_CALL_LOG}" \
    DRIVEN_COUNT_FILE="${TEST_ROOT}/targeted-submit.count" \
    NOTIFY_LOG="${TARGETED_NOTIFY_LOG}" \
    MESSAGE='请处理 group/project issue #99，基于 develop 分支处理，执行完成后直接 merge 到 release 分支' \
    ORIGIN_JSON="${ORIGIN}" \
    "${BASH}" "${SKILL_DIR}/scripts/submit_executor_batch.sh"
)"
targeted_batch_id="$(jq -r '.batch_id // ""' <<<"${targeted_output}")"
if ! jq -e '
  .status == "accepted"
  and .batch_id == "reqd-batch-1"
  and .matched_count == 0
  and .scheduler_status == "completed"
' <<<"${targeted_output}" >/dev/null; then
  echo "submit returned another outbox entry instead of its newly enqueued batch" >&2
  printf '%s\n' "${targeted_output}" >&2
  exit 1
fi
if [ "${targeted_batch_id}" != "reqd-batch-1" ] \
  || ! jq -e '
    (.requests[] | select(.batch_id == "older-retryable")
      | .status == "queued" and .attempts == 1)
    and (.requests[] | select(.batch_id == "older-received")
      | .status == "received" and .attempts == 1)
    and ([.requests[] | select(.batch_id == "reqd-batch-1")] | length == 0)
  ' "${TARGETED_OUTBOX}" >/dev/null; then
  echo "targeted submit changed or replayed an older outbox entry" >&2
  exit 1
fi
if [ "$(find "${TARGETED_STATE_ROOT}/_dispatcher/accepted_intents" -type f -name '*.json' | wc -l | tr -d ' ')" -ne 1 ] \
  || ! find "${TARGETED_STATE_ROOT}/_dispatcher/accepted_intents" \
    -type f -name '*.json' -exec jq -e \
      '.batch_id == "reqd-batch-1"
      and .matched_count == 0' {} + >/dev/null; then
  echo "targeted auto-merge submit did not compact its accepted intent" >&2
  exit 1
fi
if [ "$(wc -l <"${TARGETED_CALL_LOG}" | tr -d ' ')" -ne 1 ] \
  || ! jq -e '
    .trigger == "RUN_DRIVEN_ISSUE_BATCH"
    and .persisted_before_call == true
    and (.message | contains("batch_id=reqd-batch-1"))
    and (.message | contains("iid=99"))
    and (.message | contains("branch=develop"))
    and (.message | contains("auto_merge=true"))
    and (.message | contains("merge_target_branch=release"))
  ' "${TARGETED_CALL_LOG}" >/dev/null; then
  echo "targeted auto-merge submit did not deliver exactly its own complete batch once" >&2
  exit 1
fi

env \
  STATE_ROOT="${STATE_ROOT_PATH}" \
  PROJECT="group/project" \
  IID="700" \
  EXECUTOR_AGENT="req_executor" \
  REQ_DIGEST="legacy issue" \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null

waiting_output="$(
  env "${common_env[@]}" \
    MESSAGE='处理 group/project 的 issue #1,#4,#5' \
    ORIGIN_JSON="${ORIGIN}" \
    "${BASH}" "${SKILL_DIR}/scripts/submit_executor_batch.sh"
)"

if ! jq -e '
  .status == "waiting_for_legacy_drain"
  and (.batch_id | type == "string" and length > 0)
  and (.correlation_id | type == "string" and length > 0)
' <<<"${waiting_output}" >/dev/null; then
  echo "expected a durable batch to wait for the legacy queue" >&2
  printf '%s\n' "${waiting_output}" >&2
  exit 1
fi

BATCH_ID="$(jq -r '.batch_id' <<<"${waiting_output}")"
CORRELATION_ID="$(jq -r '.correlation_id' <<<"${waiting_output}")"
OUTBOX_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json"
MIRROR_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batches.json"
NOTIFICATIONS_FILE="${STATE_ROOT_PATH}/_dispatcher/executor_batch_notifications.json"

if ! jq -e --arg batch_id "${BATCH_ID}" --arg correlation_id "${CORRELATION_ID}" '
  (.requests | length) == 1
  and .requests[0].batch_id == $batch_id
  and .requests[0].correlation_id == $correlation_id
  and .requests[0].status == "waiting_for_legacy_drain"
  and .requests[0].selector == {type:"iid_list",iids:[1,4,5]}
  and (.requests[0].payload | startswith("RUN_DRIVEN_ISSUE_BATCH\n"))
  and (.requests[0].payload | contains("selector_type=iid_list"))
  and (.requests[0].payload | contains("iids=1,4,5"))
' "${OUTBOX_FILE}" >/dev/null; then
  echo "expected the I1 request to be persisted before legacy drain" >&2
  sed -n '1,120p' "${OUTBOX_FILE}" >&2
  exit 1
fi
EVENT_CALLBACK_NONCE="$(jq -r --arg batch_id "${BATCH_ID}" '
  .requests[] | select(.batch_id == $batch_id) | .callback_nonce
' "${OUTBOX_FILE}")"
if ! [[ "${EVENT_CALLBACK_NONCE}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "persisted batch did not expose its callback nonce before delivery" >&2
  exit 1
fi

if [ -e "${OPENCLAW_CALL_LOG}" ] && jq -e '
  select(.trigger == "RUN_DRIVEN_ISSUE_BATCH")
' "${OPENCLAW_CALL_LOG}" >/dev/null; then
  echo "batch I1 was sent while the legacy queue was non-empty" >&2
  exit 1
fi

legacy_tick="$(
  env "${common_env[@]}" \
    "${BASH}" "${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
)"
if ! jq -e '
  .status == "tick"
  and .legacy_queue.status == "completed_zero_match"
  and .batch_outbox.status == "retryable_failure"
' <<<"${legacy_tick}" >/dev/null; then
  echo "expected the dispatcher tick to clear the single bridge and retain the batch after ack loss" >&2
  printf '%s\n' "${legacy_tick}" >&2
  exit 1
fi
lost_ack_tick="${legacy_tick}"
if ! jq -e '
  .status == "tick"
  and .legacy_queue.status == "completed_zero_match"
  and .batch_outbox.status == "retryable_failure"
' <<<"${lost_ack_tick}" >/dev/null; then
  echo "expected an ack loss to retain the same durable batch for retry" >&2
  printf '%s\n' "${lost_ack_tick}" >&2
  exit 1
fi
if ! jq -e --arg batch_id "${BATCH_ID}" '
  .requests[0].batch_id == $batch_id
  and .requests[0].status == "queued"
  and .requests[0].attempts == 1
  and .requests[0].accepted_at == null
' "${OUTBOX_FILE}" >/dev/null; then
  echo "ack loss did not retain the durable outbox entry" >&2
  exit 1
fi

accepted_tick="$(
  env "${common_env[@]}" \
    "${BASH}" "${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
)"
if ! jq -e --arg batch_id "${BATCH_ID}" '
  .status == "tick"
  and .batch_outbox.status == "accepted"
  and .batch_outbox.batch_id == $batch_id
  and .batch_outbox.matched_count == 3
' <<<"${accepted_tick}" >/dev/null; then
  echo "expected replayed I1 to record the compact executor acceptance" >&2
  printf '%s\n' "${accepted_tick}" >&2
  exit 1
fi

if ! jq -s -e --arg batch_id "${BATCH_ID}" --arg correlation_id "${CORRELATION_ID}" '
  [ .[] | select(.trigger == "RUN_DRIVEN_ISSUE_BATCH") ] as $calls
  | ($calls | length) == 2
  and $calls[0].message == $calls[1].message
  and $calls[0].run_id == ("executor-batch-" + $batch_id + "-attempt-1")
  and $calls[1].run_id == ("executor-batch-" + $batch_id + "-attempt-2")
  and $calls[0].run_id != $calls[1].run_id
  and all($calls[];
    .token_env_present == true
    and .persisted_before_call == true
    and (.message | contains("batch_id=" + $batch_id))
    and (.message | contains("correlation_id=" + $correlation_id)))
' "${OPENCLAW_CALL_LOG}" >/dev/null; then
  echo "expected identical persisted I1 replay with inherited GitLab token env after ack loss" >&2
  sed -n '1,120p' "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi
if ! jq -s -e 'all(.[]; .token_env_present == true)' \
  "${OPENCLAW_CALL_LOG}" >/dev/null; then
  echo "dispatcher removed GitLab token material from a legacy or batch executor turn" >&2
  sed -n '1,120p' "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if ! jq -e --arg batch_id "${BATCH_ID}" '
  .batches[$batch_id].matched_count == 3
  and .batches[$batch_id].terminal_count == 0
  and .batches[$batch_id].status == "queued"
' "${MIRROR_FILE}" >/dev/null \
  || jq -e '.. | objects | select(has("snapshot") or has("iids") or has("iid"))' \
    "${MIRROR_FILE}" >/dev/null; then
  echo "expected a compact Task 8 mirror without an IID snapshot" >&2
  sed -n '1,120p' "${MIRROR_FILE}" >&2
  exit 1
fi

make_event() {
  local snapshot_index="$1"
  local iid="$2"
  local status="$3"
  local mr_url="$4"
  local reason="$5"
  jq -cn \
    --arg batch_id "${BATCH_ID}" \
    --arg snapshot_index "${snapshot_index}" \
    --arg iid "${iid}" \
    --arg status "${status}" \
    --arg mr_url "${mr_url}" \
    --arg reason "${reason}" '{
      event_id:($batch_id + ":snapshot-" + $snapshot_index + ":terminal-1"),
      batch_id:$batch_id,
      snapshot_index:($snapshot_index | tonumber),
      project:"group/project",
      iid:($iid | tonumber),
      status:$status,
      mr_url:(if $mr_url == "" then null else $mr_url end),
      reason:(if $reason == "" then null else $reason end)
    }'
}

DONE_EVENT="$(make_event 0 1 done 'https://gitlab.example/group/project/-/merge_requests/1' '')"
SKIPPED_EVENT="$(make_event 1 2 skipped '' 'already closed')"
TIMEOUT_EVENT="$(make_event 2 3 timeout '' 'execution timeout')"
notify_count_before_results=0
if [ -f "${NOTIFY_LOG}" ]; then
  notify_count_before_results="$(wc -l <"${NOTIFY_LOG}" | tr -d ' ')"
fi
for event_json in "${DONE_EVENT}" "${SKIPPED_EVENT}" "${TIMEOUT_EVENT}"; do
  event_id="$(jq -r '.event_id' <<<"${event_json}")"
  callback_envelope="$(make_callback_envelope "${EVENT_CALLBACK_NONCE}" "${event_json}")"
  ack="$(
    env "${common_env[@]}" \
      CALLBACK_ENVELOPE_JSON="${callback_envelope}" \
      "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
  )"
  if ! jq -e --arg event_id "${event_id}" '
    .status == "accepted" and .event_id == $event_id
  ' <<<"${ack}" >/dev/null; then
    echo "expected the fixed I3 handler to return the same accepted event_id" >&2
    printf '%s\n' "${ack}" >&2
    exit 1
  fi
done

duplicate_ack="$(
  env "${common_env[@]}" \
    CALLBACK_ENVELOPE_JSON="$(make_callback_envelope "${EVENT_CALLBACK_NONCE}" "${DONE_EVENT}")" \
    "${BASH}" "${SKILL_DIR}/scripts/handle_executor_batch_event.sh"
)"
if ! jq -e --arg event_id "$(jq -r '.event_id' <<<"${DONE_EVENT}")" '
  .status == "duplicate" and .event_id == $event_id
' <<<"${duplicate_ack}" >/dev/null; then
  echo "expected duplicate I3 to return the same duplicate ack" >&2
  printf '%s\n' "${duplicate_ack}" >&2
  exit 1
fi

post_event_tick="$(
  env "${common_env[@]}" \
    "${BASH}" "${SKILL_DIR}/scripts/run_executor_batch_tick.sh"
)"
if ! jq -e '
  .status == "tick"
  and .notifications.status == "drained"
  and .notifications.delivered == 3
' <<<"${post_event_tick}" >/dev/null; then
  echo "expected the periodic tick to deliver all three durable notifications" >&2
  printf '%s\n' "${post_event_tick}" >&2
  exit 1
fi

if [ "$(wc -l <"${NOTIFY_LOG}" | tr -d ' ')" -ne $((notify_count_before_results + 3)) ] \
  || ! jq -s -e --argjson baseline "${notify_count_before_results}" '
    .[$baseline:] | map([.event, .status, .project, .iid, .token_env_present])
      == [
        ["result","done","group/project","1",true],
        ["result","skipped","group/project","2",true],
        ["result","timeout","group/project","3",true]
      ]
  ' "${NOTIFY_LOG}" >/dev/null; then
  echo "expected exactly three new per-Issue result notifications with no extra event" >&2
  sed -n '1,120p' "${NOTIFY_LOG}" >&2
  exit 1
fi
if ! jq -e --arg batch_id "${BATCH_ID}" '
  .batches[$batch_id].terminal_count == 3
  and .batches[$batch_id].status == "completed"
' "${MIRROR_FILE}" >/dev/null; then
  echo "expected done/skipped/timeout to complete the compact mirror" >&2
  exit 1
fi

ZERO_PREPARED='{
  "status":"success",
  "project":"group/project",
  "iid":99,
  "selector":{"type":"single","iid":99},
  "force_rerun_pr":false,
  "target_branch":null,
  "issue_url":null,
  "request_text":"处理 group/project issue #99",
  "reason":null
}'
notify_count_before_zero="$(wc -l <"${NOTIFY_LOG}" | tr -d ' ')"
cold_count_before_zero="$(find "${STATE_ROOT_PATH}/_dispatcher/delivered_notifications" \
  -type f -name '*.json' | wc -l | tr -d ' ')"
hot_delivered_before_zero="$(jq -r \
  '[.notifications[] | select(.delivered_at != null)] | length' \
  "${NOTIFICATIONS_FILE}")"
cold_no_match_before_zero="$(find "${STATE_ROOT_PATH}/_dispatcher/delivered_notifications" \
  -type f -name '*.json' -exec jq -ce 'select(.status == "no_matches")' {} \; \
  | wc -l | tr -d ' ')"
zero_output="$(
  env "${common_env[@]}" \
    PREPARED_REQUEST_JSON="${ZERO_PREPARED}" \
    ORIGIN_JSON="${ORIGIN}" \
    "${BASH}" "${SKILL_DIR}/scripts/submit_executor_batch.sh"
)"
if ! jq -e '
  .status == "accepted"
  and .matched_count == 0
  and .scheduler_status == "completed"
' <<<"${zero_output}" >/dev/null; then
  echo "expected a structured zero-match selector to complete" >&2
  printf '%s\n' "${zero_output}" >&2
  exit 1
fi

env "${common_env[@]}" \
  "${BASH}" "${SKILL_DIR}/scripts/run_executor_batch_tick.sh" >/dev/null

if [ "$(wc -l <"${NOTIFY_LOG}" | tr -d ' ')" -ne $((notify_count_before_zero + 1)) ] \
  || ! tail -n 1 "${NOTIFY_LOG}" | jq -e '
    .event == "failure"
    and .iid == ""
    and .reason == "无匹配 OPEN Issue"
  ' >/dev/null; then
  echo "matched_count=0 must generate exactly one durable no-match notification" >&2
  sed -n '1,160p' "${NOTIFY_LOG}" >&2
  exit 1
fi
if ! jq -s -e 'all(.[]; .token_env_present == true)' \
  "${NOTIFY_LOG}" >/dev/null; then
  echo "dispatcher removed GitLab token material from a user notification" >&2
  sed -n '1,160p' "${NOTIFY_LOG}" >&2
  exit 1
fi
if ! jq -e '.notifications | length == 0' "${NOTIFICATIONS_FILE}" >/dev/null \
  || [ "$(find "${STATE_ROOT_PATH}/_dispatcher/delivered_notifications" -type f -name '*.json' | wc -l | tr -d ' ')" -ne $((cold_count_before_zero + hot_delivered_before_zero + 1)) ] \
  || [ "$(find "${STATE_ROOT_PATH}/_dispatcher/delivered_notifications" \
      -type f -name '*.json' -exec jq -ce 'select(.status == "no_matches")' {} \; \
      | wc -l | tr -d ' ')" -ne $((cold_no_match_before_zero + 1)) ]; then
  echo "expected one cold no_matches notification item" >&2
  exit 1
fi

echo "ok driven batch dispatcher flow is durable and idempotent"
