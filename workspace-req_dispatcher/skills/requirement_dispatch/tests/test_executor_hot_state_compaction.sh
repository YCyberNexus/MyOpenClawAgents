#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-hot-compaction.XXXXXX")"
STATE_ROOT_PATH="${TEST_ROOT}/state"
CALLBACK_NONCE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

STATE_ROOT="${STATE_ROOT_PATH}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"

jq -cn --arg callback_nonce "${CALLBACK_NONCE}" '
  {
    version:1,
    requests:[range(0;128) as $i | {
      batch_id:("history-batch-" + ($i | tostring)),
      correlation_id:("reqd-history-" + ($i | tostring)),
      project:"group/project",
      selector:{type:"single",iid:($i + 1)},
      force_rerun_pr:false,
      target_branch:null,
      executor_agent:"req_executor",
      callback_nonce:$callback_nonce,
      origin:null,
      payload:("RUN_DRIVEN_ISSUE_BATCH\nbatch_id=history-batch-" + ($i | tostring)
        + "\nexecutor_agent=req_executor\ncallback_nonce=" + $callback_nonce),
      request_digest:("a" * 64),
      status:"accepted",
      attempts:1,
      last_attempt_at:"2026-07-11T00:00:00Z",
      last_error:null,
      matched_count:1,
      snapshot_digest:("b" * 64),
      scheduler_status:"completed",
      created_at:"2026-07-11T00:00:00Z",
      updated_at:"2026-07-11T00:00:00Z",
      received_at:"2026-07-11T00:00:00Z",
      accepted_at:"2026-07-11T00:00:00Z"
    }]
  }
' >"${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json"

STATE_ROOT="${STATE_ROOT_PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh" >/dev/null
if ! jq -e '.requests | length == 0' \
  "${STATE_ROOT_PATH}/_dispatcher/executor_batch_outbox.json" >/dev/null \
  || [ "$(find "${STATE_ROOT_PATH}/_dispatcher/accepted_intents" -type f -name '*.json' | wc -l | tr -d ' ')" -ne 128 ]; then
  echo "accepted batch history remained in the hot outbox" >&2
  exit 1
fi

if ! find "${STATE_ROOT_PATH}/_dispatcher/accepted_intents" \
    -type f -name '*.json' -exec jq -e --arg nonce "${CALLBACK_NONCE}" '
      (keys | sort) == [
        "accepted_at","batch_id","callback_auth_mode","correlation_id",
        "matched_count","scheduler_status","snapshot_digest","version"
      ]
      and .version == 1
      and .callback_auth_mode == "nonce_v1"
      and (.snapshot_digest | test("^[0-9a-f]{64}$"))
      and (tostring | contains($nonce) | not)
      and (has("callback_nonce") | not)
      and (has("payload") | not)
    ' {} + >/dev/null; then
  echo "cold acceptance archive retained sensitive nonce or payload fields" >&2
  exit 1
fi

targeted_replay="$(
  STATE_ROOT="${STATE_ROOT_PATH}" BATCH_ID=history-batch-77 \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
if ! jq -e '
  .status == "accepted"
  and .batch_id == "history-batch-77"
  and .correlation_id == "reqd-history-77"
  and .record_status == "duplicate"
' <<<"${targeted_replay}" >/dev/null; then
  echo "targeted replay could not directly reconstruct a cold acceptance" >&2
  exit 1
fi

