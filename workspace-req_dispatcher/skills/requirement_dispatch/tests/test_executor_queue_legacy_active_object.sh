#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-legacy-active.XXXXXX")"
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

make_legacy_queue() {
  local state_root="$1"
  local dispatcher_dir="${state_root}/_dispatcher"
  mkdir -p "${dispatcher_dir}"
  jq -n '{
    next_id: 2,
    active: {
      queue_id: "execq-1",
      project: "ai-infra/veqp_server_v3",
      iid: 12,
      issue_url: "http://gitlab/issues/12",
      executor_agent: "req_executor",
      origin: null,
      req_digest: "issue 12",
      queued_at: 1,
      correlation_id: "reqd-legacy",
      run_id: "executor-execq-1",
      launch_state: "launching",
      launch_attempts: 1,
      launch_started_at: 1,
      launched_at: null,
      next_retry_after: null,
      launch_error: null
    },
    queue: []
  }' >"${dispatcher_dir}/executor_queue.json"
  jq -n '{pending:{}}' >"${dispatcher_dir}/pending.json"
  : >"${dispatcher_dir}/ledger.jsonl"
}

drain_state="${TEST_ROOT}/state-drain"
make_legacy_queue "${drain_state}"
drain="$(
  STATE_ROOT="${drain_state}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS="1" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "launched" ] ||
   [ "$(jq -r '.correlation_id' <<<"${drain}")" != "reqd-legacy" ]; then
  echo "expected legacy active object to be normalized and relaunched" >&2
  printf '%s\n' "${drain}" >&2
  jq . "${drain_state}/_dispatcher/executor_queue.json" >&2
  exit 1
fi

if ! jq -e '(.active | type) == "array" and (.active | length) == 1 and .active[0].launch_attempts == 2' \
  "${drain_state}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "expected drain to persist legacy active object as active array" >&2
  jq . "${drain_state}/_dispatcher/executor_queue.json" >&2
  exit 1
fi

finish_state="${TEST_ROOT}/state-finish"
make_legacy_queue "${finish_state}"
finish="$(
  STATE_ROOT="${finish_state}" \
  CORRELATION_ID="reqd-legacy" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="12" \
  bash "${SKILL_DIR}/scripts/finish_executor_queue_active.sh"
)"

if [ "$(jq -r '.status' <<<"${finish}")" != "cleared" ] ||
   ! jq -e '(.active | type) == "array" and (.active | length) == 0' \
     "${finish_state}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "expected finish to clear legacy active object and leave active array" >&2
  printf '%s\n' "${finish}" >&2
  jq . "${finish_state}/_dispatcher/executor_queue.json" >&2
  exit 1
fi

evict_state="${TEST_ROOT}/state-evict"
make_legacy_queue "${evict_state}"
old_ts="$(( $(date -u +%s) - 7200 ))"
jq --argjson ts "${old_ts}" '
  .pending["executor-execq-1"] = {
    run_id: "executor-execq-1",
    stage: "executor",
    origin: null,
    project: "ai-infra/veqp_server_v3",
    iid: 12,
    correlation_id: "reqd-legacy",
    child_session_key: null,
    spawned_at: $ts,
    req_digest: "issue 12"
  }
' "${evict_state}/_dispatcher/pending.json" >"${TEST_ROOT}/pending.legacy"
mv "${TEST_ROOT}/pending.legacy" "${evict_state}/_dispatcher/pending.json"

STATE_ROOT="${evict_state}" \
STUCK_AFTER_MINUTES="1" \
bash "${SKILL_DIR}/scripts/evict_stuck.sh" >/dev/null

if ! jq -e '(.active | type) == "array" and (.active | length) == 0' \
  "${evict_state}/_dispatcher/executor_queue.json" >/dev/null; then
  echo "expected evict to clear legacy active object and leave active array" >&2
  jq . "${evict_state}/_dispatcher/executor_queue.json" >&2
  exit 1
fi

if ! jq -e '.pending == {}' "${evict_state}/_dispatcher/pending.json" >/dev/null; then
  echo "expected evict to clear matching pending entry" >&2
  jq . "${evict_state}/_dispatcher/pending.json" >&2
  exit 1
fi

echo "ok executor queue handles legacy active object state"
