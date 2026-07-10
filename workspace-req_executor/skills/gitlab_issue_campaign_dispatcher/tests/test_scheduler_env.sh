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

GUARD_BIN="${TEST_ROOT}/guard-bin"
mkdir -p "${GUARD_BIN}"
cat >"${GUARD_BIN}/mkdir" <<'EOF'
#!/usr/bin/env bash
echo 'scheduler test guard: mkdir reached' >&2
exit 97
EOF
chmod +x "${GUARD_BIN}/mkdir"

SCHEDULER_ROOT_SAFETY_ERROR='scheduler_env.sh: unsafe EXECUTOR_SCHEDULER_ROOT:'
UNSAFE_CASE_INDEX=0

assert_unsafe_scheduler_root() {
  local unsafe_root="$1"
  local effective_root="$2"
  local label="$3"
  local root_existed_before=false
  local status=0
  local failed=false
  local stderr_file=""
  local stdout_file=""
  local derived_prefix="${effective_root%/}"
  local protected_path=""
  local -a protected_paths=(
    "${derived_prefix}/scheduler_state.json"
    "${derived_prefix}/scheduler.lock"
    "${derived_prefix}/batches"
    "${derived_prefix}/callback_inbox"
    "${derived_prefix}/callback_outbox"
  )

  if [ -e "${effective_root}" ]; then
    root_existed_before=true
  fi
  for protected_path in "${protected_paths[@]}"; do
    if [ -e "${protected_path}" ]; then
      echo "unsafe-root test precondition path already exists: ${label}: ${protected_path}" >&2
      return 1
    fi
  done

  UNSAFE_CASE_INDEX=$((UNSAFE_CASE_INDEX + 1))
  stderr_file="${TEST_ROOT}/unsafe-${UNSAFE_CASE_INDEX}.stderr"
  stdout_file="${TEST_ROOT}/unsafe-${UNSAFE_CASE_INDEX}.stdout"

  set +e
  PATH="${GUARD_BIN}:${PATH}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    EXECUTOR_SCHEDULER_ROOT="${unsafe_root}" \
    bash "${SKILL_DIR}/scripts/scheduler_env.sh" >"${stdout_file}" 2>"${stderr_file}"
  status=$?
  set -e

  if [ "${status}" -ne 2 ]; then
    echo "expected unsafe scheduler root to exit 2, got ${status}: ${label}" >&2
    failed=true
  fi
  if ! grep -Fq "${SCHEDULER_ROOT_SAFETY_ERROR}" "${stderr_file}"; then
    echo "expected scheduler root safety validation error: ${label}" >&2
    cat "${stderr_file}" >&2
    failed=true
  fi
  if [ "${root_existed_before}" = false ] && [ -e "${effective_root}" ]; then
    echo "unsafe scheduler root was created: ${label}: ${effective_root}" >&2
    failed=true
  fi
  for protected_path in "${protected_paths[@]}"; do
    if [ -e "${protected_path}" ]; then
      echo "unsafe scheduler root created derived path: ${label}: ${protected_path}" >&2
      failed=true
    fi
  done

  [ "${failed}" = false ]
}

assert_unsafe_scheduler_root /etc/req_executor /etc/req_executor 'outside allowlist: /etc'
assert_unsafe_scheduler_root /usr/local/req_executor /usr/local/req_executor 'outside allowlist: /usr/local'
assert_unsafe_scheduler_root /opt/req_executor /opt/req_executor 'outside allowlist: /opt'
assert_unsafe_scheduler_root relative/path "${PWD}/relative/path" 'relative path'
assert_unsafe_scheduler_root "${TEST_ROOT}/safe/../escape" "${TEST_ROOT}/escape" 'parent segment'
assert_unsafe_scheduler_root "${TEST_ROOT}/./dot" "${TEST_ROOT}/dot" 'current-directory segment'
assert_unsafe_scheduler_root "${TEST_ROOT}/with space" "${TEST_ROOT}/with space" 'space'
assert_unsafe_scheduler_root "${TEST_ROOT}/line"$'\n'"break" "${TEST_ROOT}/line"$'\n'"break" 'newline'
assert_unsafe_scheduler_root / / 'filesystem root'
assert_unsafe_scheduler_root "${TEST_ROOT}//double" "${TEST_ROOT}/double" 'double slash'
assert_unsafe_scheduler_root "${TEST_ROOT}/trailing//" "${TEST_ROOT}/trailing" 'double trailing slash'
assert_unsafe_scheduler_root "${TEST_ROOT}/colon:name" "${TEST_ROOT}/colon:name" 'unsupported character'

set +e
PATH="${GUARD_BIN}:${PATH}" \
  CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh" >/dev/null 2>"${TEST_ROOT}/data-default.stderr"
default_status=$?
set -e
if [ "${default_status}" -ne 97 ] || ! grep -Fq 'scheduler test guard: mkdir reached' "${TEST_ROOT}/data-default.stderr"; then
  echo 'expected /data scheduler default to pass validation and reach mkdir guard' >&2
  cat "${TEST_ROOT}/data-default.stderr" >&2
  exit 1
fi

SAFE_NESTED_ROOT="${TEST_ROOT}/scheduler"
safe_out="$(
  CONFIG_DIR="${CONFIG_DIR}" \
  EXECUTOR_SCHEDULER_ROOT="${SAFE_NESTED_ROOT}" \
  bash "${SKILL_DIR}/scripts/scheduler_env.sh"
)"
jq -e --arg root "${SAFE_NESTED_ROOT}" '.scheduler_root == $root' <<<"${safe_out}" >/dev/null

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