RECEIVED_RECOVERY_ROOT="${TEST_ROOT}/received-recovery-state"
STATE_ROOT="${RECEIVED_RECOVERY_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
received_recovery_archive_key="$(printf '%s' received-recovery-batch | sha256_text)"
jq -cn --arg callback_nonce "${CALLBACK_NONCE}" '{
  version:1,
  requests:[{
    batch_id:"received-recovery-batch",
    correlation_id:"reqd-received-recovery",
    project:"group/project",
    selector:{type:"single",iid:1},
    force_rerun_pr:false,
    target_branch:null,
    executor_agent:"req_executor",
    callback_nonce:$callback_nonce,
    origin:null,
    payload:("RUN_DRIVEN_ISSUE_BATCH\nbatch_id=received-recovery-batch"
      + "\nexecutor_agent=req_executor\ncallback_nonce=" + $callback_nonce),
    request_digest:("a" * 64),
    status:"received",
    attempts:1,
    last_attempt_at:"2026-07-11T00:00:00Z",
    last_error:null,
    matched_count:1,
    snapshot_digest:("b" * 64),
    scheduler_status:"completed",
    created_at:"2026-07-11T00:00:00Z",
    updated_at:"2026-07-11T00:00:00Z",
    received_at:"2026-07-11T00:00:00Z",
    accepted_at:null
  }]
}' >"${RECEIVED_RECOVERY_ROOT}/_dispatcher/executor_batch_outbox.json"
jq -cn '{
  version:1,
  batch_id:"received-recovery-batch",
  correlation_id:"reqd-received-recovery",
  callback_auth_mode:"nonce_v1",
  matched_count:1,
  snapshot_digest:("b" * 64),
  scheduler_status:"completed",
  accepted_at:"2026-07-11T00:00:01Z"
}' >"${RECEIVED_RECOVERY_ROOT}/_dispatcher/accepted_intents/${received_recovery_archive_key}.json"

received_recovery_result="$(
  STATE_ROOT="${RECEIVED_RECOVERY_ROOT}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
if ! jq -e '.status == "idle" and .queued_count == 0' \
    <<<"${received_recovery_result}" >/dev/null \
  || ! jq -e '.requests | length == 0' \
    "${RECEIVED_RECOVERY_ROOT}/_dispatcher/executor_batch_outbox.json" >/dev/null; then
  echo "matching cold acceptance did not clear a crash-window received row before continuing" >&2
  exit 1
fi

RECEIVED_CONFLICT_ROOT="${TEST_ROOT}/received-conflict-state"
STATE_ROOT="${RECEIVED_CONFLICT_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
received_conflict_archive_key="$(printf '%s' received-conflict-batch | sha256_text)"
jq -cn --arg callback_nonce "${CALLBACK_NONCE}" '{
  version:1,
  requests:[{
    batch_id:"received-conflict-batch",
    correlation_id:"reqd-hot-received-copy",
    project:"group/project",
    selector:{type:"single",iid:1},
    force_rerun_pr:false,
    target_branch:null,
    executor_agent:"req_executor",
    callback_nonce:$callback_nonce,
    origin:null,
    payload:("RUN_DRIVEN_ISSUE_BATCH\nbatch_id=received-conflict-batch"
      + "\nexecutor_agent=req_executor\ncallback_nonce=" + $callback_nonce),
    request_digest:("a" * 64),
    status:"received",
    attempts:1,
    last_attempt_at:"2026-07-11T00:00:00Z",
    last_error:null,
    matched_count:1,
    snapshot_digest:("b" * 64),
    scheduler_status:"completed",
    created_at:"2026-07-11T00:00:00Z",
    updated_at:"2026-07-11T00:00:00Z",
    received_at:"2026-07-11T00:00:00Z",
    accepted_at:null
  }]
}' >"${RECEIVED_CONFLICT_ROOT}/_dispatcher/executor_batch_outbox.json"
jq -cn '{
  version:1,
  batch_id:"received-conflict-batch",
  correlation_id:"reqd-conflicting-cold-copy",
  callback_auth_mode:"nonce_v1",
  matched_count:1,
  snapshot_digest:("b" * 64),
  scheduler_status:"completed",
  accepted_at:"2026-07-11T00:00:01Z"
}' >"${RECEIVED_CONFLICT_ROOT}/_dispatcher/accepted_intents/${received_conflict_archive_key}.json"

