#!/usr/bin/env bash
# Route a repository-wide mission stop to its executor, then remove the
# dispatcher-side durable chain so the same project can be submitted again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTE_CMD="${ROUTE_CMD:-${SCRIPT_DIR}/route_project.sh}"
RUN_AGENT_TURN_CMD="${RUN_AGENT_TURN_CMD:-${SCRIPT_DIR}/run_agent_turn.sh}"

mission_stop_failure() {
  jq -cn --arg reason "$1" '{status:"failed",reason:$reason}'
  exit 0
}

url_decode_path() {
  local value="$1" rest="$1" hex=""
  while [[ "${rest}" == *%* ]]; do
    rest="${rest#*%}"
    [ "${#rest}" -ge 2 ] || return 1
    hex="${rest:0:2}"
    case "${hex}" in [0-9A-Fa-f][0-9A-Fa-f]) ;; *) return 1 ;; esac
    [ "${hex}" != 00 ] || return 1
    rest="${rest:2}"
  done
  printf '%b' "${value//%/\\x}"
}

normalize_project() {
  local target="$1" prefix path decoded segment expected_host expected_protocol
  local -a segments=()
  target="${target%%\#*}"
  target="${target%%\?*}"
  while [ "${target}" != "${target%/}" ]; do target="${target%/}"; done
  case "${target}" in
    http://*|https://*)
      expected_host="${GITLAB_HOST:-${WIKI_GITLAB_HOST:-}}"
      expected_protocol="${GITLAB_API_PROTOCOL:-${WIKI_GITLAB_API_PROTOCOL:-}}"
      [ -n "${expected_host}" ] && [ -n "${expected_protocol}" ] || return 1
      case "${expected_protocol}" in http|https) ;; *) return 1 ;; esac
      prefix="${expected_protocol}://${expected_host}/"
      [[ "${target}" == "${prefix}"* ]] || return 1
      path="${target#${prefix}}"
      ;;
    *) path="${target}" ;;
  esac
  path="${path%%/-/*}"
  path="${path%.git}"
  decoded="$(url_decode_path "${path}")" || return 1
  case "${decoded}" in ""|/*|*/|*//*|*[[:space:]]*) return 1 ;; esac
  [[ "${decoded}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || return 1
  IFS='/' read -r -a segments <<<"${decoded}"
  for segment in "${segments[@]}"; do
    case "${segment}" in .|..) return 1 ;; esac
  done
  printf '%s\n' "${decoded}"
}

validate_mission_stop_result() {
  local project="$1" expected_stop_id="$2" allow_legacy_id="${3:-false}"
  case "${allow_legacy_id}" in true|false) ;; *) return 1 ;; esac
  jq -ceS --arg project "${project}" --arg expected_stop_id "${expected_stop_id}" \
    --argjson allow_legacy_id "${allow_legacy_id}" '
    if (keys | sort) == [
        "cleanup_requested_count","project","status","stop_id",
        "stopped_batch_ids","stopped_issue_iids","stopped_job_count"
      ]
      and .status == "success" and .project == $project
      and (.stop_id | type == "string")
      and (.stop_id == $expected_stop_id
        or ($allow_legacy_id
          and (.stop_id | test("^mission-stop-[0-9]+-[0-9a-f]{16}$"))))
      and (.stopped_batch_ids | type == "array" and all(.[]; type == "string"))
      and (.stopped_issue_iids | type == "array"
        and all(.[]; type == "number" and . == floor and . > 0))
      and (.stopped_job_count | type == "number" and . == floor and . >= 0)
      and (.cleanup_requested_count | type == "number" and . == floor and . >= 0)
    then . else error("invalid executor result") end
  '
}

atomic_publish_json() {
  local target="$1" value="$2" candidate
  candidate="$(mktemp "${DISPATCHER_DIR}/.mission-stop.XXXXXX")"
  printf '%s\n' "${value}" >"${candidate}"
  jq -e . "${candidate}" >/dev/null || mission_stop_failure "refusing to publish invalid dispatcher state"
  mv "${candidate}" "${target}"
}

if [ "$#" -ne 0 ]; then
  mission_stop_failure "usage: /mission-stop <gitlab-repository-url|group/project>"
