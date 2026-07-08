#!/usr/bin/env bash
# Fill available executor active slots by launching eligible queue items.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

LAUNCH_RECLAIM_SECONDS="${EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS:-11100}"
LAUNCH_RETRY_BACKOFF_SECONDS="${EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS:-60}"
SPAWN_MAX_ATTEMPTS="${EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS:-3}"
SPAWN_RETRY_SLEEP_SECONDS="${EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS:-2}"
MAX_ACTIVE="${EXECUTOR_QUEUE_MAX_ACTIVE:-1}"
MAX_ACTIVE_PER_ORIGIN="${EXECUTOR_QUEUE_MAX_ACTIVE_PER_ORIGIN:-0}"
DRAIN_BATCH_LIMIT="${EXECUTOR_QUEUE_DRAIN_BATCH_LIMIT:-${MAX_ACTIVE}}"
case "${LAUNCH_RECLAIM_SECONDS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS must be a non-negative integer" >&2; exit 1 ;; esac
case "${LAUNCH_RETRY_BACKOFF_SECONDS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS must be a non-negative integer" >&2; exit 1 ;; esac
case "${SPAWN_MAX_ATTEMPTS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS must be a positive integer" >&2; exit 1 ;; esac
case "${SPAWN_RETRY_SLEEP_SECONDS}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS must be a non-negative integer" >&2; exit 1 ;; esac
case "${MAX_ACTIVE}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_MAX_ACTIVE must be a positive integer" >&2; exit 1 ;; esac
case "${MAX_ACTIVE_PER_ORIGIN}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_MAX_ACTIVE_PER_ORIGIN must be a non-negative integer" >&2; exit 1 ;; esac
case "${DRAIN_BATCH_LIMIT}" in *[!0-9]*|"") echo "EXECUTOR_QUEUE_DRAIN_BATCH_LIMIT must be a positive integer" >&2; exit 1 ;; esac
[ "${SPAWN_MAX_ATTEMPTS}" -ge 1 ] || { echo "EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS must be >= 1" >&2; exit 1; }
[ "${MAX_ACTIVE}" -ge 1 ] || { echo "EXECUTOR_QUEUE_MAX_ACTIVE must be >= 1" >&2; exit 1; }
[ "${DRAIN_BATCH_LIMIT}" -ge 1 ] || { echo "EXECUTOR_QUEUE_DRAIN_BATCH_LIMIT must be >= 1" >&2; exit 1; }

