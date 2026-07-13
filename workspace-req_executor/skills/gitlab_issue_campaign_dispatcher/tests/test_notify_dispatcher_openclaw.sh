#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-notify-dispatcher.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
OPENCLAW_LOG="${TEST_ROOT}/openclaw.args"
OPENCLAW_STDIN_LOG="${TEST_ROOT}/openclaw.stdin"
mkdir -p "${FAKE_BIN}"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'if [ "${1:-}" = agent ] && [ "${2:-}" = --help ]; then'
  printf '%s\n' '  printf "%s\n" "  --session-key <key>" "  --session-id <id>" "  --message-file <path>"'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'printf "%s\n" "$*" >> "${OPENCLAW_LOG}"'
  printf '%s\n' 'cat >"${OPENCLAW_STDIN_LOG}"'
  printf '%s\n' 'exit 0'
} > "${FAKE_BIN}/openclaw"
chmod +x "${FAKE_BIN}/openclaw"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
OPENCLAW_STDIN_LOG="${OPENCLAW_STDIN_LOG}" \
WORK_ROOT="${TEST_ROOT}/work" \
DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
CORRELATION_ID="reqd-99" \
IID="42" \
PROJECT="claw_gitlab/req_executor_test" \
STATUS="done" \
MR_URL="http://gitlab-b.pxsemic.tech:30000/claw_gitlab/req_executor_test/-/merge_requests/7" \
bash "${SKILL_DIR}/scripts/notify_dispatcher.sh" >/dev/null 2>"${TEST_ROOT}/notify.err"

if ! grep -q -- '--agent req_dispatcher' "${OPENCLAW_LOG}"; then
  echo "expected notify_dispatcher.sh to call openclaw agent --agent req_dispatcher" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '--session-key agent:req_dispatcher:main' "${OPENCLAW_LOG}"; then
  echo "expected notify_dispatcher.sh to target dispatcher session key" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if grep -q -- 'RUN_EXECUTOR_RESULT_CALLBACK' "${OPENCLAW_LOG}" \
    || ! grep -q -- '--message-file /dev/stdin' "${OPENCLAW_LOG}" \
    || ! grep -q -- 'RUN_EXECUTOR_RESULT_CALLBACK' "${OPENCLAW_STDIN_LOG}"; then
  echo "expected callback message only on stdin via --message-file" >&2
  cat "${OPENCLAW_LOG}" "${OPENCLAW_STDIN_LOG}" >&2
  exit 1
fi

if ! grep -q -- '"correlation_id":"reqd-99"' "${OPENCLAW_STDIN_LOG}"; then
  echo "expected callback message to include I2 correlation_id" >&2
  cat "${OPENCLAW_STDIN_LOG}" >&2
  exit 1
fi

if ! grep -q -- '"status":"done"' "${TEST_ROOT}/work/log/dispatcher_callbacks.jsonl"; then
  echo "expected dispatcher callback envelope to be recorded locally" >&2
  cat "${TEST_ROOT}/work/log/dispatcher_callbacks.jsonl" >&2
  exit 1
fi

echo "ok notify_dispatcher calls openclaw"
