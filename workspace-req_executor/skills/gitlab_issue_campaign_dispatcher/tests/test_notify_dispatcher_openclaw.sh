#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-notify-dispatcher.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
OPENCLAW_LOG="${TEST_ROOT}/openclaw.args"
mkdir -p "${FAKE_BIN}"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\n" "$*" >> "${OPENCLAW_LOG}"'
  printf '%s\n' 'exit 0'
} > "${FAKE_BIN}/openclaw"
chmod +x "${FAKE_BIN}/openclaw"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
WORK_ROOT="${TEST_ROOT}/work" \
DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
CORRELATION_ID="reqd-99" \
IID="42" \
PROJECT="claw_gitlab/px_ifp_hulat_test" \
STATUS="done" \
MR_URL="http://gitlab-b.pxsemic.tech:30000/claw_gitlab/px_ifp_hulat_test/-/merge_requests/7" \
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

if ! grep -q -- 'RUN_EXECUTOR_RESULT_CALLBACK' "${OPENCLAW_LOG}"; then
  echo "expected callback message to include RUN_EXECUTOR_RESULT_CALLBACK" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '"correlation_id":"reqd-99"' "${OPENCLAW_LOG}"; then
  echo "expected callback message to include I2 correlation_id" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '"status":"done"' "${TEST_ROOT}/work/log/dispatcher_callbacks.jsonl"; then
  echo "expected dispatcher callback envelope to be recorded locally" >&2
  cat "${TEST_ROOT}/work/log/dispatcher_callbacks.jsonl" >&2
  exit 1
fi

echo "ok notify_dispatcher calls openclaw"
