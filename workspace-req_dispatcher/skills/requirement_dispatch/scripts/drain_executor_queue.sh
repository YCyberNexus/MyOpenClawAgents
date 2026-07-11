#!/usr/bin/env bash
# Launch at most one queued executor issue, or recover a stale launch attempt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

# The legacy single-Issue bridge cannot complete without a durable callback
# route. Reject a broken deployment pin before initializing state, consuming a
# correlation sequence, claiming queue work, writing pending, or calling out.
[ -n "${DISPATCHER_CALLBACK_TARGET:-}" ] \
  || { echo "drain_executor_queue.sh: DISPATCHER_CALLBACK_TARGET must not be empty" >&2; exit 2; }

ensure_state_dirs

LAUNCH_RECLAIM_SECONDS="${EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS:-11100}"
LAUNCH_RETRY_BACKOFF_SECONDS="${EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS:-60}"
SPAWN_MAX_ATTEMPTS="${EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS:-3}"
SPAWN_RETRY_SLEEP_SECONDS="${EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS:-2}"
case "${LAUNCH_RECLAIM_SECONDS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS must be a non-negative integer" >&2; exit 1 ;; esac
case "${LAUNCH_RETRY_BACKOFF_SECONDS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS must be a non-negative integer" >&2; exit 1 ;; esac
case "${SPAWN_MAX_ATTEMPTS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS must be a positive integer" >&2; exit 1 ;; esac
case "${SPAWN_RETRY_SLEEP_SECONDS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS must be a non-negative integer" >&2; exit 1 ;; esac
[ "${SPAWN_MAX_ATTEMPTS}" -ge 1 ] || { echo "EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS must be >= 1" >&2; exit 1; }

