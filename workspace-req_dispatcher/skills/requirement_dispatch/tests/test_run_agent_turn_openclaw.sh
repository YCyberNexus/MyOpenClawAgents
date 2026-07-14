#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-run-agent.XXXXXX")"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_LOG="${TEST_ROOT}/openclaw.args"
OPENCLAW_STDIN_LOG="${TEST_ROOT}/openclaw.stdin"
SECRET_NONCE='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
export OPENCLAW_AGENT_HELP_OVERRIDE=$'Options:\n  --session-key <key>  exact key\n  --session-id <id>  exact id\n  --message-file <path>  stdin-safe message'
export OPENCLAW_STATE_DIR="${TEST_ROOT}/state"
mkdir -p "${OPENCLAW_STATE_DIR}/agents/git_issuer/sessions"
cat >"${OPENCLAW_STATE_DIR}/agents/git_issuer/sessions/sessions.json" <<'EOF'
{"agent:git_issuer:legacy":{"sessionId":"12345"}}
EOF

cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OPENCLAW_LOG}"
cat >"${OPENCLAW_STDIN_LOG}"
printf '%s\n' 'accepted'
printf '%s\n' '{"status":"success","project":"ai-infra/veqp_server_v3","issue_iid":7,"issue_url":"https://gitlab.example/issues/7"}'
EOF
chmod +x "${FAKE_OPENCLAW}"

result="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  OPENCLAW_STDIN_LOG="${OPENCLAW_STDIN_LOG}" \
  RUN_ID="run-git-1" \
  TARGET_AGENT="git_issuer" \
  TARGET_SESSION_KEY="agent:git_issuer:main" \
  AGENT_TIMEOUT_SECONDS="120" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh" <<'EOF'
create issue for ai-infra/veqp_server_v3
callback_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
)"

if ! grep -q -- 'agent --agent git_issuer --session-key agent:git_issuer:main' "${OPENCLAW_LOG}"; then
  echo "expected wrapper to call openclaw agent with target and session key" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '--message-file /dev/stdin' "${OPENCLAW_LOG}" \
  || grep -q -- "${SECRET_NONCE}" "${OPENCLAW_LOG}"; then
  echo "expected wrapper to keep the nonce out of argv and select /dev/stdin" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

expected_stdin="$(printf 'create issue for ai-infra/veqp_server_v3\ncallback_nonce=%s\n' "${SECRET_NONCE}")"
if [ "$(<"${OPENCLAW_STDIN_LOG}")" != "${expected_stdin}" ]; then
  echo "expected fake openclaw to receive the complete message only on stdin" >&2
  exit 1
fi

status="$(printf '%s' "${result}" | jq -r '.status')"
run_id="$(printf '%s' "${result}" | jq -r '.run_id')"
project="$(printf '%s' "${result}" | jq -r '.worker_result_json.project')"

if [ "${status}" != "success" ] || [ "${run_id}" != "run-git-1" ] || [ "${project}" != "ai-infra/veqp_server_v3" ]; then
  echo "unexpected wrapper envelope:" >&2
  printf '%s\n' "${result}" >&2
  exit 1
fi

cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OPENCLAW_LOG}"
printf '%s\n' 'Issue 已创建成功:'
printf '%s\n' '```json'
printf '%s\n' '{'
printf '%s\n' '  "status": "success",'
printf '%s\n' '  "project": "ai-infra/veqp_server_v3",'
printf '%s\n' '  "issue_iid": 10,'
printf '%s\n' '  "issue_url": "https://gitlab.example/issues/10"'
printf '%s\n' '}'
printf '%s\n' '```'
printf '%s\n' '汇总：已创建 issue。'
EOF
chmod +x "${FAKE_OPENCLAW}"

pretty_fenced="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-pretty-fenced" \
  TARGET_AGENT="git_issuer" \
  MESSAGE="create issue with pretty fenced json" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if [ "$(printf '%s' "${pretty_fenced}" | jq -r '.worker_result_json.issue_iid // empty')" != "10" ]; then
  echo "expected wrapper to parse pretty JSON inside a markdown code fence:" >&2
  printf '%s\n' "${pretty_fenced}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
