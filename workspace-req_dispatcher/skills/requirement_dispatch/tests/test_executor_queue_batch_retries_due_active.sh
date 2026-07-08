#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-batch-retry.XXXXXX")"
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

jq -n '{
  next_id: 3,
  active: [
    {
      queue_id: "execq-1",
      project: "ai-infra/veqp_server_v3",
      iid: 12,
      issue_url: "http://gitlab/issues/12",
      executor_agent: "req_executor",
      origin: null,
      req_digest: "issue 12",
      queued_at: 1,
      correlation_id: "reqd-12",
      run_id: "executor-execq-1",
      launch_state: "launch_failed",
      launch_attempts: 1,
      launch_started_at: 1,
      launched_at: null,
      next_retry_after: 1,
      launch_error: "previous launch failed"
    },
    {
      queue_id: "execq-2",
      project: "ai-infra/veqp_server_v3",
      iid: 13,
      issue_url: "http://gitlab/issues/13",
      executor_agent: "req_executor",
      origin: null,
      req_digest: "issue 13",
      queued_at: 1,
      correlation_id: "reqd-13",
      run_id: "executor-execq-2",
      launch_state: "launch_failed",
      launch_attempts: 1,
      launch_started_at: 1,
      launched_at: null,
      next_retry_after: 1,
      launch_error: "previous launch failed"
    }
  ],
  queue: []
}' >"${DISPATCHER_DIR}/executor_queue.json"
jq -n '{pending:{}}' >"${DISPATCHER_DIR}/pending.json"
: >"${DISPATCHER_DIR}/ledger.jsonl"

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_QUEUE_MAX_ACTIVE="2" \
  EXECUTOR_QUEUE_DRAIN_BATCH_LIMIT="2" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "drained" ] ||
   [ "$(jq -r '.results | length' <<<"${drain}")" != "2" ] ||
   [ "$(jq -r '[.results[].iid] | join(",")' <<<"${drain}")" != "12,13" ]; then
  echo "expected one drain invocation to retry both due active issues" >&2
  printf '%s\n' "${drain}" >&2
  jq . "${DISPATCHER_DIR}/executor_queue.json" >&2
  exit 1
fi

if ! jq -e '
  (.active | length) == 2
  and ([.active[].launch_state] | all(. == "launched"))
  and ([.active[].launch_attempts] | all(. == 2))
' "${DISPATCHER_DIR}/executor_queue.json" >/dev/null; then
  echo "expected both due active issues to be marked relaunched" >&2
  jq . "${DISPATCHER_DIR}/executor_queue.json" >&2
  exit 1
fi

if [ "$(jq -r '.pending | length' "${DISPATCHER_DIR}/pending.json")" != "2" ]; then
  echo "expected two executor pending entries after batch retry" >&2
  jq . "${DISPATCHER_DIR}/pending.json" >&2
  exit 1
fi

echo "ok executor queue batch retries due active issues"
