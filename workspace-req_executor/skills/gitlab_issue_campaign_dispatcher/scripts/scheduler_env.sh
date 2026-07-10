#!/usr/bin/env bash
# Load and validate executor scheduler deployment settings, initialize the
# agent-wide state layout, export derived paths, and print compact config JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"

die() {
  echo "scheduler_env.sh: $1" >&2
  exit 2
}

ROOT_ENV_SET="${EXECUTOR_SCHEDULER_ROOT+x}"
ROOT_ENV_VALUE="${EXECUTOR_SCHEDULER_ROOT:-}"
CONCURRENCY_ENV_SET="${EXECUTOR_MAX_CONCURRENCY+x}"
CONCURRENCY_ENV_VALUE="${EXECUTOR_MAX_CONCURRENCY:-}"

DEFAULT_CONFIG="${CONFIG_DIR}/campaign_defaults.env"
LOCAL_CONFIG="${CONFIG_DIR}/campaign_defaults.local.env"
[ -f "${DEFAULT_CONFIG}" ] || die "missing deployment config: ${DEFAULT_CONFIG}"

EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler
EXECUTOR_MAX_CONCURRENCY=3
# shellcheck disable=SC1090
source "${DEFAULT_CONFIG}"
if [ -f "${LOCAL_CONFIG}" ]; then
  # shellcheck disable=SC1090
  source "${LOCAL_CONFIG}"
fi

if [ "${ROOT_ENV_SET}" = x ]; then
  EXECUTOR_SCHEDULER_ROOT="${ROOT_ENV_VALUE}"
fi
if [ "${CONCURRENCY_ENV_SET}" = x ]; then
  EXECUTOR_MAX_CONCURRENCY="${CONCURRENCY_ENV_VALUE}"
fi

case "${EXECUTOR_SCHEDULER_ROOT}" in
  /*) ;;
  *) die "EXECUTOR_SCHEDULER_ROOT must be an absolute path" ;;
esac

case "${EXECUTOR_MAX_CONCURRENCY}" in
  ''|*[!0-9]*) die "EXECUTOR_MAX_CONCURRENCY must be a positive integer" ;;
esac
if [[ "${EXECUTOR_MAX_CONCURRENCY}" =~ ^0+$ ]]; then
  die "EXECUTOR_MAX_CONCURRENCY must be a positive integer"
fi

SCHEDULER_STATE_FILE="${EXECUTOR_SCHEDULER_ROOT}/scheduler_state.json"
SCHEDULER_LOCK_FILE="${EXECUTOR_SCHEDULER_ROOT}/scheduler.lock"
BATCHES_ROOT="${EXECUTOR_SCHEDULER_ROOT}/batches"
CALLBACK_INBOX="${EXECUTOR_SCHEDULER_ROOT}/callback_inbox"
CALLBACK_OUTBOX="${EXECUTOR_SCHEDULER_ROOT}/callback_outbox"

export EXECUTOR_SCHEDULER_ROOT EXECUTOR_MAX_CONCURRENCY
export SCHEDULER_STATE_FILE SCHEDULER_LOCK_FILE BATCHES_ROOT CALLBACK_INBOX CALLBACK_OUTBOX

mkdir -p "${BATCHES_ROOT}" "${CALLBACK_INBOX}" "${CALLBACK_OUTBOX}"

exec {SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SCHEDULER_LOCK_FD}"
if [ ! -e "${SCHEDULER_STATE_FILE}" ]; then
  INITIAL_STATE='{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[]}'
  STATE_TMP="$(mktemp "${EXECUTOR_SCHEDULER_ROOT}/.scheduler_state.json.XXXXXX")"
  printf '%s' "${INITIAL_STATE}" >"${STATE_TMP}"
  mv "${STATE_TMP}" "${SCHEDULER_STATE_FILE}"
elif ! jq -e '
  type == "object"
  and .version == 1
  and ((.round_robin_cursor == null) or (.round_robin_cursor | type == "string"))
  and (.active_jobs | type == "object")
  and (.batch_order | type == "array")
' "${SCHEDULER_STATE_FILE}" >/dev/null; then
  die "existing scheduler state is invalid: ${SCHEDULER_STATE_FILE}"
fi
flock -u "${SCHEDULER_LOCK_FD}"
exec {SCHEDULER_LOCK_FD}>&-

jq -cn \
  --arg scheduler_root "${EXECUTOR_SCHEDULER_ROOT}" \
  --arg max_concurrency "${EXECUTOR_MAX_CONCURRENCY}" \
  --arg scheduler_state_file "${SCHEDULER_STATE_FILE}" \
  --arg scheduler_lock_file "${SCHEDULER_LOCK_FILE}" \
  --arg batches_root "${BATCHES_ROOT}" \
  --arg callback_inbox "${CALLBACK_INBOX}" \
  --arg callback_outbox "${CALLBACK_OUTBOX}" \
  '{
    scheduler_root: $scheduler_root,
    max_concurrency: ($max_concurrency | tonumber),
    scheduler_state_file: $scheduler_state_file,
    scheduler_lock_file: $scheduler_lock_file,
    batches_root: $batches_root,
    callback_inbox: $callback_inbox,
    callback_outbox: $callback_outbox
  }'
