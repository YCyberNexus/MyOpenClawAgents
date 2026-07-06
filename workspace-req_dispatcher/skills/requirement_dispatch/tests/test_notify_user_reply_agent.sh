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
  printf '%s\n' 'printf "%s\n" "$*" >> "${OPENCLAW_LOG}"'
  printf '%s\n' 'exit 0'
} > "${FAKE_BIN}/openclaw"
chmod +x "${FAKE_BIN}/openclaw"

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

echo "ok notify_user selects reply agent"
