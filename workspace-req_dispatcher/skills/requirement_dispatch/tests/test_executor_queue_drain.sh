#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-queue-drain.XXXXXX")"
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      target_agent="$2"
      shift 2
      ;;
    --session-key)
      session_id="$2"
      shift 2
      ;;
    --message)
      message="$2"
      shift 2
      ;;
    --timeout)
      shift 2
      ;;
    *)
      echo "unexpected openclaw arg: $1" >&2
      exit 8
      ;;
  esac
done

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
  TARGET_BRANCH="$([ "${iid}" = "12" ] && printf 'release/2026.07' || true)" \
  ORIGIN_JSON="${origin}" \
  REQ_DIGEST="issue ${iid}" \
  bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh" >/dev/null
done

queue_file="${STATE_ROOT}/_dispatcher/executor_queue.json"
pending_file="${STATE_ROOT}/_dispatcher/pending.json"
cp "${queue_file}" "${TEST_ROOT}/executor_queue.before-empty-callback.json"
cp "${pending_file}" "${TEST_ROOT}/pending.before-empty-callback.json"

set +e
empty_callback_output="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="" \
    bash "${SKILL_DIR}/scripts/drain_executor_queue.sh" 2>&1
)"
empty_callback_rc=$?
set -e
if [ "${empty_callback_rc}" -eq 0 ]; then
  echo "empty callback target must fail before draining the legacy queue" >&2
  printf '%s\n' "${empty_callback_output}" >&2
  exit 1
fi
if ! cmp -s "${queue_file}" "${TEST_ROOT}/executor_queue.before-empty-callback.json" \
  || ! cmp -s "${pending_file}" "${TEST_ROOT}/pending.before-empty-callback.json" \
  || [ -e "${STATE_ROOT}/_dispatcher/seq" ]; then
  echo "empty callback target changed legacy queue, pending, or seq state" >&2
  exit 1
fi
if [ -s "${OPENCLAW_CALL_LOG}" ]; then
  echo "empty callback target reached the legacy executor" >&2
  exit 1
fi

drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${drain}")" != "launched" ]; then
  echo "expected drain status launched" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

if [ "$(jq -r '.iid' <<<"${drain}")" != "12" ]; then
  echo "expected drain to launch first queued iid 12" >&2
  printf '%s\n' "${drain}" >&2
  exit 1
fi

if [ "$(jq -r '.active.iid' "${queue_file}")" != "12" ] ||
   [ "$(jq -r '.active.launch_state' "${queue_file}")" != "launched" ]; then
  echo "expected active launched item to be iid 12" >&2
  cat "${queue_file}" >&2
  exit 1
fi

if [ "$(jq -r '.queue | length' "${queue_file}")" != "1" ] ||
   [ "$(jq -r '.queue[0].iid' "${queue_file}")" != "13" ]; then
  echo "expected iid 13 to remain queued" >&2
  cat "${queue_file}" >&2
  exit 1
fi

message="$(jq -r 'select(.agent=="req_executor") | .message' "${OPENCLAW_CALL_LOG}")"
if ! grep -q '^RUN_SINGLE_ISSUE' <<<"${message}" ||
   ! grep -q '^iid=12$' <<<"${message}" ||
   ! grep -q '^correlation_id=reqd-1$' <<<"${message}" ||
   ! grep -q '^branch=release/2026.07$' <<<"${message}"; then
  echo "expected RUN_SINGLE_ISSUE payload for iid 12 with reqd-1 and target branch" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if [ "$(jq -r '.pending | length' "${pending_file}")" != "1" ]; then
  echo "expected one executor pending entry" >&2
  cat "${pending_file}" >&2
  exit 1
fi

if [ "$(jq -r '.pending | to_entries[0].value.correlation_id' "${pending_file}")" != "reqd-1" ]; then
  echo "expected pending correlation reqd-1" >&2
  cat "${pending_file}" >&2
  exit 1
fi

echo "ok executor queue drain launches first item"