set +e
STATE_ROOT="${RECEIVED_CONFLICT_ROOT}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh" >/dev/null 2>&1
received_conflict_rc=$?
set -e
if [ "${received_conflict_rc}" -eq 0 ] \
  || ! jq -e '(.requests | length) == 1 and .requests[0].status == "received"' \
    "${RECEIVED_CONFLICT_ROOT}/_dispatcher/executor_batch_outbox.json" >/dev/null; then
  echo "conflicting cold acceptance did not preserve the crash-window received row" >&2
  exit 1
fi

IDENTITY_ROOT="${TEST_ROOT}/identity-state"
STATE_ROOT="${IDENTITY_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
identity_archive_key="$(printf '%s' expected-batch | sha256_text)"
jq -cn '{
  version:1,
  batch_id:"different-batch",
  correlation_id:"reqd-wrong-identity",
  callback_auth_mode:"nonce_v1",
  matched_count:1,
  snapshot_digest:("b" * 64),
  scheduler_status:"completed",
  accepted_at:"2026-07-11T00:00:00Z"
}' >"${IDENTITY_ROOT}/_dispatcher/accepted_intents/${identity_archive_key}.json"
set +e
STATE_ROOT="${IDENTITY_ROOT}" BATCH_ID=expected-batch \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh" >/dev/null 2>&1
identity_rc=$?
set -e
if [ "${identity_rc}" -eq 0 ]; then
  echo "SHA-256 addressed acceptance archive did not verify its internal batch identity" >&2
  exit 1
fi

CONFLICT_ROOT="${TEST_ROOT}/conflict-state"
STATE_ROOT="${CONFLICT_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
mkdir -p "${CONFLICT_ROOT}/_dispatcher/accepted_intents"
conflict_archive_key="$(printf '%s' conflict-batch | sha256_text)"
jq -cn --arg callback_nonce "${CALLBACK_NONCE}" '{
  version:1,
  requests:[{
    batch_id:"conflict-batch",
    correlation_id:"reqd-hot-copy",
    project:"group/project",
    selector:{type:"single",iid:1},
    force_rerun_pr:false,
    target_branch:null,
    executor_agent:"req_executor",
    callback_nonce:$callback_nonce,
    origin:null,
    payload:("RUN_DRIVEN_ISSUE_BATCH\nbatch_id=conflict-batch"
      + "\nexecutor_agent=req_executor\ncallback_nonce=" + $callback_nonce),
    request_digest:("a" * 64),
    status:"accepted",
    attempts:1,
    last_attempt_at:"2026-07-11T00:00:00Z",
    last_error:null,
    matched_count:1,
    snapshot_digest:("b" * 64),
    scheduler_status:"completed",
    created_at:"2026-07-11T00:00:00Z",
    updated_at:"2026-07-11T00:00:00Z",
    received_at:"2026-07-11T00:00:00Z",
    accepted_at:"2026-07-11T00:00:00Z"
  }]
}' >"${CONFLICT_ROOT}/_dispatcher/executor_batch_outbox.json"
jq -cn '{
  version:1,
  batch_id:"conflict-batch",
  correlation_id:"reqd-different-cold-copy",
  callback_auth_mode:"nonce_v1",
  matched_count:1,
  snapshot_digest:("b" * 64),
  scheduler_status:"completed",
  accepted_at:"2026-07-11T00:00:00Z"
}' >"${CONFLICT_ROOT}/_dispatcher/accepted_intents/${conflict_archive_key}.json"

set +e
STATE_ROOT="${CONFLICT_ROOT}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh" >/dev/null 2>&1
conflict_rc=$?
set -e
if [ "${conflict_rc}" -eq 0 ] \
  || ! jq -e '(.requests | length) == 1 and .requests[0].batch_id == "conflict-batch"' \
    "${CONFLICT_ROOT}/_dispatcher/executor_batch_outbox.json" >/dev/null; then
  echo "conflicting cold acceptance did not fail closed before hot deletion" >&2
  exit 1
fi

jq -cn '
  {
    notifications:[range(0;128) as $i | {
      event_id:("history-event-" + ($i | tostring)),
      origin:null,
      project:"group/project",
      iid:($i + 1),
      status:"done",
      mr_url:null,
      reason:null,
      attempts:1,
      delivered_at:"2026-07-11T00:00:00Z",
      next_attempt_at:null
    }]
  }