fi
COMMAND_TEXT="${MESSAGE:-}"
[ -n "${COMMAND_TEXT}" ] || COMMAND_TEXT="$(cat)"
if [[ ! "${COMMAND_TEXT}" =~ ^/mission-stop[[:blank:]]+([^[:blank:]]+)[[:blank:]]*$ ]]; then
  mission_stop_failure "usage: /mission-stop <gitlab-repository-url|group/project>"
fi
TARGET_TEXT="${BASH_REMATCH[1]}"

# shellcheck source=source_dispatcher_env.sh
source "${SCRIPT_DIR}/source_dispatcher_env.sh" \
  || mission_stop_failure "dispatcher configuration is invalid"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

PROJECT_FULL="$(normalize_project "${TARGET_TEXT}")" \
  || mission_stop_failure "target must be a repository on the configured GitLab host or <group>/<project>"
EXECUTOR_AGENT="$(PROJECT="${PROJECT_FULL}" bash "${ROUTE_CMD}")" \
  || mission_stop_failure "repository routing failed"
if [ "${EXECUTOR_AGENT}" = "__NO_ROUTE__" ] || [ -z "${EXECUTOR_AGENT}" ]; then
  mission_stop_failure "repository has no executor route"
fi
[[ "${EXECUTOR_AGENT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || mission_stop_failure "repository route returned an invalid executor agent"

RECEIPT_NONCE="$(generate_executor_callback_nonce)" \
  || mission_stop_failure "could not generate a mission stop receipt nonce"
RECEIPT_DIGEST="$(executor_callback_nonce_sha256 "${RECEIPT_NONCE}")" \
  || mission_stop_failure "could not derive the mission stop receipt identity"
EXPECTED_STOP_ID="mission-stop-receipt-${RECEIPT_DIGEST}"
case "${EXECUTOR_SCHEDULER_STATE_FILE:-}" in
  /*) ;;
  *) mission_stop_failure "executor scheduler state path is invalid" ;;
esac
case "${EXECUTOR_SCHEDULER_STATE_FILE}" in
  *'/../'*|*'/./'*|*/..|*/.)
    mission_stop_failure "executor scheduler state path is unsafe"
    ;;
esac
[[ "${EXECUTOR_SCHEDULER_STATE_FILE}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
  || mission_stop_failure "executor scheduler state path contains unsupported characters"
EXECUTOR_SCHEDULER_ROOT="${EXECUTOR_SCHEDULER_STATE_FILE%/*}"
[ -n "${EXECUTOR_SCHEDULER_ROOT}" ] && [ "${EXECUTOR_SCHEDULER_ROOT}" != / ] \
  || mission_stop_failure "executor scheduler root is unsafe"
EXPECTED_RESULT_FILE="${EXECUTOR_SCHEDULER_ROOT}/mission_stop_archive/${EXPECTED_STOP_ID}/result.json"

CANONICAL_COMMAND="/mission-stop ${PROJECT_FULL}?receipt_nonce=${RECEIPT_NONCE}"
TURN_RC=0
TURN_RESULT="$(TARGET_AGENT="${EXECUTOR_AGENT}" MESSAGE="${CANONICAL_COMMAND}" \
  bash "${RUN_AGENT_TURN_CMD}")" || TURN_RC=$?

DIRECT_RESULT=""
if [ "${TURN_RC}" -eq 0 ]; then
  DIRECT_RESULT="$(jq -ce '
    if type == "object" and .status == "success" and .exit_code == 0
      and (.worker_result_json | type == "object")
    then .worker_result_json else error("executor call failed") end
  ' <<<"${TURN_RESULT}" 2>/dev/null \
    | validate_mission_stop_result \
      "${PROJECT_FULL}" "${EXPECTED_STOP_ID}" true 2>/dev/null)" || DIRECT_RESULT=""
fi

DURABLE_RESULT=""
if [ -e "${EXPECTED_RESULT_FILE}" ] || [ -L "${EXPECTED_RESULT_FILE}" ]; then
  if [ -L "${EXPECTED_RESULT_FILE}" ] || [ ! -f "${EXPECTED_RESULT_FILE}" ] \
      || [ ! -r "${EXPECTED_RESULT_FILE}" ]; then
    mission_stop_failure "executor durable mission stop result is unsafe"
  fi
  DURABLE_RESULT="$(validate_mission_stop_result \
    "${PROJECT_FULL}" "${EXPECTED_STOP_ID}" false \
    <"${EXPECTED_RESULT_FILE}" 2>/dev/null)" \
    || mission_stop_failure "executor durable mission stop result is invalid"
fi

if [ -n "${DIRECT_RESULT}" ] && [ -n "${DURABLE_RESULT}" ] \
    && [ "${DIRECT_RESULT}" != "${DURABLE_RESULT}" ]; then
  mission_stop_failure "executor direct and durable mission stop results conflict"
fi
if [ -n "${DURABLE_RESULT}" ]; then
  WORKER_RESULT="${DURABLE_RESULT}"
elif [ -n "${DIRECT_RESULT}" ]; then
  WORKER_RESULT="${DIRECT_RESULT}"
elif [ "${TURN_RC}" -ne 0 ]; then
  mission_stop_failure "executor mission stop transport failed"
else
  mission_stop_failure "executor mission stop failed"
fi

STOP_ID="$(jq -r '.stop_id' <<<"${WORKER_RESULT}")"
STOPPED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exec {STOP_LOCK_FD}>"${LOCK_FILE}"
flock -x "${STOP_LOCK_FD}"

OUTBOX_JSON="$(load_executor_batch_outbox_locked)" \
  || mission_stop_failure "dispatcher batch outbox is invalid"
MIRROR_JSON="$(jq -ce 'if type == "object" and (.batches | type == "object") then . else error("invalid mirror") end' \
  "${EXECUTOR_BATCH_MIRROR_FILE}" 2>/dev/null)" \
  || mission_stop_failure "dispatcher batch mirror is invalid"
QUEUE_JSON="$(jq -ce 'if type == "object" and (.queue | type == "array") then . else error("invalid queue") end' \
  "${EXECUTOR_QUEUE_FILE}" 2>/dev/null)" \
  || mission_stop_failure "dispatcher executor queue is invalid"
PENDING_JSON="$(jq -ce 'if type == "object" and (.pending | type == "object") then . else error("invalid pending") end' \
  "${PENDING_FILE}" 2>/dev/null)" \
  || mission_stop_failure "dispatcher pending state is invalid"
NOTIFICATIONS_JSON="$(jq -ce 'if type == "object" and (.notifications | type == "array") then . else error("invalid notifications") end' \
  "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" 2>/dev/null)" \
  || mission_stop_failure "dispatcher notification state is invalid"

REMOVED_OUTBOX="$(jq -c --arg project "${PROJECT_FULL}" '[.requests[] | select(.project == $project)]' <<<"${OUTBOX_JSON}")"
REMOVED_QUEUE="$(jq -c --arg project "${PROJECT_FULL}" '[.active, .queue[] | select(. != null and .project == $project)]' <<<"${QUEUE_JSON}")"
REMOVED_PENDING="$(jq -c --arg project "${PROJECT_FULL}" '[.pending[] | select(.project == $project)]' <<<"${PENDING_JSON}")"
LOCAL_BATCH_IDS="$(jq -cn --arg project "${PROJECT_FULL}" \
  --argjson outbox "${REMOVED_OUTBOX}" --argjson mirror "${MIRROR_JSON}" '
  [$outbox[].batch_id]
  + [$mirror.batches | to_entries[]
      | select(.value.project == $project and .value.status != "completed" and .value.status != "failed")
      | .key]
  | unique | sort
')"
ALL_BATCH_IDS="$(jq -cn --argjson executor "$(jq -c '.stopped_batch_ids' <<<"${WORKER_RESULT}")" \
  --argjson local "${LOCAL_BATCH_IDS}" '$executor + $local | unique | sort')"
REMOVED_NOTIFICATIONS="$(jq -c --argjson batches "${ALL_BATCH_IDS}" '
  [.notifications[] | . as $notification
    | select(($batches | index($notification.batch_id)) != null)]
' <<<"${NOTIFICATIONS_JSON}")"

NEXT_OUTBOX="$(jq -c --arg project "${PROJECT_FULL}" '.requests |= map(select(.project != $project))' <<<"${OUTBOX_JSON}")"
NEXT_MIRROR="$(jq -c --arg project "${PROJECT_FULL}" --arg stopped_at "${STOPPED_AT}" '
  .batches |= with_entries(
    if .value.project == $project and .value.status != "completed" and .value.status != "failed"
    then .value.status = "failed" | .value.updated_at = $stopped_at
    else . end)
' <<<"${MIRROR_JSON}")"
NEXT_QUEUE="$(jq -c --arg project "${PROJECT_FULL}" '
  .active = (if .active != null and .active.project == $project then null else .active end)
  | .queue |= map(select(.project != $project))
' <<<"${QUEUE_JSON}")"
NEXT_PENDING="$(jq -c --arg project "${PROJECT_FULL}" '
  .pending |= with_entries(select(.value.project != $project))
' <<<"${PENDING_JSON}")"
NEXT_NOTIFICATIONS="$(jq -c --argjson batches "${ALL_BATCH_IDS}" '
  .notifications |= map(. as $notification
    | select(($batches | index($notification.batch_id)) == null))
' <<<"${NOTIFICATIONS_JSON}")"

ARCHIVE_DIR="${DISPATCHER_DIR}/mission_stop_archive"
mkdir -p "${ARCHIVE_DIR}"
chmod 700 "${ARCHIVE_DIR}"
ARCHIVE_JSON="$(jq -cn --arg project "${PROJECT_FULL}" --arg executor_agent "${EXECUTOR_AGENT}" \
  --arg stop_id "${STOP_ID}" --arg stopped_at "${STOPPED_AT}" \
  --argjson executor_result "${WORKER_RESULT}" --argjson removed_outbox "${REMOVED_OUTBOX}" \
  --argjson removed_queue "${REMOVED_QUEUE}" --argjson removed_pending "${REMOVED_PENDING}" '{
    version:1,project:$project,executor_agent:$executor_agent,stop_id:$stop_id,
    stopped_at:$stopped_at,executor_result:$executor_result,
    removed_outbox:$removed_outbox,removed_queue:$removed_queue,
    removed_pending:$removed_pending
  }')"
ARCHIVE_JSON="$(jq -c --argjson removed_notifications "${REMOVED_NOTIFICATIONS}" \
  '.removed_notifications = $removed_notifications' <<<"${ARCHIVE_JSON}")"
atomic_publish_json "${ARCHIVE_DIR}/${STOP_ID}.json" "${ARCHIVE_JSON}"
atomic_publish_json "${EXECUTOR_BATCH_OUTBOX_FILE}" "${NEXT_OUTBOX}"
atomic_publish_json "${EXECUTOR_BATCH_MIRROR_FILE}" "${NEXT_MIRROR}"
atomic_publish_json "${EXECUTOR_QUEUE_FILE}" "${NEXT_QUEUE}"
atomic_publish_json "${PENDING_FILE}" "${NEXT_PENDING}"
atomic_publish_json "${EXECUTOR_BATCH_NOTIFICATIONS_FILE}" "${NEXT_NOTIFICATIONS}"
printf '%s\n' "$(jq -cn --arg event "mission_stop" --arg project "${PROJECT_FULL}" \
  --arg stop_id "${STOP_ID}" --arg stopped_at "${STOPPED_AT}" \
  '{event:$event,project:$project,stop_id:$stop_id,recorded_at:$stopped_at}')" >>"${LEDGER_FILE}"
flock -u "${STOP_LOCK_FD}"
exec {STOP_LOCK_FD}>&-

jq -cnS --arg project "${PROJECT_FULL}" --arg executor_agent "${EXECUTOR_AGENT}" \
  --arg stop_id "${STOP_ID}" --argjson executor_result "${WORKER_RESULT}" \
  --argjson local_batches "${LOCAL_BATCH_IDS}" \
  --argjson cleared_outbox "$(jq -r 'length' <<<"${REMOVED_OUTBOX}")" \
  --argjson cleared_queue "$(jq -r 'length' <<<"${REMOVED_QUEUE}")" \
  --argjson cleared_pending "$(jq -r 'length' <<<"${REMOVED_PENDING}")" \
  --argjson cleared_notifications "$(jq -r 'length' <<<"${REMOVED_NOTIFICATIONS}")" '{
    status:"success",project:$project,executor_agent:$executor_agent,stop_id:$stop_id,
    stopped_batch_ids:($executor_result.stopped_batch_ids + $local_batches | unique | sort),
    stopped_job_count:$executor_result.stopped_job_count,
    stopped_issue_iids:$executor_result.stopped_issue_iids,
    cleanup_requested_count:$executor_result.cleanup_requested_count,
    cleared_dispatcher_request_count:$cleared_outbox,
    cleared_legacy_queue_count:$cleared_queue,
    cleared_pending_count:$cleared_pending,
    cleared_notification_count:$cleared_notifications
  }'
