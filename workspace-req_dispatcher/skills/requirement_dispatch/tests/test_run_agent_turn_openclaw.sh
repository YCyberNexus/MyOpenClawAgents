#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-run-agent.XXXXXX")"
FAKE_OPENCLAW="${TEST_ROOT}/openclaw"
OPENCLAW_LOG="${TEST_ROOT}/openclaw.args"

cat >"${FAKE_OPENCLAW}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OPENCLAW_LOG}"
printf '%s\n' 'accepted'
printf '%s\n' '{"status":"success","project":"ai-infra/veqp_server_v3","issue_iid":7,"issue_url":"https://gitlab.example/issues/7"}'
EOF
chmod +x "${FAKE_OPENCLAW}"

result="$(
  OPENCLAW_BIN="${FAKE_OPENCLAW}" \
  OPENCLAW_LOG="${OPENCLAW_LOG}" \
  RUN_ID="run-git-1" \
  TARGET_AGENT="git_issuer" \
  TARGET_SESSION_KEY="agent:git_issuer:main" \
  AGENT_TIMEOUT_SECONDS="120" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh" <<'EOF'
create issue for ai-infra/veqp_server_v3
EOF
)"

if ! grep -q -- 'agent --agent git_issuer --session-key agent:git_issuer:main' "${OPENCLAW_LOG}"; then
  echo "expected wrapper to call openclaw agent with target and session key" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if ! grep -q -- '--message create issue for ai-infra/veqp_server_v3' "${OPENCLAW_LOG}"; then
  echo "expected wrapper to pass stdin as --message" >&2
  cat "${OPENCLAW_LOG}" >&2
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
  MESSAGE="create issue with explicit session id" \
  bash "${SKILL_DIR}/scripts/run_agent_turn.sh"
)"

if ! grep -q -- 'agent --agent git_issuer --session-id 12345' "${OPENCLAW_LOG}"; then
  echo "expected explicit numeric TARGET_SESSION_ID to use --session-id" >&2
  cat "${OPENCLAW_LOG}" >&2
  exit 1
fi

if [ "$(printf '%s' "${numeric_session}" | jq -r '.status')" != "success" ]; then
  echo "expected numeric session-id call to succeed:" >&2
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
