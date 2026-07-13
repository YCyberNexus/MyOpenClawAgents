#!/usr/bin/env bash
# Append one GitLab issue to req_dispatcher's durable executor FIFO queue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
# shellcheck source=_executor_batch_outbox_lib.sh
source "${SCRIPT_DIR}/_executor_batch_outbox_lib.sh"
ensure_state_dirs

# Never reuse or propagate a caller-provided nonce; every new intent gets fresh
# entropy and only the lowercase local variable is persisted.
unset CALLBACK_NONCE

: "${PROJECT:?PROJECT required}"
: "${IID:?IID required}"
: "${EXECUTOR_AGENT:?EXECUTOR_AGENT required}"

ISSUE_URL="${ISSUE_URL:-}"
ORIGIN_JSON="${ORIGIN_JSON:-}"
REQ_DIGEST="${REQ_DIGEST:-}"
TARGET_BRANCH="${TARGET_BRANCH:-}"

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ] || return 1
  return 0
}

case "${PROJECT}" in
  */*) ;;
  *) echo "PROJECT must be group/project (got: ${PROJECT})" >&2; exit 1 ;;
esac
[[ "${IID}" =~ ^[1-9][0-9]*$ ]] || { echo "IID must be a positive integer (got: ${IID})" >&2; exit 1; }
[ -n "${EXECUTOR_AGENT}" ] || { echo "EXECUTOR_AGENT must not be empty" >&2; exit 1; }
if [ -n "${TARGET_BRANCH}" ] && ! validate_branch_name "${TARGET_BRANCH}"; then
  echo "branch must be a safe Git ref name, got: ${TARGET_BRANCH}" >&2
  exit 1
fi
if [ -n "${ORIGIN_JSON}" ]; then
  printf '%s' "${ORIGIN_JSON}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "ORIGIN_JSON must be a JSON object when set" >&2; exit 1; }
fi

QUEUED_AT="$(date -u +%s)"
[[ "${QUEUED_AT}" =~ ^[0-9]+$ ]] || { echo "date -u +%s produced non-integer: ${QUEUED_AT}" >&2; exit 1; }
callback_nonce="$(generate_executor_callback_nonce)"

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
  --arg callback_nonce "${callback_nonce}" \
  --arg target_branch "${TARGET_BRANCH}" \
  --argjson origin "${ORIGIN_JSON:-null}" \
  --arg req_digest "${REQ_DIGEST}" \
  --argjson queued_at "${QUEUED_AT}" '
  .next_id = ((.next_id // 1) + 1)
  | .active = (.active // null)
  | .queue = ((.queue // []) + [{
      queue_id: $queue_id,
      project: $project,
      iid: ($iid | tonumber),
      issue_url: ($issue_url | select(. != "") // null),
      executor_agent: $executor_agent,
      callback_nonce: $callback_nonce,
      target_branch: ($target_branch | select(. != "") // null),
      origin: $origin,
      req_digest: $req_digest,
      queued_at: $queued_at
    }])
  ' "${EXECUTOR_QUEUE_FILE}" > "${tmp}"
mv "${tmp}" "${EXECUTOR_QUEUE_FILE}"

queued_count="$(jq -r '.queue | length' "${EXECUTOR_QUEUE_FILE}")"
flock -u 9

jq -nc \
  --arg status "queued" \
  --arg queue_id "${queue_id}" \
  --argjson queued_count "${queued_count}" \
  '{status:$status, queue_id:$queue_id, queued_count:$queued_count}'
