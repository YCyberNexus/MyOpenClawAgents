#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-scheduler-env.XXXXXX")"
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

assert_unsafe_scheduler_root() {
  local unsafe_root="$1"
  local effective_root="$2"
  local label="$3"
  local accepted=false

  if CONFIG_DIR="${CONFIG_DIR}" \
    EXECUTOR_SCHEDULER_ROOT="${unsafe_root}" \
    bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null 2>&1
  then
    accepted=true
  fi

  if [ "${accepted}" = true ]; then
    echo "expected unsafe scheduler root to fail: ${label}" >&2
  fi
  if [ -e "${effective_root}/scheduler_state.json" ] || [ -e "${effective_root}/scheduler.lock" ]; then
    echo "unsafe scheduler root created state or lock: ${label}" >&2
    return 1
  fi
  [ "${accepted}" = false ] || return 1
}

assert_unsafe_scheduler_root "${TEST_ROOT}/safe/../escape" "${TEST_ROOT}/escape" 'parent segment'
assert_unsafe_scheduler_root "${TEST_ROOT}/./dot" "${TEST_ROOT}/dot" 'current-directory segment'
assert_unsafe_scheduler_root "${TEST_ROOT}/with space" "${TEST_ROOT}/with space" 'space'
assert_unsafe_scheduler_root "${TEST_ROOT}/line"$'\n'"break" "${TEST_ROOT}/line"$'\n'"break" 'newline'
assert_unsafe_scheduler_root / / 'filesystem root'
assert_unsafe_scheduler_root "${TEST_ROOT}//double" "${TEST_ROOT}/double" 'double slash'
assert_unsafe_scheduler_root "${TEST_ROOT}/trailing//" "${TEST_ROOT}/trailing" 'double trailing slash'
assert_unsafe_scheduler_root "${TEST_ROOT}/colon:name" "${TEST_ROOT}/colon:name" 'unsupported character'

NORMALIZED_SCHEDULER_ROOT="${TEST_ROOT}/normalized/_scheduler"
normalized_out="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_SCHEDULER_ROOT="${NORMALIZED_SCHEDULER_ROOT}/" \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh"
)"
jq -e \
  --arg root "${NORMALIZED_SCHEDULER_ROOT}" \
  '.scheduler_root == $root and .scheduler_state_file == ($root + "/scheduler_state.json")' \
  <<<"${normalized_out}" >/dev/null

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
