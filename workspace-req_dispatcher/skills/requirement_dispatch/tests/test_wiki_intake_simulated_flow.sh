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
message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      target_agent="$2"
      shift 2
      ;;
    --session-id)
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

jq -nc --arg agent "${target_agent}" --arg message "${message}" \
  '{agent: $agent, message: $message}' >>"${OPENCLAW_CALL_LOG:?OPENCLAW_CALL_LOG required}"

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
    jq -nc '{status:"accepted"}'
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
  executor="$(
    PROJECT="${project}" \
    DEFAULT_EXECUTOR_AGENT="req_executor" \
    bash "${SKILL_DIR}/scripts/route_project.sh"
  )"
  correlation_id="$(
    STATE_ROOT="${STATE_ROOT}" \
    bash "${SKILL_DIR}/scripts/next_correlation_id.sh"
  )"
  executor_payload="$(
    PROJECT="${project}" \
    IID="${iid}" \
    CORRELATION_ID="${correlation_id}" \
    DISPATCHER_CALLBACK_TARGET="agent:req_dispatcher:main" \
    bash "${SKILL_DIR}/scripts/build_executor_payload.sh"
  )"
  executor_envelope="$(
    OPENCLAW_BIN="${FAKE_OPENCLAW}" \
    OPENCLAW_CALL_LOG="${OPENCLAW_CALL_LOG}" \
    ISSUE_SEQ_FILE="${ISSUE_SEQ_FILE}" \
    TARGET_AGENT="${executor}" \
    TARGET_SESSION_KEY="agent:${executor}:main" \
    RUN_ID="executor-${idx}" \
    bash "${SKILL_DIR}/scripts/run_agent_turn.sh" <<<"${executor_payload}"
  )"
  if [ "$(jq -r '.status' <<<"${executor_envelope}")" != "success" ]; then
    echo "expected executor run_agent_turn success" >&2
    printf '%s\n' "${executor_envelope}" >&2
    exit 1
  fi
done

git_calls="$(jq -r 'select(.agent=="git_issuer") | .message' "${OPENCLAW_CALL_LOG}" | grep -c '^CREATE_GITLAB_ISSUE')"
executor_calls="$(jq -r 'select(.agent=="req_executor") | .message' "${OPENCLAW_CALL_LOG}" | grep -c '^RUN_SINGLE_ISSUE')"

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

echo "ok wiki intake simulated flow creates issues and dispatches executors"