' >"${STATE_ROOT_PATH}/_dispatcher/executor_batch_notifications.json"

STATE_ROOT="${STATE_ROOT_PATH}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh" >/dev/null
if ! jq -e '.notifications | length == 0' \
  "${STATE_ROOT_PATH}/_dispatcher/executor_batch_notifications.json" >/dev/null \
  || [ "$(find "${STATE_ROOT_PATH}/_dispatcher/delivered_notifications" -type f -name '*.json' | wc -l | tr -d ' ')" -ne 128 ]; then
  echo "delivered notification history remained in the hot queue" >&2
  exit 1
fi

if ! find "${STATE_ROOT_PATH}/_dispatcher/delivered_notifications" \
    -type f -name '*.json' -exec jq -e '
      (keys | sort) == [
        "attempts","delivered_at","event_id","iid","mr_url","origin",
        "project","reason","status","version"
      ]
      and .version == 1
      and .delivered_at != null
    ' {} + >/dev/null; then
  echo "cold notification archive was not compact or valid" >&2
  exit 1
fi

prepare_delivered_replay_state() {
  local replay_root="$1"
  local cold_project="$2"
  local event_id="cold-replay-batch:snapshot-0:terminal-1"
  local archive_key

  STATE_ROOT="${replay_root}" "${BASH}" -c '
    source "$1"
    ensure_state_dirs
  ' _ "${SKILL_DIR}/scripts/env_paths.sh"
  archive_key="$(printf '%s' "${event_id}" | sha256_text)"
  jq -cn '{
    batches:{
      "cold-replay-batch":{
        batch_id:"cold-replay-batch",
        project:"group/project",
        executor_agent:"req_executor",
        callback_auth_mode:"legacy_pre_upgrade",
        callback_nonce_sha256:null,
        origin:null,
        matched_count:1,
        terminal_count:1,
        status:"completed",
        request_digest:"cold-replay-request",
        created_at:"2026-07-11T00:00:00Z",
        updated_at:"2026-07-11T00:00:01Z"
      }
    }
  }' >"${replay_root}/_dispatcher/executor_batches.json"
  jq -cn '{
    event_id:"cold-replay-batch:snapshot-0:terminal-1",
    batch_id:"cold-replay-batch",
    snapshot_index:0,
    project:"group/project",
    iid:42,
    status:"done",
    mr_url:"https://gitlab.example/group/project/-/merge_requests/42",
    reason:null,
    received_at:"2026-07-11T00:00:01Z"
  }' >"${replay_root}/_dispatcher/executor_batch_events.jsonl"
  jq -cn \
    --arg event_id "${event_id}" \
    --arg project "${cold_project}" '{
      version:1,
      event_id:$event_id,
      origin:null,
      project:$project,
      iid:42,
      status:"done",
      mr_url:"https://gitlab.example/group/project/-/merge_requests/42",
      reason:null,
      attempts:1,
      delivered_at:"2026-07-11T00:00:02Z"
    }' >"${replay_root}/_dispatcher/delivered_notifications/${archive_key}.json"
}

COLD_REPLAY_EVENT='{
  "event_id":"cold-replay-batch:snapshot-0:terminal-1",
  "batch_id":"cold-replay-batch",
  "snapshot_index":0,
  "project":"group/project",
  "iid":42,
  "status":"done",
  "mr_url":"https://gitlab.example/group/project/-/merge_requests/42",
  "reason":null
}'

DELIVERED_REPLAY_ROOT="${TEST_ROOT}/delivered-replay-state"
prepare_delivered_replay_state "${DELIVERED_REPLAY_ROOT}" "group/project"
delivered_replay_result="$(
  STATE_ROOT="${DELIVERED_REPLAY_ROOT}" \
  WORKER_RESULT_JSON="${COLD_REPLAY_EVENT}" \
    "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${delivered_replay_result}" >/dev/null \
  || ! jq -e '.notifications | length == 0' \
    "${DELIVERED_REPLAY_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "duplicate I3 rebuilt a notification already present in the delivered cold archive" >&2
  exit 1