numeric_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-numeric" \
  TARGET_AGENT="git_issuer" \
  TARGET_SESSION_ID="12345" \
  MESSAGE="create issue with deprecated explicit session id" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if ! grep -q -- 'agent --session-id 12345' "${OPENCLAW_LOG}" \
    || grep -q -- 'agent --agent git_issuer --session-id 12345' "${OPENCLAW_LOG}"; then
  echo "expected actual TARGET_SESSION_ID to omit --agent and keep id semantics" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${numeric_session}" | jq -r '.status')" != "success" ]; then
  echo "expected deprecated numeric session id call to succeed:" >&2
  printf '%s\n' "${numeric_session}" >&2
  exit 1
fi

if [ "$(printf '%s' "${numeric_session}" | jq -r '.target_session_id')" != "12345" ] \
    || [ "$(printf '%s' "${numeric_session}" | jq -r '.child_session_key')" != "null" ]; then
  echo "expected session id and session key to remain distinct in the envelope" >&2
  printf '%s\n' "${numeric_session}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
timeout_floor="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-timeout-floor" \
  TARGET_AGENT="git_issuer" \
  TARGET_SESSION_KEY="agent:git_issuer:main" \
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="240" \
  AGENT_TIMEOUT_SECONDS="30" \
  MESSAGE="create issue with protected downstream timeout" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if ! grep -q -- '--timeout 240' "${OPENCLAW_LOG}"; then
  echo "expected DOWNSTREAM_AGENT_TIMEOUT_SECONDS to protect against shorter per-call timeout" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${timeout_floor}" | jq -r '.status')" != "success" ]; then
  echo "expected protected timeout call to succeed:" >&2
  printf '%s\n' "${timeout_floor}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
executor_default_timeout="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-default-timeout" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="10800" \
  MESSAGE="run single issue with executor timeout" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if ! grep -q -- '--timeout 10800' "${OPENCLAW_LOG}"; then
  echo "expected EXECUTOR_AGENT_TIMEOUT_SECONDS to apply to executor target" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${executor_default_timeout}" | jq -r '.status')" != "success" ]; then
  echo "expected executor timeout default call to succeed:" >&2
  printf '%s\n' "${executor_default_timeout}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
executor_issue_scoped_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-issue-session" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="10800" \
  MESSAGE='RUN_SINGLE_ISSUE
project=ai-infra/veqp_server_v3
iid=11
correlation_id=reqd-9
dispatcher_callback_target=agent:req_dispatcher:main' \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

expected_issue_session="agent:req_executor:issue-ai-infra-veqp-server-v3-11"
if ! grep -q -- "agent --agent req_executor --session-key ${expected_issue_session}" "${OPENCLAW_LOG}"; then
  echo "expected executor RUN_SINGLE_ISSUE to use issue-scoped session key" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${executor_issue_scoped_session}" | jq -r '.child_session_key')" != "${expected_issue_session}" ]; then
  echo "expected issue-scoped session key in wrapper envelope:" >&2
  printf '%s\n' "${executor_issue_scoped_session}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
executor_batch_scoped_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-batch-session" \
  TARGET_AGENT="req_executor" \
  TARGET_SESSION_KEY="agent:req_executor:main" \
  GIT_ISSUER_AGENT="git_issuer" \
  MESSAGE='RUN_DRIVEN_ISSUE_BATCH
batch_id=reqd-batch-17
correlation_id=reqd-17
project=ai-infra/veqp_server_v3
executor_agent=req_executor
selector_type=single
iid=17
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
callback_nonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

expected_batch_session="agent:req_executor:batch-reqd-batch-17-a0fab1377f49a759b57f63318262ebe89fabfc990e8e93ceac2984561482b9d4"
if ! grep -q -- "agent --agent req_executor --session-key ${expected_batch_session}" \
    "${OPENCLAW_LOG}"; then
  echo "expected RUN_DRIVEN_ISSUE_BATCH to use a batch-scoped session key" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi
if [ "$(printf '%s' "${executor_batch_scoped_session}" | jq -r '.child_session_key')" != \
    "${expected_batch_session}" ]; then
  echo "expected batch-scoped session key in wrapper envelope" >&2
  exit 1
