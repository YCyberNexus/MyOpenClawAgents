#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-notify.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
OPENCLAW_LOG="${TEST_ROOT}/openclaw.args"
mkdir -p "${FAKE_BIN}"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'message="$(cat)"'
  printf '%s\n' 'expected_url="${REPLY_GATEWAY_URL:-${ZHIBAN_GATEWAY_URL:-}}"'
  printf '%s\n' 'expected_token="${REPLY_GATEWAY_TOKEN:-${ZHIBAN_GATEWAY_TOKEN:-}}"'
  printf '%s\n' '[ "${OPENCLAW_GATEWAY_URL:-}" = "${expected_url}" ] || exit 71'
  printf '%s\n' '[ "${OPENCLAW_GATEWAY_TOKEN:-}" = "${expected_token}" ] || exit 72'
  printf '%s\n' 'token_set=false'
  printf '%s\n' '[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] && token_set=true'
  printf '%s\n' 'printf -- "--agent %s --session-key %s gateway-url=%s gateway-token-set=%s force-helper=%s protocol=%s message=%s\n" "${OPENCLAW_TARGET_AGENT:-}" "${OPENCLAW_TARGET_SESSION_KEY:-}" "${OPENCLAW_GATEWAY_URL:-}" "${token_set}" "${OPENCLAW_FORCE_GATEWAY_HELPER:-}" "${OPENCLAW_GATEWAY_PROTOCOL:-}" "${message}" >> "${OPENCLAW_LOG}"'
  printf '%s\n' 'exit 0'
} > "${FAKE_BIN}/openclaw"
chmod +x "${FAKE_BIN}/openclaw"
export OPENCLAW_AGENT_TRANSPORT="${FAKE_BIN}/openclaw"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${TEST_ROOT}/state" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
EVENT="result" \
STATUS="done" \
IID="42" \
MR_URL="https://gitlab.example/mr/1" \
ORIGIN_JSON='{"channel":"wecom","user":"u1","conversation":"c1","reply_agent":"origin_reply_agent"}' \
bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify.err"

if ! grep -q -- '--agent origin_reply_agent' "${OPENCLAW_LOG}"; then
  echo "expected notify_user.sh to send to origin.reply_agent" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if grep -q -- '--agent fallback_agent' "${OPENCLAW_LOG}"; then
  echo "did not expect notify_user.sh to send to DEFAULT_REPLY_AGENT when origin.reply_agent is present" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '--session-key agent:origin_reply_agent:main' "${OPENCLAW_LOG}" \
  || ! grep -q -- 'gateway-url=ws://example.invalid:8080' "${OPENCLAW_LOG}" \
  || ! grep -q -- 'gateway-token-set=true' "${OPENCLAW_LOG}" \
  || ! grep -q -- 'force-helper=1' "${OPENCLAW_LOG}" \
  || ! grep -q -- 'protocol=4' "${OPENCLAW_LOG}"; then
  echo "expected notify_user.sh to pin the selected Gateway and force protocol 4" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

: > "${OPENCLAW_LOG}"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${TEST_ROOT}/state-fallback" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
EVENT="result" \
STATUS="done" \
IID="43" \
MR_URL="https://gitlab.example/mr/2" \
ORIGIN_JSON='{"channel":"wecom","user":"u2","conversation":"c2"}' \
bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify-fallback.err"

if ! grep -q -- '--agent fallback_agent' "${OPENCLAW_LOG}"; then
  echo "expected notify_user.sh to fall back to DEFAULT_REPLY_AGENT when origin.reply_agent is absent" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

: > "${OPENCLAW_LOG}"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${TEST_ROOT}/state-manual-no-origin" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
EVENT="result" \
STATUS="done" \
IID="46" \
MR_URL="https://gitlab.example/mr/4" \
bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify-manual-no-origin.err"

if [ -s "${OPENCLAW_LOG}" ]; then
  echo "did not expect notify_user.sh to send to DEFAULT_REPLY_AGENT when ORIGIN_JSON is empty" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! jq -e 'select(.kind=="user_notify_skipped" and .origin==null and .channel==null)' \
  "${TEST_ROOT}/state-manual-no-origin/_dispatcher/ledger.jsonl" >/dev/null; then
  echo "expected empty-origin manual entry to write a skipped ledger row with null channel" >&2
  sed -n '1,20p' "${TEST_ROOT}/state-manual-no-origin/_dispatcher/ledger.jsonl" >&2
  exit 1
fi

: > "${OPENCLAW_LOG}"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${TEST_ROOT}/state-manual-null-origin" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
EVENT="result" \
STATUS="done" \
IID="47" \
MR_URL="https://gitlab.example/mr/5" \
ORIGIN_JSON='null' \
bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify-manual-null-origin.err"

if [ -s "${OPENCLAW_LOG}" ]; then
  echo "did not expect notify_user.sh to send to DEFAULT_REPLY_AGENT when ORIGIN_JSON is null" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! jq -e 'select(.kind=="user_notify_skipped" and .origin==null and .channel==null)' \
  "${TEST_ROOT}/state-manual-null-origin/_dispatcher/ledger.jsonl" >/dev/null; then
  echo "expected null-origin manual entry to write a skipped ledger row with null channel" >&2
  sed -n '1,20p' "${TEST_ROOT}/state-manual-null-origin/_dispatcher/ledger.jsonl" >&2
  exit 1
fi

: > "${OPENCLAW_LOG}"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${TEST_ROOT}/state-legacy-zhiban" \
ZHIBAN_GATEWAY_URL="ws://legacy.example.invalid:8080" \
ZHIBAN_GATEWAY_TOKEN="legacy-token" \
ZHIBAN_AGENT="legacy_zhiban_agent" \
ZHIBAN_NOTIFY_TIMEOUT_SECONDS="5" \
EVENT="result" \
STATUS="done" \
IID="44" \
MR_URL="https://gitlab.example/mr/3" \
ORIGIN_JSON='{"channel":"wecom","user":"u3","conversation":"c3"}' \
bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify-legacy-zhiban.err"

