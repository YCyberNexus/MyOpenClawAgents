#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-retry-free-slot.XXXXXX")"
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
printf '%s\n' '{"status":"waiting_for_callbacks","chat_summary":"accepted executor turn"}'
FAKE
chmod +x "${FAKE_OPENCLAW}"

for iid in 12 13; do
  origin="$(jq -nc --arg user "u${iid}" \
    '{channel:"wecom", user:$user, conversation:("c-" + $user), reply_agent:"reply_agent"}')"
  STATE_ROOT="${STATE_ROOT}" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="${iid}" \
  ISSUE_URL="http://gitlab/issues/${iid}" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${origin}" \
  REQ_DIGEST="issue ${iid}" \
  bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
done

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
tmp="$(mktemp "${TEST_ROOT}/queue.XXXXXX")"
jq '
  .active = [(.queue[0] + {
    correlation_id: "reqd-12",
    run_id: "executor-execq-1",
    launch_state: "launch_failed",
    launch_attempts: 1,
    launch_started_at: 1,
    launched_at: null,
    next_retry_after: 1,
    launch_error: "previous launch failed"
  })]
  | .queue = [.queue[1]]
' "${queue_file}" >"${tmp}"
mv "${tmp}" "${queue_file}"

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_QUEUE_MAX_ACTIVE="2" \
  EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS="60" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "launched" ] ||
   [ "$(jq -r '.iid' <<<"${drain}")" != "13" ]; then
  echo "expected free active slot to launch queued iid 13 before retrying existing failed active" >&2
  printf '%s\n' "${drain}" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '[.active[].iid] | join(",")' "${queue_file}")" != "12,13" ] ||
   [ "$(jq -r '.active[] | select(.iid == 12) | .launch_state' "${queue_file}")" != "launch_failed" ] ||
   [ "$(jq -r '.active[] | select(.iid == 13) | .launch_state' "${queue_file}")" != "launched" ]; then
  echo "expected failed iid 12 to remain active and queued iid 13 to use the free slot" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue | length' "${queue_file}")" != "0" ]; then
  echo "expected queued item to be consumed" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

echo "ok executor queue retry does not block a free active slot"
