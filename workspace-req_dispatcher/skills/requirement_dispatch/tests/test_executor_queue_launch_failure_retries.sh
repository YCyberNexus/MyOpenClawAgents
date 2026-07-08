#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-retries.XXXXXX")"
STATE_ROOT="${TEST_ROOT}/state"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls"

cat >"${FAKE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"
printf '\n' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"
echo "simulated gateway failure" >&2
exit 42
FAKE
chmod +x "${FAKE_OPENCLAW}"

STATE_ROOT="${STATE_ROOT}" \
PROJECT="ai-infra/veqp_server_v3" \
IID="12" \
ISSUE_URL="http://gitlab/issues/12" \
EXECUTOR_AGENT="req_executor" \
REQ_DIGEST="issue 12" \
bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS="0" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "launch_failed" ]; then
  echo "expected launch_failed status" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

call_count="$(wc -l <"${OPENCLAW_CALL_LOG}" | tr -d ' ')"
if [ "${call_count}" != "3" ]; then
  echo "expected three identical launch attempts, got ${call_count}" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if [ "$(sort -u "${OPENCLAW_CALL_LOG}" | wc -l | tr -d ' ')" != "1" ]; then
  echo "expected identical openclaw launch arguments on every retry" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
if [ "$(jq -r '.active[0].iid' "${queue_file}")" != "12" ] ||
   [ "$(jq -r '.active[0].launch_state' "${queue_file}")" != "launch_failed" ] ||
   [ "$(jq -r '.queue | length' "${queue_file}")" != "0" ]; then
  echo "expected failed launch to keep iid 12 active for later retry" >&2
  cat "${queue_file}" >&2
  exit 1
fi

echo "ok executor queue launch failure retries"
