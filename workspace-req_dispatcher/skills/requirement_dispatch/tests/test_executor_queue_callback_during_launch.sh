#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-callback-race.XXXXXX")"
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
    --session-key) shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --timeout) shift 2 ;;
    *) echo "unexpected openclaw arg: $1" >&2; exit 8 ;;
  esac
done
jq -nc --arg agent "${target_agent}" --arg message "${message}" \
  '{agent:$agent, message:$message}' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"

STATE_ROOT="${STATE_ROOT:?STATE_ROOT required}" \
RUN_ID="executor-execq-1" \
OUTCOME="success" \
STAGE="executor" \
PROJECT="ai-infra/veqp_server_v3" \
IID="12" \
MR_URL="http://gitlab/mr/1" \
bash "${SKILL_DIR:?SKILL_DIR required}/scripts/drain_pending.sh" >/dev/null

STATE_ROOT="${STATE_ROOT}" \
CORRELATION_ID="reqd-1" \
PROJECT="ai-infra/veqp_server_v3" \
IID="12" \
bash "${SKILL_DIR}/scripts/finish_executor_queue_active.sh" >/dev/null

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

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  SKILL_DIR="${SKILL_DIR}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
pending_file="${STATE_ROOT}/_dispatcher/pending.json"

if [ "$(jq -r '.status' <<<"${drain}")" != "active_changed_after_launch" ]; then
  echo "expected drain to detect callback already changed active" >&2
  printf '%s\n' "${drain}" >&2
  jq . "${queue_file}" >&2
  jq . "${pending_file}" >&2
  exit 1
fi

if ! jq -e '.active == null' "${queue_file}" >/dev/null; then
  echo "expected callback during launch to leave active cleared" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.pending | length' "${pending_file}")" != "0" ]; then
  echo "expected no leaked pending after callback during launch" >&2
  jq . "${pending_file}" >&2
  exit 1
fi

if ! jq -e 'select(.run_id=="executor-execq-1" and .outcome=="success" and .was_pending==true)' \
  "${STATE_ROOT}/_dispatcher/ledger.jsonl" >/dev/null; then
  echo "expected early callback to drain a real pending entry" >&2
  sed -n '1,20p' "${STATE_ROOT}/_dispatcher/ledger.jsonl" >&2
  exit 1
fi

echo "ok executor queue handles callback during launch"