fi

# 新 STATE_ROOT 会让 batch_id 从同一个值重新计数；不同持久化 nonce 必须隔离历史 session。
: >"${OPENCLAW_LOG}"
executor_restarted_state_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-batch-restarted-state" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  MESSAGE='RUN_DRIVEN_ISSUE_BATCH
batch_id=reqd-batch-17
correlation_id=reqd-17
project=ai-infra/veqp_server_v3
executor_agent=req_executor
selector_type=single
iid=17
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
callback_nonce=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

expected_restarted_state_session="agent:req_executor:batch-reqd-batch-17-52b6419d27bd7f547cee3b92f8c17a908b8a49601ecbec161e5030de1dfe9e0a"
if [ "$(printf '%s' "${executor_restarted_state_session}" | jq -r '.child_session_key')" != \
    "${expected_restarted_state_session}" ]; then
  echo "expected a fresh nonce to isolate a restarted STATE_ROOT batch session" >&2
  printf '%s\n' "${executor_restarted_state_session}" >&2
  exit 1
fi
if [ "${expected_restarted_state_session}" = "${expected_batch_session}" ]; then
  echo "expected identical batch ids with different nonces to use different sessions" >&2
  exit 1
fi

# 同一持久化 outbox 重试会携带相同 nonce，因此必须保持同一 session key。
: >"${OPENCLAW_LOG}"
executor_batch_retry_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-batch-retry" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  MESSAGE='RUN_DRIVEN_ISSUE_BATCH
batch_id=reqd-batch-17
correlation_id=reqd-17
project=ai-infra/veqp_server_v3
executor_agent=req_executor
selector_type=single
iid=17
force_rerun_pr=false
dispatcher_callback_target=agent:req_dispatcher:main
callback_nonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"
if [ "$(printf '%s' "${executor_batch_retry_session}" | jq -r '.child_session_key')" != \
    "${expected_batch_session}" ]; then
  echo "expected a retry with the persisted nonce to reuse its batch session" >&2
  exit 1
fi

# 合法 batch_id 最长可达 128 字符；生成的 OpenClaw session 名称部分不得超过 128。
long_batch_id="$(printf '%0128d' 0 | tr '0' 'b')"
long_batch_message="$(printf '%s\n' \
  'RUN_DRIVEN_ISSUE_BATCH' \
  "batch_id=${long_batch_id}" \
  'correlation_id=reqd-long' \
  'project=ai-infra/veqp_server_v3' \
  'executor_agent=req_executor' \
  'selector_type=single' \
  'iid=17' \
  'force_rerun_pr=false' \
  'dispatcher_callback_target=agent:req_dispatcher:main' \
  'callback_nonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')"
: >"${OPENCLAW_LOG}"
executor_long_batch_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-long-batch-id" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  MESSAGE="${long_batch_message}" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"
long_batch_session_key="$(printf '%s' "${executor_long_batch_session}" | jq -r '.child_session_key')"
long_batch_session_name="${long_batch_session_key#agent:req_executor:}"
expected_long_batch_fragment="$(printf '%057d' 0 | tr '0' 'b')"
expected_long_batch_session="agent:req_executor:batch-${expected_long_batch_fragment}-a0fab1377f49a759b57f63318262ebe89fabfc990e8e93ceac2984561482b9d4"
if [ "${#long_batch_session_name}" -gt 128 ]; then
  echo "expected long batch session name to stay within 128 characters" >&2
  printf '%s\n' "${long_batch_session_key}" >&2
  exit 1
fi
if [ "${long_batch_session_key}" != "${expected_long_batch_session}" ]; then
  echo "expected a 128-character batch id to use the bounded readable prefix" >&2
  printf '%s\n' "${long_batch_session_key}" >&2
  exit 1
fi

# 升级前无 callback_nonce 的持久化批次必须继续命中原来的 96 字符旧 session key。
legacy_long_batch_message="$(printf '%s\n' \
  'RUN_DRIVEN_ISSUE_BATCH' \
  "batch_id=${long_batch_id}" \
  'correlation_id=reqd-legacy-long' \
  'project=ai-infra/veqp_server_v3' \
  'executor_agent=req_executor' \
  'selector_type=single' \
  'iid=17' \
  'force_rerun_pr=false' \
  'dispatcher_callback_target=agent:req_dispatcher:main')"
