#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-wiki-flow.XXXXXX")"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_CALL_LOG="${TEST_ROOT}/openclaw.calls.jsonl"
ISSUE_SEQ_FILE="${TEST_ROOT}/issue-seq"
STATE_ROOT="${TEST_ROOT}/state"

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
    --message-file)
      message_file="$2"
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
[ -z "${message_file}" ] || [ "${message_file}" = /dev/stdin ] || exit 7
[ -z "${message_file}" ] || message="$(cat)"

jq -nc --arg agent "${target_agent}" --arg session_id "${session_id}" --arg message "${message}" \
  '{agent: $agent, session_id: $session_id, message: $message}' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"

case "${target_agent}" in
  git_issuer)
    current="0"
    if [ -f "${ISSUE_SEQ_FILE:?ISSUE_SEQ_FILE required}" ]; then
      current="$(cat "${ISSUE_SEQ_FILE}")"
    fi
    next=$((current + 1))
    printf '%s\n' "${next}" >"${ISSUE_SEQ_FILE}"
    iid=$((100 + next))
    jq -nc \
      --argjson iid "${iid}" \
      --arg issue_url "http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/issues/${iid}" \
      '{status:"success",issue_iid:$iid,issue_url:$issue_url,project:"claw_gitlab/px_ifp_hulat_test",entry_label:"todo",reason:null,correlation_id:null}'
    ;;
  req_executor)
    iid="$(awk -F= '$1 == "iid" {print $2; exit}' <<<"${message}")"
    jq -nc --arg iid "${iid}" '{
      status:"success",
      batch_id:("single-wiki-" + $iid),
      matched_count:1,
      snapshot_digest:("e" * 64),
      scheduler_status:"queued"
    }'
    ;;
  *)
    echo "unexpected target agent: ${target_agent}" >&2
    exit 7
    ;;
esac
FAKE
chmod +x "${FAKE_OPENCLAW}"

WIKI_URL="http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements"
WIKI_CONTENT="$(cat <<'EOF'
## Login flow
Implement password reset.

## Export flow
Add CSV export.
EOF
)"

prepared="$(
  MESSAGE="请处理 ${WIKI_URL}" \
  WIKI_CONTENT="${WIKI_CONTENT}" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

payload_count="$(jq '.git_issuer_payloads | length' <<<"${prepared}")"
if [ "${payload_count}" -ne 2 ]; then
  echo "expected two git_issuer payloads" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

for idx in $(seq 0 $((payload_count - 1))); do
  payload="$(jq -r --argjson idx "${idx}" '.git_issuer_payloads[$idx]' <<<"${prepared}")"
  git_envelope="$(
    OPENCLAW_BIN="${FAKE_OPENCLAW}" \
    OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
    ISSUE_SEQ_FILE="${ISSUE_SEQ_FILE}" \
    TARGET_AGENT="git_issuer" \
    TARGET_SESSION_KEY="agent:git_issuer:main" \
    RUN_ID="git-${idx}" \
    bash "${SKILL_DIR}/scripts/run_agent_turn.sh" <<<"${payload}"
  )"
  if [ "$(jq -r '.status' <<<"${git_envelope}")" != "success" ]; then
    echo "expected git_issuer run_agent_turn success" >&2
    printf '%s\n' "${git_envelope}" >&2
    exit 1
  fi
  issue_json="$(jq -c '.worker_result_json' <<<"${git_envelope}")"
  project="$(jq -r '.project' <<<"${issue_json}")"
  iid="$(jq -r '.issue_iid' <<<"${issue_json}")"
  issue_url="$(jq -r '.issue_url' <<<"${issue_json}")"
  executor="$(
    PROJECT="${project}" \
    DEFAULT_EXECUTOR_AGENT="req_executor" \
    bash "${SKILL_DIR}/scripts/route_project.sh"
  )"
  enqueue="$(
    STATE_ROOT="${STATE_ROOT}" \
    PROJECT="${project}" \
    IID="${iid}" \
    ISSUE_URL="${issue_url}" \
    EXECUTOR_AGENT="${executor}" \
    REQ_DIGEST="wiki item ${idx}" \
    bash "${SKILL_DIR}/scripts/enqueue_executor_issue.sh"
  )"
  if [ "$(jq -r '.status' <<<"${enqueue}")" != "queued" ]; then
    echo "expected enqueue success" >&2
    printf '%s\n' "${enqueue}" >&2
    exit 1
  fi

  queue_drain="$(
    STATE_ROOT="${STATE_ROOT}" \
    OPENCLAW_BIN="${FAKE_OPENCLAW}" \
    OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
    ISSUE_SEQ_FILE="${ISSUE_SEQ_FILE}" \
    EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
    DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
    bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
  )"
  if [ "${idx}" -eq 0 ]; then
    if [ "$(jq -r '.status' <<<"${queue_drain}")" != "launched" ] ||
       [ "$(jq -r '.iid' <<<"${queue_drain}")" != "101" ]; then
      echo "expected first queued issue to launch" >&2
      printf '%s\n' "${queue_drain}" >&2
      exit 1
    fi
    first_run_id="$(jq -r '.run_id' <<<"${queue_drain}")"
    first_correlation_id="$(jq -r '.correlation_id' <<<"${queue_drain}")"
  else
    if [ "$(jq -r '.status' <<<"${queue_drain}")" != "busy" ]; then
      echo "expected second issue to stay queued while first is active" >&2
      printf '%s\n' "${queue_drain}" >&2
      exit 1
    fi
  fi
