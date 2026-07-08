#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-reject.XXXXXX")"
STATE_ROOT="${TEST_ROOT}/state"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls.jsonl"

cat >"${FAKE_OPENCLAW}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != "agent" ]; then
  echo "unexpected openclaw command: $*" >&2
  exit 9
fi
shift
target_agent=""
message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) target_agent="$2"; shift 2 ;;
    --session-id) shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --timeout) shift 2 ;;
    *) echo "unexpected openclaw arg: $1" >&2; exit 8 ;;
  esac
done
jq -nc --arg agent "${target_agent}" --arg message "${message}" \
  '{agent:$agent, message:$message}' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"
printf '%s\n' '{"status":"completed","chat_summary":"nothing to spawn"}'
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

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
pending_file="${STATE_ROOT}/_dispatcher/pending.json"

if [ "$(jq -r '.status' <<<"${drain}")" != "launch_failed" ]; then
  echo "expected unaccepted executor output to become launch_failed" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

if [ "$(jq -r '.active[0].launch_state' "${queue_file}")" != "launch_failed" ]; then
  echo "expected active to remain launch_failed" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

if ! jq -e '.active[0].launch_error | contains("worker_result_json.status=completed")' \
  "${queue_file}" >/dev/null; then
  echo "expected launch_error to explain rejected worker status" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.pending | length' "${pending_file}")" != "0" ]; then
  echo "expected no executor pending entry for unaccepted output" >&2
  jq . "${pending_file}" >&2
  exit 1
fi

if [ "$(jq -s 'length' "${OPENCLAW_CALL_LOG}")" != "3" ]; then
  echo "expected three retry attempts for unaccepted output" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

echo "ok executor queue rejects unaccepted output"
