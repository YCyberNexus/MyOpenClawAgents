#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WRAPPER="${SKILL_DIR}/scripts/set_executor_acpx_timeout.sh"
TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-dispatcher-acpx-timeout.XXXXXX")"
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
    target_agent:$target_agent,target_session_key:$target_session_key,
    message_source:$message_source,message:$message
  }' >"${CAPTURE}"
if [ "${FAKE_MODE:-success}" = invalid ]; then
  jq -cn '{status:"success",exit_code:0,worker_result_json:{status:"success"}}'
else
  jq -cn --argjson timeout "${FAKE_TIMEOUT:-3600}" '{
    status:"success",exit_code:0,
    worker_result_json:{
      status:"success",acpx_timeout_seconds:$timeout,
      previous_acpx_timeout_seconds:18000,
      executor_agent_timeout_seconds:($timeout + 3600),
      exec_tool_timeout_seconds:($timeout + 3900),
      queue_launch_reclaim_seconds:($timeout + 4200),
      stuck_after_minutes:(((($timeout + 4200 + 59) / 60) | floor) + 20),
      active_count:2,
      applies_to:"future_attempts"
    }
  }'
fi
EOF
chmod +x "${FAKE_TURN}"

success_output="$(
  MESSAGE='/timeout-executor 1h' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  bash "${WRAPPER}"
)"
jq -e '
  .status == "success"
  and .acpx_timeout_seconds == 3600
  and .previous_acpx_timeout_seconds == 18000
  and .executor_agent_timeout_seconds == 7200
  and .exec_tool_timeout_seconds == 7500
  and .queue_launch_reclaim_seconds == 7800
  and .stuck_after_minutes == 150
  and .active_count == 2
  and .applies_to == "future_attempts"
' <<<"${success_output}" >/dev/null
jq -e '
  .target_agent == "req_executor"
  and .target_session_key == "agent:req_executor:main"
  and .message_source == "stdin"
  and .message == "/timeout-executor 3600"
' "${CAPTURE}" >/dev/null

capture_before="$(jq -cS . "${CAPTURE}")"
invalid_output="$(
  MESSAGE='/timeout-executor 30s' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  bash "${WRAPPER}"
)"
jq -e '.status == "failed"' <<<"${invalid_output}" >/dev/null
[ "${capture_before}" = "$(jq -cS . "${CAPTURE}")" ] \
  || { echo 'invalid timeout command reached executor transport' >&2; exit 1; }

for legacy_command in '/acpx-timeout 1h' '/executor-timeout 1h'; do
  legacy_name_output="$(
    MESSAGE="${legacy_command}" \
    DEFAULT_EXECUTOR_AGENT=req_executor \
    RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
    CAPTURE="${CAPTURE}" \
    bash "${WRAPPER}"
  )"
  jq -e '.status == "failed"' <<<"${legacy_name_output}" >/dev/null
  [ "${capture_before}" = "$(jq -cS . "${CAPTURE}")" ] \
    || { echo 'legacy timeout command reached executor transport' >&2; exit 1; }
done

invalid_response="$(
  MESSAGE='/timeout-executor 1h' \
  DEFAULT_EXECUTOR_AGENT=req_executor \
  RUN_AGENT_TURN_CMD="${FAKE_TURN}" \
  CAPTURE="${CAPTURE}" \
  FAKE_MODE=invalid \
  bash "${WRAPPER}"
)"
jq -e '
  .status == "failed"
  and .reason == "executor returned an invalid acpx timeout response"
' <<<"${invalid_response}" >/dev/null

echo 'ok dispatcher acpx timeout forwarding'