: >"${OPENCLAW_LOG}"
executor_legacy_long_batch_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-legacy-long-batch-id" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  MESSAGE="${legacy_long_batch_message}" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"
legacy_long_batch_session_key="$(printf '%s' "${executor_legacy_long_batch_session}" | jq -r '.child_session_key')"
expected_legacy_long_fragment="$(printf '%096d' 0 | tr '0' 'b')"
expected_legacy_long_batch_session="agent:req_executor:batch-${expected_legacy_long_fragment}"
if [ "${legacy_long_batch_session_key}" != "${expected_legacy_long_batch_session}" ]; then
  echo "expected a legacy 128-character batch id to retain its original 96-character prefix" >&2
  printf '%s\n' "${legacy_long_batch_session_key}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
executor_explicit_main_session="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-explicit-main-session" \
  TARGET_AGENT="req_executor" \
  TARGET_SESSION_KEY="agent:req_executor:main" \
  GIT_ISSUER_AGENT="git_issuer" \
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="10800" \
  MESSAGE='RUN_SINGLE_ISSUE
project=ai-infra/veqp_server_v3
iid=11
correlation_id=reqd-9
dispatcher_callback_target=agent:req_dispatcher:main' \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if grep -q -- 'agent --agent req_executor --session-key agent:req_executor:main' "${OPENCLAW_LOG}"; then
  echo "expected explicit main session override to be ignored for executor RUN_SINGLE_ISSUE" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- "agent --agent req_executor --session-key ${expected_issue_session}" "${OPENCLAW_LOG}"; then
  echo "expected executor RUN_SINGLE_ISSUE with explicit main override to use issue-scoped session key" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${executor_explicit_main_session}" | jq -r '.child_session_key')" != "${expected_issue_session}" ]; then
  echo "expected issue-scoped session key in explicit-main wrapper envelope:" >&2
  printf '%s\n' "${executor_explicit_main_session}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
executor_timeout_floor="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-executor-timeout-floor" \
  TARGET_AGENT="req_executor" \
  GIT_ISSUER_AGENT="git_issuer" \
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="10800" \
  AGENT_TIMEOUT_SECONDS="120" \
  MESSAGE="run single issue with protected executor timeout" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if ! grep -q -- '--timeout 10800' "${OPENCLAW_LOG}"; then
  echo "expected EXECUTOR_AGENT_TIMEOUT_SECONDS to protect against shorter executor timeout" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${executor_timeout_floor}" | jq -r '.status')" != "success" ]; then
  echo "expected protected executor timeout call to succeed:" >&2
  printf '%s\n' "${executor_timeout_floor}" >&2
  exit 1
fi

: >"${OPENCLAW_LOG}"
git_issuer_keeps_downstream_timeout="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-keeps-downstream-timeout" \
  TARGET_AGENT="git_issuer" \
  GIT_ISSUER_AGENT="git_issuer" \
  DOWNSTREAM_AGENT_TIMEOUT_SECONDS="600" \
  EXECUTOR_AGENT_TIMEOUT_SECONDS="10800" \
  MESSAGE="create issue without executor timeout" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if ! grep -q -- '--timeout 600' "${OPENCLAW_LOG}"; then
  echo "expected git_issuer target to keep DOWNSTREAM_AGENT_TIMEOUT_SECONDS" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${git_issuer_keeps_downstream_timeout}" | jq -r '.status')" != "success" ]; then
  echo "expected git_issuer timeout call to succeed:" >&2
  printf '%s\n' "${git_issuer_keeps_downstream_timeout}" >&2
  exit 1
fi

set +e
bad_session_output="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  TARGET_AGENT="git_issuer" \
  TARGET_SESSION_KEY="agent:…main" \
  MESSAGE="create issue with invalid session key" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh" 2>&1
)"
bad_session_code=$?
set -e

