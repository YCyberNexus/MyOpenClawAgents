#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMIT_SCRIPT="$(cd "${SCRIPT_DIR}/.." && pwd)/send_req_dispatcher_from_114.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/send-req-dispatcher-test.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
CURL_REQUEST_LOG="${TEST_ROOT}/curl-request.json"
CURL_ARGS_LOG="${TEST_ROOT}/curl-args.txt"
mkdir -p "${FAKE_BIN}"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'request="$(cat)"'
  printf '%s\n' 'printf "%s" "${request}" >"${CURL_REQUEST_LOG:?}"'
  printf '%s\n' 'printf "%s\n" "$@" >"${CURL_ARGS_LOG:?}"'
  printf '%s\n' 'printf "%s\n" "{\"id\":\"chatcmpl-test\",\"object\":\"chat.completion\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"需求已受理\"},\"finish_reason\":\"stop\"}]}"'
} >"${FAKE_BIN}/curl"
chmod +x "${FAKE_BIN}/curl"

response="$(
  PATH="${FAKE_BIN}:${PATH}" \
  CURL_REQUEST_LOG="${CURL_REQUEST_LOG}" \
  CURL_ARGS_LOG="${CURL_ARGS_LOG}" \
  REQ_DISPATCHER_GATEWAY_TOKEN="gateway-token-not-for-argv" \
  REQ_DISPATCHER_GATEWAY_URL="http://10.64.5.104:18789/v1/chat/completions" \
  CURRENT_AGENT_NAME="zhujiaye" \
  WECHAT_USER_ID="wm-user-123" \
  WECHAT_CONVERSATION_ID="conv-456" \
  TASK_DESCRIPTION="处理 group/project 的 #42" \
  "${BASH}" "${SUBMIT_SCRIPT}"
)"

if ! jq -e '
  .model == "openclaw/req_dispatcher"
  and .stream == false
  and (.messages | length) == 1
  and .messages[0].role == "user"
  and (.messages[0].content | startswith(
    "[origin] {\"channel\":\"wecom\",\"user\":\"wm-user-123\",\"conversation\":\"conv-456\",\"reply_agent\":\"zhujiaye\",\"source_agent\":\"zhujiaye\",\"source_session\":\"agent:zhujiaye:main\"}\n"
  ))
  and (has("tool") | not)
  and (has("sessionKey") | not)
' "${CURL_REQUEST_LOG}" >/dev/null; then
  echo "expected a direct req_dispatcher Chat Completions request" >&2
  sed -n '1,20p' "${CURL_REQUEST_LOG}" >&2
  exit 1
fi

if ! grep -Fxq -- 'x-openclaw-agent-id: req_dispatcher' "${CURL_ARGS_LOG}" \
  || ! grep -Fxq -- 'x-openclaw-session-key: agent:req_dispatcher:main' "${CURL_ARGS_LOG}" \
  || ! grep -Fxq -- 'http://10.64.5.104:18789/v1/chat/completions' "${CURL_ARGS_LOG}"; then
  echo "expected fixed req_dispatcher routing headers and Chat Completions endpoint" >&2
  sed -n '1,40p' "${CURL_ARGS_LOG}" >&2
  exit 1
fi

if grep -Eq -- 'sessions_send|/tools/invoke' "${CURL_ARGS_LOG}" \
  || grep -q -- 'sessions_send' "${CURL_REQUEST_LOG}"; then
  echo "sessions_send must not be used because it starts A2A announce" >&2
  exit 1
fi

if grep -q -- 'gateway-token-not-for-argv' "${CURL_ARGS_LOG}"; then
  echo "gateway token leaked into curl argv" >&2
  exit 1
fi

if [ "${response}" != '{"id":"chatcmpl-test","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"需求已受理"},"finish_reason":"stop"}]}' ]; then
  echo "expected the 104 HTTP response to be returned unchanged" >&2
  printf '%s\n' "${response}" >&2
  exit 1
fi

set +e
legacy_endpoint_output="$(
  PATH="${FAKE_BIN}:${PATH}" \
  CURL_REQUEST_LOG="${CURL_REQUEST_LOG}" \
  CURL_ARGS_LOG="${CURL_ARGS_LOG}" \
  REQ_DISPATCHER_GATEWAY_TOKEN="gateway-token-not-for-argv" \
  REQ_DISPATCHER_GATEWAY_URL="http://10.64.5.104:18789/tools/invoke" \
  CURRENT_AGENT_NAME="zhujiaye" \
  WECHAT_USER_ID="wm-user-123" \
  WECHAT_CONVERSATION_ID="conv-456" \
  TASK_DESCRIPTION="不应提交" \
  "${BASH}" "${SUBMIT_SCRIPT}" 2>&1
)"
legacy_endpoint_rc=$?
set -e

if [ "${legacy_endpoint_rc}" -ne 64 ] \
  || ! printf '%s' "${legacy_endpoint_output}" \
    | grep -Fq -- 'must end with /v1/chat/completions'; then
  echo "expected the legacy /tools/invoke endpoint to be rejected" >&2
  printf '%s\n' "${legacy_endpoint_output}" >&2
  exit 1
fi

echo "ok send_req_dispatcher uses a non-delivering direct agent request"