NOW="$(date -u +%s)"
[[ "${NOW}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${NOW}" >&2; exit 1; }

# This may be unused when there is already active work. Wasting a correlation id
# is harmless and avoids holding the queue lock while calling another flocked script.
NEW_CORRELATION_ID="$(STATE_ROOT="${STATE_ROOT}" bash "${SCRIPT_DIR}/next_correlation_id.sh")"

write_executor_pending_locked() {
  local active_json="$1"
  local spawned_at="$2"
  local tmp_pending

  tmp_pending="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
  jq \
    --argjson active "${active_json}" \
    --argjson ts "${spawned_at}" '
    .pending[$active.run_id] = {
      run_id: $active.run_id,
      stage: "executor",
      origin: ($active.origin // null),
      project: ($active.project // null),
      iid: ($active.iid // null),
      correlation_id: ($active.correlation_id // null),
      child_session_key: ($active.child_session_key // null),
      spawned_at: $ts,
      req_digest: ($active.req_digest // "")
    }
    ' "${PENDING_FILE}" > "${tmp_pending}"
  mv "${tmp_pending}" "${PENDING_FILE}"
}

claim_or_status() {
  exec 9>"${LOCK_FILE}"
  flock 9

  state="$(jq -c '.' "${EXECUTOR_QUEUE_FILE}")" || { echo "jq read failed on ${EXECUTOR_QUEUE_FILE} (corrupt?)" >&2; exit 1; }
  active_type="$(jq -r '.active | type' <<<"${state}")"
  queued_count="$(jq -r '.queue | length' <<<"${state}")"

  if [ "${active_type}" = "null" ]; then
    if [ "${queued_count}" = "0" ]; then
      flock -u 9
      jq -nc '{status:"idle", queued_count:0}'
      return 0
    fi

    tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
    jq \
      --arg cid "${NEW_CORRELATION_ID}" \
      --argjson now "${NOW}" '
      (.queue[0]) as $item
      | .queue = (.queue[1:] // [])
      | .active = ($item + {
          correlation_id: $cid,
          run_id: ("executor-" + $item.queue_id),
          launch_state: "launching",
          launch_attempts: 1,
          launch_started_at: $now,
          launched_at: null,
          next_retry_after: null,
          launch_error: null
        })
      ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
    mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
    active="$(jq -c '.active' "${EXECUTOR_QUEUE_FILE}")"
    write_executor_pending_locked "${active}" "${NOW}"
    remaining="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
    flock -u 9
    jq -nc --argjson active "${active}" --argjson queued_count "${remaining}" \
      '{status:"claimed", active:$active, queued_count:$queued_count}'
    return 0
  fi

  active="$(jq -c '.active' <<<"${state}")"
  launch_state="$(jq -r '.launch_state // "launched"' <<<"${active}")"
  launch_started_at="$(jq -r '.launch_started_at // 0' <<<"${active}")"
  next_retry_after="$(jq -r '.next_retry_after // 0' <<<"${active}")"

  if [ "${launch_state}" = "launched" ]; then
    flock -u 9
    jq -nc --argjson active "${active}" --argjson queued_count "${queued_count}" \
      '{status:"busy", reason:"active_executor_pending", active:$active, queued_count:$queued_count}'
    return 0
  fi

  if [ "${launch_state}" = "launching" ] && [ $((NOW - launch_started_at)) -lt "${LAUNCH_RECLAIM_SECONDS}" ]; then
    flock -u 9
    jq -nc --argjson active "${active}" --argjson queued_count "${queued_count}" \
      '{status:"busy", reason:"launch_in_progress", active:$active, queued_count:$queued_count}'
    return 0
  fi

  if [ "${launch_state}" = "launch_failed" ] && [ "${NOW}" -lt "${next_retry_after}" ]; then
    flock -u 9
    jq -nc --argjson active "${active}" --argjson queued_count "${queued_count}" \
      '{status:"waiting_retry", active:$active, queued_count:$queued_count}'
    return 0
  fi

  tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
  jq --argjson now "${NOW}" '
    .active = (.active + {
      launch_state: "launching",
      launch_attempts: ((.active.launch_attempts // 0) + 1),
      launch_started_at: $now,
      next_retry_after: null,
      launch_error: null
    })
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
  mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
  active="$(jq -c '.active' "${EXECUTOR_QUEUE_FILE}")"
  write_executor_pending_locked "${active}" "${NOW}"
  queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
  flock -u 9
  jq -nc --argjson active "${active}" --argjson queued_count "${queued_count}" \
    '{status:"claimed", active:$active, queued_count:$queued_count}'
}

claim="$(claim_or_status)"
claim_status="$(jq -r '.status' <<<"${claim}")"
if [ "${claim_status}" != "claimed" ]; then
  printf '%s\n' "${claim}"
  exit 0
fi

active="$(jq -c '.active' <<<"${claim}")"
queue_id="$(jq -r '.queue_id' <<<"${active}")"
project="$(jq -r '.project' <<<"${active}")"
iid="$(jq -r '.iid' <<<"${active}")"
executor_agent="$(jq -r '.executor_agent' <<<"${active}")"
correlation_id="$(jq -r '.correlation_id' <<<"${active}")"
run_id="$(jq -r '.run_id' <<<"${active}")"
req_digest="$(jq -r '.req_digest // ""' <<<"${active}")"
target_branch="$(jq -r '.target_branch // ""' <<<"${active}")"
origin_json="$(jq -c 'if .origin == null then empty else .origin end' <<<"${active}" || true)"

payload="$(
  PROJECT="${project}" \
  IID="${iid}" \
  CORRELATION_ID="${correlation_id}" \
  DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}" \
  TARGET_BRANCH="${target_branch}" \
  bash "${SCRIPT_DIR}/build_executor_payload.sh"
)"
sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "drain_executor_queue.sh: no SHA-256 command is available" >&2
    return 2
  fi
}

attempt=1
run_rc=1
envelope=""
envelope_status="failed"
accepted_executor="false"
driven_acceptance_json=null
last_error_text=""
while [ "${attempt}" -le "${SPAWN_MAX_ATTEMPTS}" ]; do
  set +e
  envelope="$(
    env \
    -u GITLAB_TOKEN \
    -u GLAB_TOKEN \
    -u GITLAB_PRIVATE_TOKEN \
    -u PRIVATE_TOKEN \
    -u WIKI_GITLAB_TOKEN \
    OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}" \
    TARGET_AGENT="${executor_agent}" \
    RUN_ID="${run_id}" \
    DEFAULT_EXECUTOR_AGENT="${executor_agent}" \
    DOWNSTREAM_AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
    EXECUTOR_AGENT_TIMEOUT_SECONDS="${EXECUTOR_AGENT_TIMEOUT_SECONDS:-${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}}" \
    AGENT_TIMEOUT_SECONDS="${EXECUTOR_AGENT_TIMEOUT_SECONDS:-${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}}" \
    bash "${SCRIPT_DIR}/run_agent_turn.sh" <<<"${payload}"
  )"
  run_rc=$?
  set -e

  envelope_status="failed"
  worker_status=""
  accepted_executor="false"
  driven_acceptance_json=null
  if [ "${run_rc}" -eq 0 ]; then
    envelope_status="$(jq -r '.status // "failed"' <<<"${envelope}" 2>/dev/null || printf 'failed')"
    if [ "${envelope_status}" = "success" ]; then
      worker_status="$(jq -r '.worker_result_json.status // ""' <<<"${envelope}" 2>/dev/null || true)"
      if [ "${worker_status}" = "waiting_for_callbacks" ]; then
        accepted_executor="true"
      elif driven_acceptance_json="$(jq -ce '
        if type == "object"
          and (keys | sort) == [
            "batch_id","matched_count","scheduler_status","snapshot_digest","status"
          ]
          and .status == "success"
          and (.batch_id | type == "string"
            and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
          and (.matched_count == 0 or .matched_count == 1)
          and (.snapshot_digest | type == "string" and length > 0)
          and (.scheduler_status == "queued" or .scheduler_status == "running"
            or .scheduler_status == "completed")
          and (if .matched_count == 0 then .scheduler_status == "completed" else true end)
        then . else error("invalid single shim acceptance") end
      ' <<<"$(jq -c '.worker_result_json // null' <<<"${envelope}" 2>/dev/null)" 2>/dev/null)"; then
        accepted_executor="true"
      elif [ -z "${worker_status}" ] &&
           jq -r '.raw_output // ""' <<<"${envelope}" 2>/dev/null | grep -q 'waiting_for_callbacks'; then
        driven_acceptance_json=null
        accepted_executor="true"
      else
        driven_acceptance_json=null
        worker_status_label="${worker_status:-null}"
        last_error_text="executor did not accept RUN_SINGLE_ISSUE for callback wait: worker_result_json.status=${worker_status_label}; envelope=${envelope}"
      fi
    else
      last_error_text="${envelope}"
    fi
  else
    last_error_text="run_agent_turn exited ${run_rc}: ${envelope}"
  fi
  [ "${accepted_executor}" = "true" ] && break
  if [ "${attempt}" -lt "${SPAWN_MAX_ATTEMPTS}" ] && [ "${SPAWN_RETRY_SLEEP_SECONDS}" -gt 0 ]; then
    sleep "${SPAWN_RETRY_SLEEP_SECONDS}"
  fi
  attempt=$((attempt + 1))
done

if [ "${accepted_executor}" = "true" ]; then
  if [ "${driven_acceptance_json}" != null ]; then
    driven_batch_id="$(jq -r '.batch_id' <<<"${driven_acceptance_json}")"
    driven_matched_count="$(jq -r '.matched_count' <<<"${driven_acceptance_json}")"
    driven_snapshot_digest="$(jq -r '.snapshot_digest' <<<"${driven_acceptance_json}")"
    driven_scheduler_status="$(jq -r '.scheduler_status' <<<"${driven_acceptance_json}")"
    driven_request_digest="$(printf '%s' "${payload}" | sha256_text)"
    STATE_ROOT="${STATE_ROOT}" \
    QUEUE_ID="${queue_id}" \
    CORRELATION_ID="${correlation_id}" \
    BATCH_ID="${driven_batch_id}" \
    EXECUTOR_AGENT="${executor_agent}" \
    MATCHED_COUNT="${driven_matched_count}" \
    SNAPSHOT_DIGEST="${driven_snapshot_digest}" \
    SCHEDULER_STATUS="${driven_scheduler_status}" \
    REQUEST_DIGEST="${driven_request_digest}" \
      "${BASH}" "${SCRIPT_DIR}/record_legacy_executor_batch_receipt.sh" >/dev/null

    bridge_recovery="$(
      STATE_ROOT="${STATE_ROOT}" \
        "${BASH}" "${SCRIPT_DIR}/recover_legacy_executor_batch_bridge.sh"
    )"
    if [ "${driven_matched_count}" -eq 0 ]; then
      if [ "$(jq -r '.status' <<<"${bridge_recovery}")" != cleared ]; then
        echo "drain_executor_queue.sh: zero-match legacy bridge did not clear" >&2
        exit 3
      fi
      "${BASH}" "${SCRIPT_DIR}/drain_executor_batch_notifications.sh" >/dev/null || true
      queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
      jq -nc \
        --arg status "completed_zero_match" \
        --arg queue_id "${queue_id}" \
        --arg project "${project}" \
        --argjson iid "${iid}" \
        --arg run_id "${run_id}" \
        --arg correlation_id "${correlation_id}" \
        --arg batch_id "${driven_batch_id}" \
        --argjson queued_count "${queued_count}" '{
          status:$status,queue_id:$queue_id,project:$project,iid:$iid,
          run_id:$run_id,correlation_id:$correlation_id,batch_id:$batch_id,
          queued_count:$queued_count
        }'
      exit 0
    fi
  fi

  child_session_key="$(jq -r '.child_session_key // ""' <<<"${envelope}")"
  launched_at="$(date -u +%s)"
  exec 9>"${LOCK_FILE}"
  flock 9
  active_matches="$(jq -r --arg queue_id "${queue_id}" --arg cid "${correlation_id}" \
    'if .active != null and .active.queue_id == $queue_id and .active.correlation_id == $cid then "yes" else "no" end' \
    "${EXECUTOR_QUEUE_FILE}")"
  pending_present="$(jq -r --arg rid "${run_id}" 'if .pending[$rid] then "yes" else "no" end' "${PENDING_FILE}")"
  queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"

  if [ "${active_matches}" = "yes" ] && [ "${pending_present}" = "yes" ]; then
    tmp_pending="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
    jq --arg rid "${run_id}" --arg csk "${child_session_key}" '
      .pending[$rid].child_session_key = ($csk | select(. != "") // null)
    ' "${PENDING_FILE}" > "${tmp_pending}"
    mv "${tmp_pending}" "${PENDING_FILE}"

    tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
    jq \
      --arg queue_id "${queue_id}" \
      --arg cid "${correlation_id}" \
      --arg csk "${child_session_key}" \
      --argjson launched_at "${launched_at}" '
      if .active != null
         and .active.queue_id == $queue_id
         and .active.correlation_id == $cid
      then
        .active = (.active + {
          launch_state: "launched",
          child_session_key: ($csk | select(. != "") // null),
          launched_at: $launched_at,
          next_retry_after: null,
          launch_error: null
        })
      else . end
      ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
    mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
    flock -u 9

    jq -nc \
      --arg status "launched" \
      --arg queue_id "${queue_id}" \
      --arg project "${project}" \
      --arg target_branch "${target_branch}" \
      --argjson iid "${iid}" \
      --arg run_id "${run_id}" \
      --arg correlation_id "${correlation_id}" \
      --argjson queued_count "${queued_count}" \
      '{status:$status, queue_id:$queue_id, project:$project, iid:$iid,
        target_branch:($target_branch | select(. != "") // null),
        run_id:$run_id, correlation_id:$correlation_id, queued_count:$queued_count}'
    exit 0
  fi

  current_active="$(jq -c '.active // null' "${EXECUTOR_QUEUE_FILE}")"
  flock -u 9
  jq -nc \
    --arg status "active_changed_after_launch" \
    --arg queue_id "${queue_id}" \
    --arg project "${project}" \
    --argjson iid "${iid}" \
    --arg run_id "${run_id}" \
    --arg correlation_id "${correlation_id}" \
    --arg active_matches "${active_matches}" \
    --arg pending_present "${pending_present}" \
    --argjson active "${current_active}" \
    --argjson queued_count "${queued_count}" \
    '{status:$status, queue_id:$queue_id, project:$project, iid:$iid,
      run_id:$run_id, correlation_id:$correlation_id,
      active_matches:$active_matches, pending_present:$pending_present,
      active:$active, queued_count:$queued_count}'
  exit 0
fi

error_text="${last_error_text:-${envelope}}"
failed_at="$(date -u +%s)"
next_retry_after=$((failed_at + LAUNCH_RETRY_BACKOFF_SECONDS))

exec 9>"${LOCK_FILE}"
flock 9
tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq \
  --arg queue_id "${queue_id}" \
  --arg cid "${correlation_id}" \
  --arg err "${error_text}" \
  --argjson next_retry_after "${next_retry_after}" '
  if .active != null
     and .active.queue_id == $queue_id
     and .active.correlation_id == $cid
  then
    .active = (.active + {
      launch_state: "launch_failed",
      launch_error: $err,
      next_retry_after: $next_retry_after
    })
  else . end
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
tmp_pending="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
jq --arg rid "${run_id}" 'del(.pending[$rid])' "${PENDING_FILE}" > "${tmp_pending}"
mv "${tmp_pending}" "${PENDING_FILE}"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "launch_failed" \
  --arg queue_id "${queue_id}" \
  --arg project "${project}" \
  --argjson iid "${iid}" \
  --arg run_id "${run_id}" \
  --arg correlation_id "${correlation_id}" \
  --argjson attempts "${SPAWN_MAX_ATTEMPTS}" \
  --argjson queued_count "${queued_count}" \
  '{status:$status, queue_id:$queue_id, project:$project, iid:$iid,
    run_id:$run_id, correlation_id:$correlation_id,
    launch_attempts_this_drain:$attempts, queued_count:$queued_count}'
