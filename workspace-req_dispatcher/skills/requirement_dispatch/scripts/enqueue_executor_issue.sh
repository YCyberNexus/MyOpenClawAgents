#!/usr/bin/env bash
# Append one GitLab issue to req_dispatcher's durable executor FIFO queue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${PROJECT:?PROJECT required}"
: "${IID:?IID required}"
: "${EXECUTOR_AGENT:?EXECUTOR_AGENT required}"

ISSUE_URL="${ISSUE_URL:-}"
ORIGIN_JSON="${ORIGIN_JSON:-}"
REQ_DIGEST="${REQ_DIGEST:-}"

case "${PROJECT}" in
  */*) ;;
  *) echo "PROJECT must be group/project (got: ${PROJECT})" >&2; exit 1 ;;
esac
[[ "${IID}" =~ ^[1-9][0-9]*$ ]] || { echo "IID must be a positive integer (got: ${IID})" >&2; exit 1; }
[ -n "${EXECUTOR_AGENT}" ] || { echo "EXECUTOR_AGENT must not be empty" >&2; exit 1; }
if [ -n "${ORIGIN_JSON}" ]; then
  printf '%s' "${ORIGIN_JSON}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "ORIGIN_JSON must be a JSON object when set" >&2; exit 1; }
fi

QUEUED_AT="$(date -u +%s)"
[[ "${QUEUED_AT}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${QUEUED_AT}" >&2; exit 1; }

exec 9>"${LOCK_FILE}"
flock 9

queue_id="$(
  jq -r '"execq-" + ((.next_id // 1) | tostring)' "${EXECUTOR_QUEUE_FILE}"
)" || { echo "jq read failed on ${EXECUTOR_QUEUE_FILE} (corrupt?)" >&2; exit 1; }

tmp="$(mktemp "${DISPATCHER_DIR}/executor_queue.XXXXXX")"
jq \
  --arg queue_id "${queue_id}" \
  --arg project "${PROJECT}" \
  --arg iid "${IID}" \
  --arg issue_url "${ISSUE_URL}" \
  --arg executor_agent "${EXECUTOR_AGENT}" \
  --argjson origin "${ORIGIN_JSON:-null}" \
  --arg req_digest "${REQ_DIGEST}" \
  --argjson queued_at "${QUEUED_AT}" '
  def active_array:
    if (.active | type) == "array" then .active
    elif .active == null then []
    else [.active]
    end;
  .next_id = ((.next_id // 1) + 1)
  | .active = active_array
  | .queue = ((.queue // []) + [{
      queue_id: $queue_id,
      project: $project,
      iid: ($iid | tonumber),
      issue_url: ($issue_url | select(. != "") // null),
      executor_agent: $executor_agent,
      origin: $origin,
      req_digest: $req_digest,
      queued_at: $queued_at
    }])
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"

queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
active_count="$(jq -r '.active | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "queued" \
  --arg queue_id "${queue_id}" \
  --argjson queued_count "${queued_count}" \
  --argjson active_count "${active_count}" \
  '{status:$status, queue_id:$queue_id, queued_count:$queued_count, active_count:$active_count}'