fi

DELIVERED_CONFLICT_ROOT="${TEST_ROOT}/delivered-conflict-state"
prepare_delivered_replay_state "${DELIVERED_CONFLICT_ROOT}" "other/project"
set +e
STATE_ROOT="${DELIVERED_CONFLICT_ROOT}" \
WORKER_RESULT_JSON="${COLD_REPLAY_EVENT}" \
  "${BASH}" "${SKILL_DIR}/scripts/apply_executor_batch_event.sh" >/dev/null 2>&1
delivered_conflict_rc=$?
set -e
if [ "${delivered_conflict_rc}" -eq 0 ] \
  || ! jq -e '.notifications | length == 0' \
    "${DELIVERED_CONFLICT_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "conflicting delivered cold archive did not fail closed before notification projection" >&2
  exit 1
fi

write_zero_match_archive() {
  local state_root="$1"
  local batch_id="$2"
  local project="$3"
  local event_id="${batch_id}:no-matches"
  local archive_key

  archive_key="$(printf '%s' "${event_id}" | sha256_text)"
  jq -cn \
    --arg event_id "${event_id}" \
    --arg project "${project}" '{
      version:1,
      event_id:$event_id,
      origin:null,
      project:$project,
      iid:null,
      status:"no_matches",
      mr_url:null,
      reason:"无匹配 OPEN Issue",
      attempts:1,
      delivered_at:"2026-07-11T00:00:02Z"
    }' >"${state_root}/_dispatcher/delivered_notifications/${archive_key}.json"
}

ZERO_REPLAY_ROOT="${TEST_ROOT}/zero-replay-state"
STATE_ROOT="${ZERO_REPLAY_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
write_zero_match_archive "${ZERO_REPLAY_ROOT}" zero-replay-batch group/project
zero_replay_result="$(
  STATE_ROOT="${ZERO_REPLAY_ROOT}" \
  BATCH_ID=zero-replay-batch \
  PROJECT=group/project \
  ORIGIN_JSON=null \
    "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_empty_notification.sh"
)"
if ! jq -e '.status == "duplicate"' <<<"${zero_replay_result}" >/dev/null \
  || ! jq -e '.notifications | length == 0' \
    "${ZERO_REPLAY_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "zero-match replay rebuilt a notification already present in delivered cold state" >&2
  exit 1
fi

ZERO_CONFLICT_ROOT="${TEST_ROOT}/zero-conflict-state"
STATE_ROOT="${ZERO_CONFLICT_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
write_zero_match_archive "${ZERO_CONFLICT_ROOT}" zero-conflict-batch other/project
set +e
STATE_ROOT="${ZERO_CONFLICT_ROOT}" \
BATCH_ID=zero-conflict-batch \
PROJECT=group/project \
ORIGIN_JSON=null \
  "${BASH}" "${SKILL_DIR}/scripts/enqueue_executor_batch_empty_notification.sh" \
  >/dev/null 2>&1
zero_conflict_rc=$?
set -e
if [ "${zero_conflict_rc}" -eq 0 ] \
  || ! jq -e '.notifications | length == 0' \
    "${ZERO_CONFLICT_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "conflicting zero-match delivered archive did not fail closed" >&2
  exit 1
fi

