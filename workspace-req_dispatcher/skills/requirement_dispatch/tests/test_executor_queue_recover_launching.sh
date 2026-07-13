#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-recover.XXXXXX")"
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
session_id=""
message=""
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) target_agent="$2"; shift 2 ;;
    --session-key) session_id="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --message-file) message_file="$2"; shift 2 ;;
    --timeout) shift 2 ;;
    *) echo "unexpected openclaw arg: $1" >&2; exit 8 ;;
  esac
done
[ -z "${message_file}" ] || [ "${message_file}" = /dev/stdin ] || exit 7
[ -z "${message_file}" ] || message="$(cat)"
jq -nc --arg agent "${target_agent}" --arg session_id "${session_id}" --arg message "${message}" \
  '{agent:$agent, session_id:$session_id, message:$message}' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"
printf '%s\n' '{"status":"waiting_for_callbacks","chat_summary":"accepted executor turn"}'
FAKE
chmod +x "${FAKE_OPENCLAW}"

STATE_ROOT="${STATE_ROOT}" \
PROJECT="ai-infra/veqp_server_v3" \
IID="12" \
ISSUE_URL="http://gitlab/issues/12" \
EXECUTOR_AGENT="req_executor" \
REQ_DIGEST="issue 12" \
bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
tmp="$(mktemp "${TEST_ROOT}/queue.XXXXXX")"
jq '
  .active = (.queue[0] + {
    correlation_id: "reqd-77",
    run_id: "executor-execq-1",
    launch_state: "launching",
    launch_attempts: 1,
    launch_started_at: 1,
    launched_at: null,
    next_retry_after: null,
    launch_error: null
  })
  | .queue = []
' "${queue_file}" >"${tmp}"
mv "${tmp}" "${queue_file}"

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS="1" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "launched" ]; then
  echo "expected stale launching active to be relaunched" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

if [ "$(jq -r '.correlation_id' <<<"${drain}")" != "reqd-77" ] ||
   [ "$(jq -r '.run_id' <<<"${drain}")" != "executor-execq-1" ]; then
  echo "expected relaunch to reuse correlation_id and run_id" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

message="$(jq -r 'select(.agent=="req_executor") | .message' "${OPENCLAW_CALL_LOG}")"
if ! grep -q '^correlation_id=reqd-77$' <<<"${message}"; then
  echo "expected relaunched payload to reuse reqd-77" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if [ "$(jq -r '.active.launch_attempts' "${queue_file}")" != "2" ] ||
   [ "$(jq -r '.active.launch_state' "${queue_file}")" != "launched" ]; then
  echo "expected active launch_attempts to increment and mark launched" >&2
  cat "${queue_file}" >&2
  exit 1
fi

echo "ok executor queue recovers stale launching active"
