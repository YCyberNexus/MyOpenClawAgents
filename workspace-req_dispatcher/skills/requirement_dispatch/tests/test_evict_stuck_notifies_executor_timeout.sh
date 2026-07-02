#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-evict-notify.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
OPENCLAW_LOG="${TEST_ROOT}/openclaw.args"
STATE_ROOT="${TEST_ROOT}/state"
DISPATCHER_DIR="${STATE_ROOT}/_dispatcher"

mkdir -p "${FAKE_BIN}" "${DISPATCHER_DIR}"

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\n" "$*" >> "${OPENCLAW_LOG}"'
  printf '%s\n' 'exit "${FAKE_OPENCLAW_RC:-0}"'
} > "${FAKE_BIN}/openclaw"
chmod +x "${FAKE_BIN}/openclaw"

old_ts="$(( $(date -u +%s) - 7200 ))"
jq -n --argjson ts "${old_ts}" \
  '{
    pending: {
      "run-executor-origin": {
        run_id: "run-executor-origin",
        stage: "executor",
        origin: {
          channel: "wecom",
          user: "u1",
          conversation: "c1",
          reply_agent: "origin_reply_agent"
        },
        project: "group/project",
        iid: 42,
        correlation_id: "corr-42",
        child_session_key: "child-42",
        spawned_at: $ts,
        req_digest: "demo requirement"
      },
      "run-git-issuer-origin": {
        run_id: "run-git-issuer-origin",
        stage: "git_issuer",
        origin: {
          channel: "wecom",
          user: "u2",
          conversation: "c2",
          reply_agent: "git_issuer_reply_agent"
        },
        project: null,
        iid: null,
        correlation_id: null,
        child_session_key: "child-issuer",
        spawned_at: $ts,
        req_digest: "issuer requirement"
      },
      "run-executor-no-origin": {
        run_id: "run-executor-no-origin",
        stage: "executor",
        origin: null,
        project: "group/project",
        iid: 43,
        correlation_id: "corr-43",
        child_session_key: "child-43",
        spawned_at: $ts,
        req_digest: "no origin requirement"
      }
    }
  }' > "${DISPATCHER_DIR}/pending.json"
: > "${DISPATCHER_DIR}/ledger.jsonl"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${STATE_ROOT}" \
STUCK_AFTER_MINUTES="1" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
bash "${SKILL_DIR}/scripts/evict_stuck.sh" >/dev/null

if ! jq -e '.pending == {}' "${DISPATCHER_DIR}/pending.json" >/dev/null; then
  echo "expected evict_stuck.sh to delete all expired pending entries" >&2
  jq . "${DISPATCHER_DIR}/pending.json" >&2
  exit 1
fi

for expected_run_id in run-executor-origin run-git-issuer-origin run-executor-no-origin; do
  if ! jq -e --arg rid "${expected_run_id}" \
    'select(.run_id==$rid and .outcome=="stuck_evicted" and .was_pending==true)' \
    "${DISPATCHER_DIR}/ledger.jsonl" >/dev/null; then
    echo "expected stuck_evicted ledger row for ${expected_run_id}" >&2
    sed -n '1,20p' "${DISPATCHER_DIR}/ledger.jsonl" >&2
    exit 1
  fi
done

if ! jq -e 'select(.run_id=="run-executor-origin" and .stage=="executor" and .project=="group/project" and .issue_iid==42)' \
  "${DISPATCHER_DIR}/ledger.jsonl" >/dev/null; then
  echo "expected executor stuck_evicted ledger row to preserve project and iid" >&2
  sed -n '1,20p' "${DISPATCHER_DIR}/ledger.jsonl" >&2
  exit 1
fi

openclaw_lines="$(wc -l < "${OPENCLAW_LOG}")"
if [ "${openclaw_lines}" -ne 1 ]; then
  echo "expected exactly one user notification for executor entry with origin; got ${openclaw_lines}" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '--agent origin_reply_agent' "${OPENCLAW_LOG}"; then
  echo "expected evict_stuck.sh to notify origin.reply_agent for executor stuck timeout" >&2
  [ -f "${OPENCLAW_LOG}" ] && sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '"status":"timeout"' "${OPENCLAW_LOG}"; then
  echo "expected timeout status in user notification envelope" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '#42 处理超时未完成，已停放待人工处理' "${OPENCLAW_LOG}"; then
  echo "expected human timeout content in user notification envelope" >&2
  sed -n '1,20p' "${OPENCLAW_LOG}" >&2
  exit 1
fi

FAIL_STATE_ROOT="${TEST_ROOT}/state-notify-fails"
FAIL_DISPATCHER_DIR="${FAIL_STATE_ROOT}/_dispatcher"
mkdir -p "${FAIL_DISPATCHER_DIR}"

jq -n --argjson ts "${old_ts}" \
  '{
    pending: {
      "run-executor-notify-fails": {
        run_id: "run-executor-notify-fails",
        stage: "executor",
        origin: {
          channel: "wecom",
          user: "u4",
          conversation: "c4",
          reply_agent: "origin_reply_agent"
        },
        project: "group/project",
        iid: 44,
        correlation_id: "corr-44",
        child_session_key: "child-44",
        spawned_at: $ts,
        req_digest: "notify failure requirement"
      }
    }
  }' > "${FAIL_DISPATCHER_DIR}/pending.json"