if ! grep -q -- '--agent legacy_zhiban_agent' "${OPENCLAW_LOG}"; then
  echo "expected notify_user.sh to honor legacy ZHIBAN_* pins when REPLY_* pins are absent" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

: > "${OPENCLAW_LOG}"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${TEST_ROOT}/state-failed-ignore-wiki" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
EVENT="result" \
STATUS="failed" \
IID="45" \
WIKI_URL="https://gitlab.example/wiki/attempt-log" \
REASON="测试失败" \
ORIGIN_JSON='{"channel":"wecom","user":"u4","conversation":"c4"}' \
bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify-failed-ignore-wiki.err"

if grep -q -- '详情见' "${OPENCLAW_LOG}"; then
  echo "did not expect notify_user.sh failed content to include wiki details" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if grep -q -- 'wiki_url' "${OPENCLAW_LOG}"; then
  echo "did not expect notify_user.sh result envelope to include wiki_url" >&2
  echo "openclaw args:" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

# Exercise the production transport path with a remote-only personal agent.
# The slow helper is exec'd by the transport, so the watchdog must terminate
# the actual Gateway request process rather than leave an orphaned delivery.
SLOW_HELPER="${TEST_ROOT}/slow-gateway-helper"
SLOW_HELPER_REQUEST="${TEST_ROOT}/slow-helper.request.json"
SLOW_HELPER_PID="${TEST_ROOT}/slow-helper.pid"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'request="$(cat)"'
  printf '%s\n' '[ "${OPENCLAW_GATEWAY_URL:-}" = "ws://slow.example.invalid:8080" ] || exit 71'
  printf '%s\n' '[ "${OPENCLAW_GATEWAY_TOKEN:-}" = "slow-token" ] || exit 72'
  printf '%s\n' '[ "${OPENCLAW_FORCE_GATEWAY_HELPER:-}" = 1 ] || exit 73'
  printf '%s\n' '[ "${OPENCLAW_GATEWAY_PROTOCOL:-}" = 4 ] || exit 74'
  printf '%s\n' 'printf "%s" "${request}" >"${SLOW_HELPER_REQUEST:?}"'
  printf '%s\n' 'printf "%s\n" "$$" >"${SLOW_HELPER_PID:?}"'
  printf '%s\n' 'exec sleep 60'
} >"${SLOW_HELPER}"
chmod +x "${SLOW_HELPER}"

set +e
env -u OPENCLAW_AGENT_TRANSPORT \
  OPENCLAW_BIN="${FAKE_BIN}/openclaw" \
  OPENCLAW_GATEWAY_HELPER_BIN="${SLOW_HELPER}" \
  SLOW_HELPER_REQUEST="${SLOW_HELPER_REQUEST}" \
  SLOW_HELPER_PID="${SLOW_HELPER_PID}" \
  STATE_ROOT="${TEST_ROOT}/state-slow-helper" \
  REPLY_GATEWAY_URL="ws://slow.example.invalid:8080" \
  REPLY_GATEWAY_TOKEN="slow-token" \
  DEFAULT_REPLY_AGENT="fallback_agent" \
  REPLY_NOTIFY_TIMEOUT_SECONDS="1" \
  REPLY_NOTIFY_WATCHDOG_GRACE_SECONDS="31" \
  EVENT="result" \
  STATUS="done" \
  IID="48" \
  MR_URL="https://gitlab.example/mr/6" \
  ORIGIN_JSON='{"channel":"wecom","user":"u5","conversation":"c5","reply_agent":"zhujiaye"}' \
  bash "${SKILL_DIR}/scripts/notify_user.sh" >/dev/null 2>"${TEST_ROOT}/notify-slow-helper.err"
slow_rc=$?
set -e

if [ "${slow_rc}" -ne 0 ] \
  || [ ! -s "${SLOW_HELPER_REQUEST}" ] \
  || ! jq -e '
    .target_agent == "zhujiaye"
    and .session_key == "agent:zhujiaye:main"
    and .timeout_seconds == 1
    and (.run_id | startswith("req-notify-result-48-"))
    and ((.message | fromjson)
      | .kind == "req_result_push"
        and .iid == 48
        and .origin.reply_agent == "zhujiaye")
  ' "${SLOW_HELPER_REQUEST}" >/dev/null; then
  echo "expected production transport to preserve the remote personal-agent request" >&2
  [ -f "${SLOW_HELPER_REQUEST}" ] && sed -n '1,20p' "${SLOW_HELPER_REQUEST}" >&2
  exit 1
fi

if [ ! -s "${SLOW_HELPER_PID}" ] || kill -0 "$(cat "${SLOW_HELPER_PID}")" >/dev/null 2>&1; then
  echo "expected notify watchdog to terminate the actual Gateway helper process" >&2
  exit 1
fi

if ! jq -e 'select(.kind=="user_notify_failed" and .iid==48 and .reason=="gateway agent run timeout")' \
    "${TEST_ROOT}/state-slow-helper/_dispatcher/ledger.jsonl" >/dev/null \
  || ! jq -e 'select(.kind=="user_notify" and .iid==48 and .delivered==false)' \
    "${TEST_ROOT}/state-slow-helper/_dispatcher/log/user_notify.jsonl" >/dev/null; then
  echo "expected slow Gateway delivery to be recorded as a non-fatal timeout" >&2
  exit 1
fi

echo "ok notify_user selects reply agent"
