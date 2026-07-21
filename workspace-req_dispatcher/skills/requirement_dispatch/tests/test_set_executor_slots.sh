#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/set_executor_slots.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-slots.XXXXXX")"
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
  jq -cn --argjson slots "${FAKE_SLOTS:-7}" '{
    status:"success",exit_code:0,
    worker_result_json:{
      status:"success",parallel_project_limit:$slots,
      previous_parallel_project_limit:3,
      active_project_count:2,available_project_slots:($slots - 2),
      draining:false
    }
  }'
fi
EOF
chmod +x "${FAKE_TURN}"

success_output="$(
  MESSAGE='/slot 7' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  bash "${WRAPPER}"
)"
jq -e '
  .status == "success"
  and .parallel_project_limit == 7
  and .previous_parallel_project_limit == 3
  and .active_project_count == 2
  and .available_project_slots == 5
  and .draining == false
' <<<"${success_output}" >/dev/null
jq -e '
  .target_agent == "req_executor"
  and .target_session_key == "agent:req_executor:main"
  and .message_source == "stdin"
  and .message == "/slot 7"
' "${CAPTURE}" >/dev/null

capture_before="$(jq -cS . "${CAPTURE}")"
invalid_output="$(
  MESSAGE='/slot 0' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  bash "${WRAPPER}"
)"
jq -e '.status == "failed" and (.reason | startswith("usage:"))' \
  <<<"${invalid_output}" >/dev/null
[ "${capture_before}" = "$(jq -cS . "${CAPTURE}")" ] \
  || { echo 'invalid dispatcher /slot command reached executor transport' >&2; exit 1; }

invalid_response="$(
  MESSAGE='/slot 7' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  FAKE_MODE=invalid \
  bash "${WRAPPER}"
)"
jq -e '
  .status == "failed"
  and .reason == "executor returned an invalid slot response"
' <<<"${invalid_response}" >/dev/null

echo 'ok dispatcher slot forwarding'
