#!/usr/bin/env bash
set -euo pipefail
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>\n  --session-id <id>\n  --message-file <path>'
export RUN_AGENT_TURN_STRICT_JSON_RECEIPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-callback-race.XXXXXX")"
STATE_ROOT="${TEST_ROOT}/state"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls.jsonl"
CALLBACK_ATTEMPT_LOG="${TEST_ROOT}/callback-attempt.json"

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

set +e
STATE_ROOT="${STATE_ROOT:?STATE_ROOT required}" \
RUN_ID="executor-execq-1" \
OUTCOME="success" \
STAGE="executor" \
PROJECT="ai-infra/veqp_server_v3" \
IID="12" \
MR_URL="http://gitlab/mr/1" \
bash "${SKILL_DIR:?SKILL_DIR required}/scripts/drain_pending.sh" >/dev/null 2>&1
drain_pending_rc=$?

STATE_ROOT="${STATE_ROOT}" \
CORRELATION_ID="reqd-1" \
PROJECT="ai-infra/veqp_server_v3" \
IID="12" \
bash "${SKILL_DIR}/scripts/finish_executor_queue_active.sh" >/dev/null 2>&1
finish_active_rc=$?
set -e
jq -nc \
  --argjson drain_pending_rc "${drain_pending_rc}" \
  --argjson finish_active_rc "${finish_active_rc}" \
  '{drain_pending_rc:$drain_pending_rc,finish_active_rc:$finish_active_rc}' \
  >"${CALLBACK_ATTEMPT_LOG:?CALLBACK_ATTEMPT_LOG required}"

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
  CALLBACK_ATTEMPT_LOG="${CALLBACK_ATTEMPT_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
pending_file="${STATE_ROOT}/_dispatcher/pending.json"

if [ "$(jq -r '.status' <<<"${drain}")" != "launched" ]; then
  echo "expected rejected I2 callback attempt to leave the nonce_v1 launch active" >&2
  printf '%s\n' "${drain}" >&2
  jq . "${queue_file}" >&2
  jq . "${pending_file}" >&2
  exit 1
fi

if ! jq -e '
    .active.run_id == "executor-execq-1"
    and .active.launch_state == "launched"
    and (.active.callback_nonce | test("^[0-9a-f]{64}$"))
  ' "${queue_file}" >/dev/null; then
  echo "expected rejected I2 callback attempt to preserve the launched active" >&2
  jq . "${queue_file}" >&2
  exit 1
fi

if ! jq -e '
    (.pending | length) == 1
    and .pending["executor-execq-1"].callback_auth_mode == "nonce_v1"
    and (.pending["executor-execq-1"].callback_nonce_sha256
      | test("^[0-9a-f]{64}$"))
  ' "${pending_file}" >/dev/null; then
  echo "expected rejected I2 callback attempt to preserve nonce_v1 pending state" >&2
  jq . "${pending_file}" >&2
  exit 1
fi

if ! jq -e '.drain_pending_rc != 0 and .finish_active_rc != 0' \
  "${CALLBACK_ATTEMPT_LOG}" >/dev/null; then
  echo "expected both forged legacy I2 callback operations to fail" >&2
  jq . "${CALLBACK_ATTEMPT_LOG}" >&2
  exit 1
fi

if [ -s "${STATE_ROOT}/_dispatcher/ledger.jsonl" ]; then
  echo "rejected I2 callback wrote a completion ledger row" >&2
  sed -n '1,20p' "${STATE_ROOT}/_dispatcher/ledger.jsonl" >&2
  exit 1
fi

echo "ok executor queue rejects forged legacy callback during nonce_v1 launch"
