#!/usr/bin/env bash
set -euo pipefail
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-stuck-recovery.XXXXXX")"
STATE_ROOT="${TEST_ROOT}/state"
DISPATCHER_DIR="${STATE_ROOT}/_dispatcher"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls.jsonl"

mkdir -p "${DISPATCHER_DIR}"

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
message_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) target_agent="$2"; shift 2 ;;
    --session-key) shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --message-file) message_file="$2"; shift 2 ;;
    --timeout) shift 2 ;;
    *) echo "unexpected openclaw arg: $1" >&2; exit 8 ;;
  esac
done
[ -z "${message_file}" ] || [ "${message_file}" = /dev/stdin ] || exit 7
[ -z "${message_file}" ] || message="$(cat)"
jq -nc --arg agent "${target_agent}" --arg message "${message}" \
  '{agent:$agent, message:$message}' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"
printf '%s\n' '{"status":"waiting_for_callbacks","chat_summary":"accepted executor turn"}'
FAKE
chmod +x "${FAKE_OPENCLAW}"

old_ts="$(( $(date -u +%s) - 7200 ))"
jq -n --argjson ts "${old_ts}" \
  '{
    pending: {
      "run-executor-stuck": {
        run_id: "run-executor-stuck",
        stage: "executor",
        origin: null,
        project: "group/project",
        iid: 42,
        correlation_id: "corr-42",
        child_session_key: "child-42",
        spawned_at: $ts,
        req_digest: "stuck requirement"
      }
    }
  }' > "${DISPATCHER_DIR}/pending.json"
: > "${DISPATCHER_DIR}/ledger.jsonl"
jq -n '{
  next_id: 2,
  active: {
    queue_id: "execq-1",
    project: "group/project",
    iid: 42,
    issue_url: "http://gitlab/issues/42",
    executor_agent: "req_executor",
    origin: null,
    req_digest: "stuck requirement",
    queued_at: 1,
    correlation_id: "corr-42",
    run_id: "run-executor-stuck",
    launch_state: "launched",
    launch_attempts: 1,
    launch_started_at: 1,
    launched_at: 2,
    next_retry_after: null,
    launch_error: null,
    child_session_key: "child-42"
  },
  queue: [{
    queue_id: "execq-2",
    project: "group/project",
    iid: 46,
    issue_url: "http://gitlab/issues/46",
    executor_agent: "req_executor",
    origin: null,
    req_digest: "queued after stuck",
    queued_at: 3
  }]
}' > "${DISPATCHER_DIR}/executor_queue.json"

STATE_ROOT="${STATE_ROOT}" \
STUCK_AFTER_MINUTES="1" \
bash "${SKILL_DIR}/scripts/evict_stuck.sh" >/dev/null

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "launched" ] ||
   [ "$(jq -r '.iid' <<<"${drain}")" != "46" ]; then
  echo "expected queue drain after stuck eviction to launch iid 46" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

if [ "$(jq -r '.active.iid' "${DISPATCHER_DIR}/executor_queue.json")" != "46" ] ||
   [ "$(jq -r '.queue | length' "${DISPATCHER_DIR}/executor_queue.json")" != "0" ]; then
  echo "expected iid 46 to become active after stuck recovery" >&2
  jq . "${DISPATCHER_DIR}/executor_queue.json" >&2
  exit 1
fi

if [ "$(jq -r '.pending | length' "${DISPATCHER_DIR}/pending.json")" != "1" ]; then
  echo "expected only new executor pending entry after stuck recovery" >&2
  jq . "${DISPATCHER_DIR}/pending.json" >&2
  exit 1
fi

message="$(jq -r 'select(.agent=="req_executor") | .message' "${OPENCLAW_CALL_LOG}")"
if ! grep -q '^iid=46$' <<<"${message}"; then
  echo "expected recovered drain to launch queued iid 46" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

echo "ok executor queue recovers after stuck active eviction"