ZERO_ACCEPTED_ROOT="${TEST_ROOT}/zero-accepted-residual-state"
STATE_ROOT="${ZERO_ACCEPTED_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
write_zero_match_archive "${ZERO_ACCEPTED_ROOT}" zero-accepted-residual group/project
jq -cn --arg callback_nonce "${CALLBACK_NONCE}" '{
  version:1,
  requests:[{
    batch_id:"zero-accepted-residual",
    correlation_id:"reqd-zero-accepted-residual",
    project:"group/project",
    selector:{type:"single",iid:42},
    force_rerun_pr:false,
    target_branch:null,
    executor_agent:"req_executor",
    callback_nonce:$callback_nonce,
    origin:null,
    payload:("RUN_DRIVEN_ISSUE_BATCH\nbatch_id=zero-accepted-residual"
      + "\nexecutor_agent=req_executor\ncallback_nonce=" + $callback_nonce),
    request_digest:("a" * 64),
    status:"received",
    attempts:1,
    last_attempt_at:"2026-07-11T00:00:00Z",
    last_error:null,
    matched_count:0,
    snapshot_digest:("b" * 64),
    scheduler_status:"completed",
    created_at:"2026-07-11T00:00:00Z",
    updated_at:"2026-07-11T00:00:01Z",
    received_at:"2026-07-11T00:00:01Z",
    accepted_at:null
  }]
}' >"${ZERO_ACCEPTED_ROOT}/_dispatcher/executor_batch_outbox.json"
zero_accepted_result="$(
  STATE_ROOT="${ZERO_ACCEPTED_ROOT}" \
    "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_outbox.sh"
)"
if ! jq -e '.status == "accepted" and .matched_count == 0' \
    <<<"${zero_accepted_result}" >/dev/null \
  || ! jq -e '.notifications | length == 0' \
    "${ZERO_ACCEPTED_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null; then
  echo "accepted zero-match crash recovery rebuilt a delivered notification" >&2
  exit 1
fi

ZERO_BRIDGE_ROOT="${TEST_ROOT}/zero-bridge-residual-state"
STATE_ROOT="${ZERO_BRIDGE_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
write_zero_match_archive "${ZERO_BRIDGE_ROOT}" zero-bridge-residual group/project
jq -cn '{
  batches:{
    "zero-bridge-residual":{
      batch_id:"zero-bridge-residual",
      project:"group/project",
      executor_agent:"req_executor",
      callback_auth_mode:"legacy_pre_upgrade",
      callback_nonce_sha256:null,
      origin:null,
      matched_count:0,
      terminal_count:0,
      status:"completed",
      request_digest:"zero-bridge-request",
      created_at:"2026-07-11T00:00:00Z",
      updated_at:"2026-07-11T00:00:01Z"
    }
  }
}' >"${ZERO_BRIDGE_ROOT}/_dispatcher/executor_batches.json"
jq -cn '{
  next_id:2,
  active:{
    queue_id:"execq-1",
    correlation_id:"reqd-zero-bridge",
    run_id:"executor-execq-1",
    project:"group/project",
    iid:42,
    executor_agent:"req_executor",
    origin:null,
    driven_batch_id:"zero-bridge-residual",
    driven_request_digest:"zero-bridge-request",
    driven_executor_agent:"req_executor",
    driven_project:"group/project",
    driven_callback_auth_mode:"legacy_pre_upgrade",
    driven_callback_nonce_sha256:null,
    driven_matched_count:0,
    driven_snapshot_digest:"legacy-snapshot",
    driven_scheduler_status:"completed"
  },
  queue:[]
}' >"${ZERO_BRIDGE_ROOT}/_dispatcher/executor_queue.json"
jq -cn '{
  pending:{
    "executor-execq-1":{
      run_id:"executor-execq-1",
      stage:"executor",
      project:"group/project",
      iid:42,
      correlation_id:"reqd-zero-bridge",
      callback_auth_mode:"legacy_pre_upgrade",
      callback_nonce_sha256:null
    }
  }
}' >"${ZERO_BRIDGE_ROOT}/_dispatcher/pending.json"
zero_bridge_result="$(
  STATE_ROOT="${ZERO_BRIDGE_ROOT}" \
    "${BASH}" "${SKILL_DIR}/scripts/recover_legacy_executor_batch_bridge.sh"
)"
if ! jq -e '.status == "cleared"' <<<"${zero_bridge_result}" >/dev/null \
  || ! jq -e '.notifications | length == 0' \
    "${ZERO_BRIDGE_ROOT}/_dispatcher/executor_batch_notifications.json" >/dev/null \
  || ! jq -e '.active == null' \
    "${ZERO_BRIDGE_ROOT}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "legacy zero-match bridge recovery rebuilt a delivered notification" >&2
  exit 1
