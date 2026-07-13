#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-finish.XXXXXX")"
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

origin='{"channel":"wecom","user":"u1","conversation":"c1","reply_agent":"reply_agent"}'
for iid in 12 13; do
  STATE_ROOT="${STATE_ROOT}" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="${iid}" \
  ISSUE_URL="http://gitlab/issues/${iid}" \
  EXECUTOR_AGENT="req_executor" \
  ORIGIN_JSON="${origin}" \
  REQ_DIGEST="issue ${iid}" \
  bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
done

drain_one="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
pending_file="${STATE_ROOT}/_dispatcher/pending.json"
queue_before_finish="$(jq -cS . "${queue_file}")"
pending_before_finish="$(jq -cS . "${pending_file}")"
set +e
finish="$(
  STATE_ROOT="${STATE_ROOT}" \
  CORRELATION_ID="$(jq -r '.correlation_id' <<<"${drain_one}")" \
  PROJECT="ai-infra/veqp_server_v3" \
  IID="12" \
  bash "${SKILL_DIR}/scripts/finish_executor_queue_active.sh" 2>&1
)"
finish_rc=$?
set -e

if [ "${finish_rc}" -eq 0 ] \
  || [ "$(jq -cS . "${queue_file}")" != "${queue_before_finish}" ] \
  || [ "$(jq -cS . "${pending_file}")" != "${pending_before_finish}" ]; then
  echo "expected direct legacy finish to reject nonce_v1 active without mutation" >&2
  printf '%s\n' "${finish}" >&2
  exit 1
fi

drain_two="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain_two}")" != "busy" ] ||
   [ "$(jq -r '.active.iid' <<<"${drain_two}")" != "12" ]; then
  echo "expected rejected direct finish to keep iid 12 active" >&2
  printf '%s\n' "${drain_two}" >&2
  exit 1
fi

if [ "$(jq -r '.active.iid' "${queue_file}")" != "12" ] ||
   [ "$(jq -r '.queue | length' "${queue_file}")" != "1" ]; then
  echo "expected iid 12 active and iid 13 still queued" >&2
  cat "${queue_file}" >&2
  exit 1
fi

mapfile -t launched_iids < <(jq -r 'select(.agent=="req_executor") | .message' "${OPENCLAW_CALL_LOG}" | awk -F= '/^iid=/{print $2}')
if [ "${#launched_iids[@]}" -ne 1 ] ||
   [ "${launched_iids[0]}" != "12" ]; then
  echo "expected rejected direct finish not to launch iid 13" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

echo "ok executor queue rejects direct legacy finish for nonce_v1 active"
