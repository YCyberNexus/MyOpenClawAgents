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