fi

COMPACTION_RACE_ROOT="${TEST_ROOT}/notification-compaction-race"
STATE_ROOT="${COMPACTION_RACE_ROOT}" "${BASH}" -c '
  source "$1"
  ensure_state_dirs
' _ "${SKILL_DIR}/scripts/env_paths.sh"
RACE_EVENT_ID='notification-race-batch:snapshot-0:terminal-1'
jq -cn --arg event_id "${RACE_EVENT_ID}" '{
  notifications:[{
    event_id:$event_id,
    origin:null,
    project:"group/project",
    iid:1,
    status:"done",
    mr_url:null,
    reason:null,
    attempts:0,
    delivered_at:null,
    next_attempt_at:null
  }]
}' >"${COMPACTION_RACE_ROOT}/_dispatcher/executor_batch_notifications.json"

RACE_READY="${TEST_ROOT}/notification-race.ready"
RACE_RELEASE="${TEST_ROOT}/notification-race.release"
RACE_KEY_HELPER="${TEST_ROOT}/notification-race-key-helper.sh"
RACE_NOTIFY="${TEST_ROOT}/notification-race-notify.sh"
RACE_FIRST_OUT="${TEST_ROOT}/notification-race-first.out"
RACE_FIRST_ERR="${TEST_ROOT}/notification-race-first.err"
RACE_EVENT_KEY="$(printf '%s' "${RACE_EVENT_ID}" | sha256_text)"

cat >"${RACE_KEY_HELPER}" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
: >"${RACE_READY:?}"
while [ ! -e "${RACE_RELEASE:?}" ]; do
  sleep 0.05
done
printf '%s\n' "${RACE_EVENT_KEY:?}"
HELPER
chmod +x "${RACE_KEY_HELPER}"
cat >"${RACE_NOTIFY}" <<'NOTIFY'
#!/usr/bin/env bash
set -euo pipefail
exit 0
NOTIFY
chmod +x "${RACE_NOTIFY}"

STATE_ROOT="${COMPACTION_RACE_ROOT}" \
NOTIFY_USER_SCRIPT="${RACE_NOTIFY}" \
EXECUTOR_BATCH_NOTIFICATION_KEY_HELPER="${RACE_KEY_HELPER}" \
RACE_READY="${RACE_READY}" \
RACE_RELEASE="${RACE_RELEASE}" \
RACE_EVENT_KEY="${RACE_EVENT_KEY}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh" \
  >"${RACE_FIRST_OUT}" 2>"${RACE_FIRST_ERR}" &
race_first_pid=$!
for _ in $(seq 1 200); do
  [ -e "${RACE_READY}" ] && break
  sleep 0.05
done
[ -e "${RACE_READY}" ] || {
  echo "notification race helper did not reach the pre-lock barrier" >&2
  exit 1
}

STATE_ROOT="${COMPACTION_RACE_ROOT}" \
NOTIFY_USER_SCRIPT="${RACE_NOTIFY}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh" >/dev/null
STATE_ROOT="${COMPACTION_RACE_ROOT}" \
NOTIFY_USER_SCRIPT="${RACE_NOTIFY}" \
  "${BASH}" "${SKILL_DIR}/scripts/drain_executor_batch_notifications.sh" >/dev/null
: >"${RACE_RELEASE}"
set +e
wait "${race_first_pid}"
race_first_rc=$?
set -e
if [ "${race_first_rc}" -ne 0 ] \
  || ! jq -e '.status == "drained" and .attempted == 0 and .failed == 0' \
    "${RACE_FIRST_OUT}" >/dev/null; then
  echo "a stale pending notification snapshot did not accept an identical cold delivery" >&2
  sed -n '1,120p' "${RACE_FIRST_ERR}" >&2
  exit 1
fi

echo "ok accepted intents and delivered notifications leave hot state"
