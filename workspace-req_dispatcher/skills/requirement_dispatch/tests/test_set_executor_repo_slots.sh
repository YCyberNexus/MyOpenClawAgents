#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/set_executor_repo_slots.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-repo-slots.XXXXXX")"
FAKE_TURN="${TEST_ROOT}/run-agent-turn.sh"
CAPTURE="${TEST_ROOT}/capture.json"

cat >"${FAKE_TURN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
message="$(cat)"
jq -cn \
  --arg target_agent "${TARGET_AGENT:-}" \
  --arg target_session_key "${TARGET_SESSION_KEY:-}" \
  --arg message_source "${MESSAGE_SOURCE:-}" \
  --arg message "${message}" '{
    target_agent:$target_agent,
    target_session_key:$target_session_key,
    message_source:$message_source,
    message:$message
  }' >"${CAPTURE}"
if [ "${FAKE_MODE:-success}" = invalid ]; then
  jq -cn '{status:"success",exit_code:0,worker_result_json:{status:"success"}}'
else
  jq -cn --argjson slots "${FAKE_SLOTS:-4}" '{
    status:"success",exit_code:0,
    worker_result_json:{
      status:"success",
      per_repository_issue_limit:$slots,
      previous_per_repository_issue_limit:1,
      active_repository_count:2,
      active_issue_count:3,
      over_limit_repository_count:0,
      draining:false
    }
  }'
fi
EOF
chmod +x "${FAKE_TURN}"

success_output="$(
  MESSAGE='/repo-slot 4' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  bash "${WRAPPER}"
)"
jq -e '
  .status == "success"
  and .per_repository_issue_limit == 4
  and .previous_per_repository_issue_limit == 1
  and .active_repository_count == 2
  and .active_issue_count == 3
  and .over_limit_repository_count == 0
  and .draining == false
' <<<"${success_output}" >/dev/null
jq -e '
  .target_agent == "req_executor"
  and .target_session_key == "agent:req_executor:main"
  and .message_source == "stdin"
  and .message == "/repo-slot 4"
' "${CAPTURE}" >/dev/null

capture_before="$(jq -cS . "${CAPTURE}")"
invalid_output="$(
  MESSAGE='/repo-slot 0' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  bash "${WRAPPER}"
)"
jq -e '.status == "failed" and (.reason | startswith("usage:"))' \
  <<<"${invalid_output}" >/dev/null
[ "${capture_before}" = "$(jq -cS . "${CAPTURE}")" ] \
  || { echo 'invalid dispatcher /repo-slot command reached transport' >&2; exit 1; }

invalid_response="$(
  MESSAGE='/repo-slot 4' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  FAKE_MODE=invalid \
  bash "${WRAPPER}"
)"
jq -e '
  .status == "failed"
  and .reason == "executor returned an invalid repository slot response"
' <<<"${invalid_response}" >/dev/null

echo 'ok dispatcher per-repository Issue slot forwarding'