if [ "${EXECUTOR_QUEUE_DRAIN_SINGLE:-0}" != "1" ]; then
  results="[]"
  iterations=0
  while [ "${iterations}" -lt "${DRAIN_BATCH_LIMIT}" ]; do
    one="$(
      EXECUTOR_QUEUE_DRAIN_SINGLE="1" \
      bash "${SCRIPT_DIR}/drain_executor_queue.sh"
    )"
    results="$(jq -nc --argjson results "${results}" --argjson one "${one}" '$results + [$one]')"
    iterations=$((iterations + 1))

    status="$(jq -r '.status // ""' <<<"${one}")"
    claim_kind="$(jq -r '.claim_kind // ""' <<<"${one}")"
    active_count="$(jq -r '.active_count // 0' <<<"${one}")"
    queued_count="$(jq -r '.queued_count // 0' <<<"${one}")"
    max_active="$(jq -r --argjson fallback "${MAX_ACTIVE}" '.max_active // $fallback' <<<"${one}")"

    case "${status}" in
      launched|launch_failed|active_changed_after_launch) ;;
      *) break ;;
    esac
    if [ "${queued_count}" -gt 0 ] && [ "${active_count}" -lt "${max_active}" ]; then
      continue
    fi
    [ "${claim_kind}" = "retry" ] || break
  done

  result_count="$(jq -r 'length' <<<"${results}")"
  if [ "${result_count}" = "1" ]; then
    jq -c '.[0]' <<<"${results}"
  else
    jq -nc --argjson results "${results}" '
      ($results[($results | length) - 1]) as $last
      | {
          status: "drained",
          first_status: ($results[0].status // null),
          last_status: ($last.status // null),
          active_count: ($last.active_count // 0),
          queued_count: ($last.queued_count // 0),
          max_active: ($last.max_active // null),
          launched_count: ([$results[] | select(.status == "launched")] | length),
          launch_failed_count: ([$results[] | select(.status == "launch_failed")] | length),
          active_changed_count: ([$results[] | select(.status == "active_changed_after_launch")] | length),
          results: $results
        }'
  fi
  exit 0
fi

NOW="$(date -u +%s)"
[[ "${NOW}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${NOW}" >&2; exit 1; }

# This may be unused when no queue item is claimed. Wasting a correlation id is
# harmless and avoids holding the queue lock while calling another flocked script.
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

normalize_queue_locked() {
  local tmp_queue
  tmp_queue="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
  jq '
    def active_array:
      if (.active | type) == "array" then .active
      elif .active == null then []
      else [.active]
      end;
    .next_id = (.next_id // 1)
    | .active = active_array
    | .queue = (.queue // [])
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp_queue}"
  mv "${tmp_queue}" "${EXECUTOR_QUEUE_FILE}"
}

find_eligible_queue_index() {
  local state_json="$1"
  jq -r \
    --argjson cap "${MAX_ACTIVE_PER_ORIGIN}" '
    def origin_key($item):
      ($item.origin // null) as $origin
      | if ($origin | type) != "object" then ""
        else
          ($origin.reply_agent // $origin.source_agent // "unknown") as $agent
          | ($origin.user // $origin.conversation // $origin.source_session // "") as $who
          | if $who == "" then "" else ($agent + ":" + $who) end
        end;
    if $cap == 0 then
      0
    else
      (
        reduce .active[] as $active ({}; (origin_key($active)) as $key
          | if $key == "" then . else .[$key] = ((.[$key] // 0) + 1) end)
      ) as $active_by_origin
      | [
          .queue
          | to_entries[]
          | (origin_key(.value)) as $key
          | select($key == "" or (($active_by_origin[$key] // 0) < $cap))
          | .key
        ][0] // empty
    end
  ' <<<"${state_json}"
}

claim_or_status() {
  exec 9>"${LOCK_FILE}"
  flock 9
  normalize_queue_locked

  state="$(jq -c '.' "${EXECUTOR_QUEUE_FILE}")" || { echo "jq read failed on ${EXECUTOR_QUEUE_FILE} (corrupt?)" >&2; exit 1; }
  active_count="$(jq -r '.active | length' <<<"${state}")"
  queued_count="$(jq -r '.queue | length' <<<"${state}")"
  eligible_index=""

  retry_index="$(jq -r \
    --argjson now "${NOW}" \
    --argjson reclaim_seconds "${LAUNCH_RECLAIM_SECONDS}" '
    [
      .active
      | to_entries[]
      | select(
          ((.value.launch_state // "launched") == "launching"
            and ($now - ((.value.launch_started_at // 0) | tonumber)) >= $reclaim_seconds)
          or
          ((.value.launch_state // "launched") == "launch_failed"
            and $now >= ((.value.next_retry_after // 0) | tonumber))
        )
      | .key
    ][0] // empty
  ' <<<"${state}")"

  if [ "${active_count}" -lt "${MAX_ACTIVE}" ] && [ "${queued_count}" != "0" ]; then
    eligible_index="$(find_eligible_queue_index "${state}")"
    if [ -n "${eligible_index}" ] && [ "${eligible_index}" != "null" ]; then
      retry_index=""
    fi
  fi

  if [ -n "${retry_index}" ]; then
    tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
    jq \
      --argjson idx "${retry_index}" \
      --argjson now "${NOW}" '
      .active[$idx] = (.active[$idx] + {
        launch_state: "launching",
        launch_attempts: ((.active[$idx].launch_attempts // 0) + 1),
        launch_started_at: $now,
        next_retry_after: null,
        launch_error: null
      })
    ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
    mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
    active="$(jq -c --argjson idx "${retry_index}" '.active[$idx]' "${EXECUTOR_QUEUE_FILE}")"
    write_executor_pending_locked "${active}" "${NOW}"
    active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
    queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
    flock -u 9
    jq -nc \
      --argjson active "${active}" \
      --argjson active_count "${active_count}" \
      --argjson queued_count "${queued_count}" \
      --argjson max_active "${MAX_ACTIVE}" \
      '{status:"claimed", claim_kind:"retry", active:$active, active_count:$active_count,
        queued_count:$queued_count, max_active:$max_active}'
    return 0
  fi

  if [ "${active_count}" -ge "${MAX_ACTIVE}" ]; then
    flock -u 9
    jq -nc \
      --argjson active "$(jq -c '.active' <<<"${state}")" \
      --argjson active_count "${active_count}" \
      --argjson queued_count "${queued_count}" \
      --argjson max_active "${MAX_ACTIVE}" \
      '{status:"busy", reason:"active_slots_full", active:$active,
        active_count:$active_count, queued_count:$queued_count, max_active:$max_active}'
    return 0
  fi

  if [ "${queued_count}" = "0" ]; then
    flock -u 9
    jq -nc \
      --argjson active_count "${active_count}" \
      --argjson queued_count "${queued_count}" \
      --argjson max_active "${MAX_ACTIVE}" \
      '{status:"idle", active_count:$active_count, queued_count:$queued_count, max_active:$max_active}'
    return 0
  fi

  if [ -z "${eligible_index}" ]; then
    eligible_index="$(find_eligible_queue_index "${state}")"
  fi

  if [ -z "${eligible_index}" ] || [ "${eligible_index}" = "null" ]; then
    flock -u 9
    jq -nc \
      --argjson active "$(jq -c '.active' <<<"${state}")" \
      --argjson active_count "${active_count}" \
      --argjson queued_count "${queued_count}" \
      --argjson max_active "${MAX_ACTIVE}" \
      --argjson per_origin "${MAX_ACTIVE_PER_ORIGIN}" \
      '{status:"busy", reason:"origin_active_limit", active:$active,
        active_count:$active_count, queued_count:$queued_count,
        max_active:$max_active, max_active_per_origin:$per_origin}'
    return 0
  fi

  tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
  jq \
    --argjson idx "${eligible_index}" \
    --arg cid "${NEW_CORRELATION_ID}" \
    --argjson now "${NOW}" '
    (.queue[$idx]) as $item
    | .queue = (.queue[:$idx] + .queue[($idx + 1):])
    | .active = (.active + [($item + {
        correlation_id: $cid,
        run_id: ("executor-" + $item.queue_id),
        launch_state: "launching",
        launch_attempts: 1,
        launch_started_at: $now,
        launched_at: null,
        next_retry_after: null,
        launch_error: null
      })])
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
  mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
  active="$(jq -c --arg cid "${NEW_CORRELATION_ID}" '.active[] | select(.correlation_id == $cid)' "${EXECUTOR_QUEUE_FILE}")"
  write_executor_pending_locked "${active}" "${NOW}"
  active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
  queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
  flock -u 9
  jq -nc \
    --argjson active "${active}" \
    --argjson active_count "${active_count}" \
    --argjson queued_count "${queued_count}" \
    --argjson max_active "${MAX_ACTIVE}" \
    '{status:"claimed", claim_kind:"queued", active:$active, active_count:$active_count,
      queued_count:$queued_count, max_active:$max_active}'
}

claim="$(claim_or_status)"
claim_status="$(jq -r '.status' <<<"${claim}")"
if [ "${claim_status}" != "claimed" ]; then
  printf '%s\n' "${claim}"
  exit 0
fi

active="$(jq -c '.active' <<<"${claim}")"
claim_kind="$(jq -r '.claim_kind // ""' <<<"${claim}")"
queue_id="$(jq -r '.queue_id' <<<"${active}")"
project="$(jq -r '.project' <<<"${active}")"
iid="$(jq -r '.iid' <<<"${active}")"
executor_agent="$(jq -r '.executor_agent' <<<"${active}")"
correlation_id="$(jq -r '.correlation_id' <<<"${active}")"
run_id="$(jq -r '.run_id' <<<"${active}")"
origin_json="$(jq -c 'if .origin == null then empty else .origin end' <<<"${active}" || true)"

payload="$(
  PROJECT="${project}" \
  IID="${iid}" \
  CORRELATION_ID="${correlation_id}" \
  DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}" \
  bash "${SCRIPT_DIR}/build_executor_payload.sh"
)"

attempt=1
run_rc=1
envelope=""
envelope_status="failed"
accepted_executor="false"
last_error_text=""
while [ "${attempt}" -le "${SPAWN_MAX_ATTEMPTS}" ]; do
  set +e
  envelope="$(
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
  if [ "${run_rc}" -eq 0 ]; then
    envelope_status="$(jq -r '.status // "failed"' <<<"${envelope}" 2>/dev/null || printf 'failed')"
    if [ "${envelope_status}" = "success" ]; then
      worker_status="$(jq -r '.worker_result_json.status // ""' <<<"${envelope}" 2>/dev/null || true)"
      if [ "${worker_status}" = "waiting_for_callbacks" ]; then
        accepted_executor="true"
      elif [ -z "${worker_status}" ] &&
           jq -r '.raw_output // ""' <<<"${envelope}" 2>/dev/null | grep -q 'waiting_for_callbacks'; then
        accepted_executor="true"
      else
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
  child_session_key="$(jq -r '.child_session_key // ""' <<<"${envelope}")"
  launched_at="$(date -u +%s)"
  exec 9>"${LOCK_FILE}"
  flock 9
  normalize_queue_locked
  active_matches="$(jq -r --arg queue_id "${queue_id}" --arg cid "${correlation_id}" \
    'if any(.active[]; .queue_id == $queue_id and .correlation_id == $cid) then "yes" else "no" end' \
    "${EXECUTOR_QUEUE_FILE}")"
  pending_present="$(jq -r --arg rid "${run_id}" 'if .pending[$rid] then "yes" else "no" end' "${PENDING_FILE}")"
  queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
  active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"

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
      .active = [
        .active[]
        | if .queue_id == $queue_id and .correlation_id == $cid
          then . + {
            launch_state: "launched",
            child_session_key: ($csk | select(. != "") // null),
            launched_at: $launched_at,
            next_retry_after: null,
            launch_error: null
          }
          else .
          end
      ]
    ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
    mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
    active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
    queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
    flock -u 9

    jq -nc \
      --arg status "launched" \
      --arg queue_id "${queue_id}" \
      --arg project "${project}" \
      --argjson iid "${iid}" \
      --arg run_id "${run_id}" \
      --arg correlation_id "${correlation_id}" \
      --arg claim_kind "${claim_kind}" \
      --argjson active_count "${active_count}" \
      --argjson queued_count "${queued_count}" \
      --argjson max_active "${MAX_ACTIVE}" \
      '{status:$status, queue_id:$queue_id, project:$project, iid:$iid,
        run_id:$run_id, correlation_id:$correlation_id,
        claim_kind:($claim_kind|select(.!="")//null),
        active_count:$active_count, queued_count:$queued_count, max_active:$max_active}'
    exit 0
  fi

  current_active="$(jq -c '.active' "${EXECUTOR_QUEUE_FILE}")"
  flock -u 9
  jq -nc \
    --arg status "active_changed_after_launch" \
    --arg queue_id "${queue_id}" \
    --arg project "${project}" \
    --argjson iid "${iid}" \
    --arg run_id "${run_id}" \
    --arg correlation_id "${correlation_id}" \
    --arg claim_kind "${claim_kind}" \
    --arg active_matches "${active_matches}" \
    --arg pending_present "${pending_present}" \
    --argjson active "${current_active}" \
    --argjson active_count "${active_count}" \
    --argjson queued_count "${queued_count}" \
    --argjson max_active "${MAX_ACTIVE}" \
    '{status:$status, queue_id:$queue_id, project:$project, iid:$iid,
      run_id:$run_id, correlation_id:$correlation_id,
      claim_kind:($claim_kind|select(.!="")//null),
      active_matches:$active_matches, pending_present:$pending_present,
      active:$active, active_count:$active_count,
      queued_count:$queued_count, max_active:$max_active}'
  exit 0
fi

error_text="${last_error_text:-${envelope}}"
failed_at="$(date -u +%s)"
next_retry_after=$((failed_at + LAUNCH_RETRY_BACKOFF_SECONDS))

exec 9>"${LOCK_FILE}"
flock 9
normalize_queue_locked
tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq \
  --arg queue_id "${queue_id}" \
  --arg cid "${correlation_id}" \
  --arg err "${error_text}" \
  --argjson next_retry_after "${next_retry_after}" '
  .active = [
    .active[]
    | if .queue_id == $queue_id and .correlation_id == $cid
      then . + {
        launch_state: "launch_failed",
        launch_error: $err,
        next_retry_after: $next_retry_after
      }
      else .
      end
  ]
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"
tmp_pending="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
jq --arg rid "${run_id}" 'del(.pending[$rid])' "${PENDING_FILE}" > "${tmp_pending}"
mv "${tmp_pending}" "${PENDING_FILE}"
active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "launch_failed" \
  --arg queue_id "${queue_id}" \
  --arg project "${project}" \
  --argjson iid "${iid}" \
  --arg run_id "${run_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg claim_kind "${claim_kind}" \
  --argjson attempts "${SPAWN_MAX_ATTEMPTS}" \
  --argjson active_count "${active_count}" \
  --argjson queued_count "${queued_count}" \
  --argjson max_active "${MAX_ACTIVE}" \
  '{status:$status, queue_id:$queue_id, project:$project, iid:$iid,
    run_id:$run_id, correlation_id:$correlation_id,
    claim_kind:($claim_kind|select(.!="")//null),
    launch_attempts_this_drain:$attempts, active_count:$active_count,
    queued_count:$queued_count, max_active:$max_active}'
