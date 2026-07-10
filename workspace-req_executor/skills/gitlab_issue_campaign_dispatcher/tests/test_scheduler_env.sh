#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-scheduler-env.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
SCHEDULER_ROOT="${TEST_ROOT}/_scheduler"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=/data
EXECUTOR_SCHEDULER_ROOT=${SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=3
EOF

out="$(CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh")"
jq -e '.max_concurrency == 3 and (.scheduler_root | endswith("/_scheduler"))' <<<"${out}" >/dev/null

if [[ "${out}" == *$'\n'* ]]; then
  echo 'expected scheduler config JSON on one line' >&2
  exit 1
fi

for path in \
  "${SCHEDULER_ROOT}/batches" \
  "${SCHEDULER_ROOT}/callback_inbox" \
  "${SCHEDULER_ROOT}/callback_outbox"
do
  if [ ! -d "${path}" ]; then
    echo "expected scheduler directory to exist: ${path}" >&2
    exit 1
  fi
done

STATE_FILE="${SCHEDULER_ROOT}/scheduler_state.json"
EXPECTED_INITIAL_STATE='{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[]}'
if [ "$(<"${STATE_FILE}")" != "${EXPECTED_INITIAL_STATE}" ]; then
  echo 'unexpected initial scheduler state' >&2
  cat "${STATE_FILE}" >&2
  exit 1
fi

exported_paths="$(CONFIG_DIR="${CONFIG_DIR}" bash -c '
  source "$1" >/dev/null
  jq -cn \
    --arg state "${SCHEDULER_STATE_FILE}" \
    --arg lock "${SCHEDULER_LOCK_FILE}" \
    --arg batches "${BATCHES_ROOT}" \
    --arg inbox "${CALLBACK_INBOX}" \
    --arg outbox "${CALLBACK_OUTBOX}" \
    "{state:\$state,lock:\$lock,batches:\$batches,inbox:\$inbox,outbox:\$outbox}"
' _ "${SKILL_DIR}/scripts/scheduler_env.sh")"
jq -e \
  --arg root "${SCHEDULER_ROOT}" \
  '.state == ($root + "/scheduler_state.json")
    and .lock == ($root + "/scheduler.lock")
    and .batches == ($root + "/batches")
    and .inbox == ($root + "/callback_inbox")
    and .outbox == ($root + "/callback_outbox")' \
  <<<"${exported_paths}" >/dev/null

PRESERVED_STATE='{"version":1,"round_robin_cursor":"batch-1","active_jobs":{},"batch_order":["batch-1"]}'
printf '%s' "${PRESERVED_STATE}" >"${STATE_FILE}"
CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null
if [ "$(<"${STATE_FILE}")" != "${PRESERVED_STATE}" ]; then
  echo 'expected existing valid scheduler state to be preserved' >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_CONCURRENCY=0 bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null 2>&1; then
  echo 'expected invalid concurrency to fail' >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_SCHEDULER_ROOT=relative/path bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null 2>&1; then
  echo 'expected relative scheduler root to fail' >&2
  exit 1
fi

jq -e '.max_concurrency == 7' <<<"$(
  CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_MAX_CONCURRENCY=7 \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh"
)" >/dev/null

LOCAL_SCHEDULER_ROOT="${TEST_ROOT}/local/_scheduler"
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<EOF
EXECUTOR_SCHEDULER_ROOT=${LOCAL_SCHEDULER_ROOT}
EXECUTOR_MAX_CONCURRENCY=5
EOF

local_out="$(CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh")"
jq -e \
  --arg root "${LOCAL_SCHEDULER_ROOT}" \
  '.scheduler_root == $root and .max_concurrency == 5' \
  <<<"${local_out}" >/dev/null

jq -e '.max_concurrency == 7' <<<"$(
  CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_MAX_CONCURRENCY=7 \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh"
)" >/dev/null

echo 'ok scheduler env initialization'
