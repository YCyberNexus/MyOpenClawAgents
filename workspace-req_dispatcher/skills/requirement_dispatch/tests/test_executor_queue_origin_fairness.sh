#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-origin-fairness.XXXXXX")"
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

enqueue_issue() {
  local iid="$1"
  local user="$2"
  local origin
  origin="$(jq -nc --arg user "${user}" \
    '{channel:"wecom", user:$user, conversation:("c-" + $user), reply_agent:"reply_agent"}')"
  STATE_ROOT="${STATE_ROOT}" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="${iid}" \
  ISSUE_URL="http://gitlab/issues/${iid}" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${origin}" \
  REQ_DIGEST="issue ${iid}" \
  bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
}

enqueue_issue 12 "alice"
enqueue_issue 13 "alice"
enqueue_issue 14 "bob"

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_QUEUE_MAX_ACTIVE="2" \
  EXECUTOR_QUEUE_MAX_ACTIVE_PER_ORIGIN="1" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "drained" ] ||
   [ "$(jq -r '.launched_count' <<<"${drain}")" != "2" ] ||
   [ "$(jq -r '[.results[].iid] | join(",")' <<<"${drain}")" != "12,14" ]; then
  echo "expected one drain invocation to launch alice iid 12 and bob iid 14" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

if [ "$(jq -r '.active_count' <<<"${drain}")" != "2" ] ||
   [ "$(jq -r '.queued_count' <<<"${drain}")" != "1" ]; then
  echo "expected drain summary to report two active and one queued" >&2
  printf '%s\n' "${drain}" >&2
  jq . "${STATE_ROOT}/_dispatcher/executor_queue.json" >&2
  exit 1
fi

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
if [ "$(jq -r '[.active[].iid] | join(",")' "${queue_file}")" != "12,14" ] ||
   [ "$(jq -r '.queue | length' "${queue_file}")" != "1" ] ||
   [ "$(jq -r '.queue[0].iid' "${queue_file}")" != "13" ]; then
  echo "expected active iids 12,14 and alice iid 13 still queued" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

echo "ok executor queue applies per-origin active cap"