if [ "${bad_session_code}" -ne 2 ] || ! grep -q 'TARGET_SESSION_KEY must not contain placeholder ellipsis' <<<"${bad_session_output}"; then
  echo "expected placeholder session key to fail before calling openclaw" >&2
  printf 'code=%s\n%s\n' "${bad_session_code}" "${bad_session_output}" >&2
  exit 1
fi

cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
sleep 2
printf '%s\n' '{"status":"success","project":"ai-infra/veqp_server_v3","issue_iid":8,"issue_url":"https://gitlab.example/issues/8"}'
EOF
chmod +x "${FAKE_OPENCLAW}"

heartbeat_stderr="${TEST_ROOT}/heartbeat.stderr"
heartbeat_result="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-heartbeat" \
  RUN_AGENT_TURN_HEARTBEAT_SECONDS="1" \
  TARGET_AGENT="git_issuer" \
  MESSAGE="create issue with heartbeat" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh" 2>"${heartbeat_stderr}"
)"

if ! grep -q 'run_agent_turn: waiting for git_issuer' "${heartbeat_stderr}"; then
  echo "expected heartbeat on stderr while downstream agent is still running" >&2
  cat "${heartbeat_stderr}" >&2
  exit 1
fi

if [ "$(printf '%s' "${heartbeat_result}" | jq -r '.worker_result_json.issue_iid')" != "8" ]; then
  echo "expected heartbeat run to keep stdout as final JSON envelope:" >&2
  printf '%s\n' "${heartbeat_result}" >&2
  exit 1
fi

raw_temp_root="${TEST_ROOT}/raw-temp"
mkdir -p "${raw_temp_root}"
cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'sensitive downstream output'
printf '%s\n' '{"status":"success","project":"ai-infra/veqp_server_v3","issue_iid":9,"issue_url":"https://gitlab.example/issues/9"}'
EOF
chmod +x "${FAKE_OPENCLAW}"

raw_cleanup_result="$(
  TMPDIR="${raw_temp_root}" \
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  RUN_ID="run-git-raw-cleanup" \
  TARGET_AGENT="git_issuer" \
  MESSAGE="create issue with raw cleanup" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if [ "$(printf '%s' "${raw_cleanup_result}" | jq -r '.worker_result_json.issue_iid')" != "9" ]; then
  echo "expected raw cleanup run to parse worker JSON:" >&2
  printf '%s\n' "${raw_cleanup_result}" >&2
  exit 1
fi

for raw_file in "${raw_temp_root}"/req-dispatcher-run-agent-output.*; do
  [ -e "${raw_file}" ] || continue
  if [ -s "${raw_file}" ]; then
    echo "expected auto-created raw output temp file to be truncated after capture: ${raw_file}" >&2
    cat "${raw_file}" >&2
    exit 1
  fi
done

cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"status":"success","project":"first"}'
printf '%s\n' '{"status":"success","project":"second"}'
EOF
chmod +x "${FAKE_OPENCLAW}"
ambiguous="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  RUN_ID="run-git-ambiguous" \
  TARGET_AGENT="git_issuer" \
  MESSAGE="return two objects" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"
if [ "$(printf '%s' "${ambiguous}" | jq -r '.worker_result_json')" != null ]; then
  echo "expected multiple different JSON objects to be rejected as ambiguous" >&2
  printf '%s\n' "${ambiguous}" >&2
  exit 1
fi

cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OPENCLAW_LOG}"
printf '%s\n' 'gateway unavailable'
exit 23
EOF
chmod +x "${FAKE_OPENCLAW}"

failed="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-2" \
  TARGET_AGENT="git_issuer" \
  TARGET_SESSION_KEY="agent:git_issuer:main" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh" <<'EOF'
create issue
EOF
)"

failed_status="$(printf '%s' "${failed}" | jq -r '.status')"
exit_code="$(printf '%s' "${failed}" | jq -r '.exit_code')"

if [ "${failed_status}" != "failed" ] || [ "${exit_code}" != "23" ]; then
  echo "expected controlled failed envelope for openclaw failure:" >&2
  printf '%s\n' "${failed}" >&2
  exit 1
fi

echo "ok run_agent_turn wraps openclaw agent"