done

first_callback_nonce="$(jq -r '.active.callback_nonce' \
  "${STATE_ROOT}/_dispatcher/executor_queue.json")"
first_batch_id="$(jq -r '.active.driven_batch_id' \
  "${STATE_ROOT}/_dispatcher/executor_queue.json")"
first_event="$(jq -cn \
  --arg batch_id "${first_batch_id}" '{
    event_id:($batch_id + ":snapshot-0:terminal-1"),
    batch_id:$batch_id,
    snapshot_index:0,
    project:"claw_gitlab/px_ifp_hulat_test",
    iid:101,
    status:"done",
    mr_url:"http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/merge_requests/1",
    reason:null
  }')"
first_callback_envelope="$(jq -cn \
  --arg callback_nonce "${first_callback_nonce}" \
  --argjson event "${first_event}" '{
    callback_nonce:$callback_nonce,
    executor_agent:"req_executor",
    worker_result_json:$event
  }')"
STATE_ROOT="${STATE_ROOT}" CALLBACK_ENVELOPE_JSON="${first_callback_envelope}" \
  bash "${SKILL_DIR}/scripts/handle_executor_batch_event.sh" >/dev/null
first_recovery="$(
  STATE_ROOT="${STATE_ROOT}" \
    bash "${SKILL_DIR}/scripts/recover_legacy_executor_batch_bridge.sh"
)"
if ! jq -e '.status == "cleared"' <<<"${first_recovery}" >/dev/null; then
  echo "expected authenticated first Issue callback to clear the single bridge" >&2
  printf '%s\n' "${first_recovery}" >&2
  exit 1
fi

second_drain="$(
  STATE_ROOT="${STATE_ROOT}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
  ISSUE_SEQ_FILE="${ISSUE_SEQ_FILE}" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="600" \
  DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
  bash "${SKILL_DIR}/scripts/drain_executor_queue.sh"
)"

if [ "$(jq -r '.status' <<<"${second_drain}")" != "launched" ] ||
   [ "$(jq -r '.iid' <<<"${second_drain}")" != "102" ]; then
  echo "expected second queued issue to launch after first finishes" >&2
  printf '%s\n' "${second_drain}" >&2
  exit 1
fi

git_calls="$(jq -r 'select(.agent=="git_issuer") | .message' "${OPENCLAW_CALL_LOG}" | grep -c '^CREATE_GITLAB_ISSUE')"
executor_calls="$(jq -r 'select(.agent=="req_executor") | .message' "${OPENCLAW_CALL_LOG}" | grep -c '^RUN_SINGLE_ISSUE')"
executor_sessions="$(jq -r 'select(.agent=="req_executor") | .session_id' "${OPENCLAW_CALL_LOG}")"

if [ "${git_calls}" -ne 2 ]; then
  echo "expected two git_issuer CREATE_GITLAB_ISSUE calls, got ${git_calls}" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if [ "${executor_calls}" -ne 2 ]; then
  echo "expected two executor RUN_SINGLE_ISSUE calls, got ${executor_calls}" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if grep -qx 'agent:req_executor:main' <<<"${executor_sessions}"; then
  echo "expected executor RUN_SINGLE_ISSUE calls to avoid main session" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

executor_session_count="$(printf '%s\n' "${executor_sessions}" | sort -u | wc -l | tr -d ' ')"
if [ "${executor_session_count}" -ne 2 ]; then
  echo "expected two distinct executor sessions, got ${executor_session_count}" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

if ! grep -qx 'agent:req_executor:issue-claw-gitlab-px-ifp-hulat-test-101' <<<"${executor_sessions}" ||
   ! grep -qx 'agent:req_executor:issue-claw-gitlab-px-ifp-hulat-test-102' <<<"${executor_sessions}"; then
  echo "expected executor sessions to include project and iid" >&2
  cat "${OPENCLAW_CALL_LOG}" >&2
  exit 1
fi

echo "ok wiki intake simulated flow queues issues and drains executors"