: > "${FAIL_DISPATCHER_DIR}/ledger.jsonl"

set +e
PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
STATE_ROOT="${FAIL_STATE_ROOT}" \
STUCK_AFTER_MINUTES="1" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="0" \
bash "${SKILL_DIR}/scripts/evict_stuck.sh" >/dev/null 2>"${TEST_ROOT}/evict-notify-fails.err"
evict_rc=$?
set -e

if [ "${evict_rc}" -ne 0 ]; then
  echo "expected evict_stuck.sh to keep eviction successful when notify_user.sh fails" >&2
  sed -n '1,20p' "${TEST_ROOT}/evict-notify-fails.err" >&2
  exit 1
fi

if ! jq -e '.pending == {}' "${FAIL_DISPATCHER_DIR}/pending.json" >/dev/null; then
  echo "expected notify failure case to still delete expired pending" >&2
  jq . "${FAIL_DISPATCHER_DIR}/pending.json" >&2
  exit 1
fi

if ! jq -e 'select(.run_id=="run-executor-notify-fails" and .outcome=="stuck_evicted" and .stage=="executor")' \
  "${FAIL_DISPATCHER_DIR}/ledger.jsonl" >/dev/null; then
  echo "expected notify failure case to still write stuck_evicted ledger row" >&2
  sed -n '1,20p' "${FAIL_DISPATCHER_DIR}/ledger.jsonl" >&2
  exit 1
fi

if ! grep -q -- 'notify_user timeout push failed' "${TEST_ROOT}/evict-notify-fails.err"; then
  echo "expected evict_stuck.sh to report non-fatal notify_user failure" >&2
  sed -n '1,20p' "${TEST_ROOT}/evict-notify-fails.err" >&2
  exit 1
fi

OPENCLAW_FAIL_STATE_ROOT="${TEST_ROOT}/state-openclaw-fails"
OPENCLAW_FAIL_DISPATCHER_DIR="${OPENCLAW_FAIL_STATE_ROOT}/_dispatcher"
mkdir -p "${OPENCLAW_FAIL_DISPATCHER_DIR}"

jq -n --argjson ts "${old_ts}" \
  '{
    pending: {
      "run-executor-openclaw-fails": {
        run_id: "run-executor-openclaw-fails",
        stage: "executor",
        origin: {
          channel: "wecom",
          user: "u5",
          conversation: "c5",
          reply_agent: "origin_reply_agent"
        },
        project: "group/project",
        iid: 45,
        correlation_id: "corr-45",
        child_session_key: "child-45",
        spawned_at: $ts,
        req_digest: "openclaw failure requirement"
      }
    }
  }' > "${OPENCLAW_FAIL_DISPATCHER_DIR}/pending.json"
: > "${OPENCLAW_FAIL_DISPATCHER_DIR}/ledger.jsonl"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLAW_LOG="${OPENCLAW_LOG}" \
FAKE_OPENCLAW_RC="7" \
STATE_ROOT="${OPENCLAW_FAIL_STATE_ROOT}" \
STUCK_AFTER_MINUTES="1" \
REPLY_GATEWAY_URL="ws://example.invalid:8080" \
REPLY_GATEWAY_TOKEN="token" \
DEFAULT_REPLY_AGENT="fallback_agent" \
REPLY_NOTIFY_TIMEOUT_SECONDS="5" \
bash "${SKILL_DIR}/scripts/evict_stuck.sh" >/dev/null 2>"${TEST_ROOT}/evict-openclaw-fails.err"

if ! jq -e '.pending == {}' "${OPENCLAW_FAIL_DISPATCHER_DIR}/pending.json" >/dev/null; then
  echo "expected openclaw failure case to still delete expired pending" >&2
  jq . "${OPENCLAW_FAIL_DISPATCHER_DIR}/pending.json" >&2
  exit 1
fi

if ! jq -e 'select(.run_id=="run-executor-openclaw-fails" and .outcome=="stuck_evicted" and .stage=="executor")' \
  "${OPENCLAW_FAIL_DISPATCHER_DIR}/ledger.jsonl" >/dev/null; then
  echo "expected openclaw failure case to still write stuck_evicted ledger row" >&2
  sed -n '1,20p' "${OPENCLAW_FAIL_DISPATCHER_DIR}/ledger.jsonl" >&2
  exit 1
fi

if ! jq -e 'select(.kind=="user_notify_failed" and .status=="timeout" and .iid==45 and .reason=="gateway agent run non-zero")' \
  "${OPENCLAW_FAIL_DISPATCHER_DIR}/ledger.jsonl" >/dev/null; then
  echo "expected openclaw failure case to write user_notify_failed ledger row" >&2
  sed -n '1,20p' "${OPENCLAW_FAIL_DISPATCHER_DIR}/ledger.jsonl" >&2
  exit 1
fi

echo "ok evict_stuck notifies executor timeout"
