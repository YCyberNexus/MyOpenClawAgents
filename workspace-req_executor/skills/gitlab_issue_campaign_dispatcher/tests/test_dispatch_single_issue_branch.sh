#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-branch.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
DRIVEN_BATCH="${TEST_ROOT}/run_driven_issue_batch.sh"
CAPTURE_FILE="${TEST_ROOT}/driven-trigger.txt"
mkdir -p "${CONFIG_DIR}"

unset GITLAB_HOST GITLAB_API_PROTOCOL GITLAB_ADDRESS GITLAB_TOKEN
unset REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=tracked-blue.invalid:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=tracked-token-must-not-reach-local-test
EOF
cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<'EOF'
GITLAB_HOST=local-gitlab.invalid:9443
GITLAB_API_PROTOCOL=https
GITLAB_TOKEN=local-branch-fixture-token
REQ_EXECUTOR_GITLAB_LOCAL_TEST_MODE=true
REQ_EXECUTOR_GITLAB_ALLOWED_HOSTS=local-gitlab.invalid:9443
EOF

cat >"${DRIVEN_BATCH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >"${CAPTURE_FILE}"
jq -cn '{status:"accepted",spawn_grants:[],reconcile_actions:[]}'
EOF
chmod +x "${DRIVEN_BATCH}"

if ! CONFIG_DIR="${CONFIG_DIR}" \
  DRIVEN_BATCH_CMD="${DRIVEN_BATCH}" CAPTURE_FILE="${CAPTURE_FILE}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr" <<'EOF'
RUN_SINGLE_ISSUE
project=claw_gitlab/req_executor_test
iid=42
correlation_id=reqd-branch
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=1111111111111111111111111111111111111111111111111111111111111111
branch=release/2026.07
EOF
then
  echo "dispatch_single_issue.sh should accept a branch field" >&2
  cat "${TEST_ROOT}/stderr" >&2
  exit 1
fi

if ! grep -q '^branch=release/2026.07$' "${CAPTURE_FILE}"; then
  echo "expected driven batch shim to forward branch" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" \
  DRIVEN_BATCH_CMD="${DRIVEN_BATCH}" CAPTURE_FILE="${CAPTURE_FILE}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null 2>"${TEST_ROOT}/invalid.err" <<'EOF'
RUN_SINGLE_ISSUE
project=claw_gitlab/req_executor_test
iid=42
correlation_id=reqd-branch
dispatcher_callback_target=agent:req_dispatcher:main
executor_agent=req_executor
callback_nonce=1111111111111111111111111111111111111111111111111111111111111111
branch=../bad
EOF
then
  echo "expected invalid branch to fail" >&2
  exit 1
fi

if ! grep -q "branch must be a safe Git ref name" "${TEST_ROOT}/invalid.err"; then
  echo "expected clear invalid branch error" >&2
  cat "${TEST_ROOT}/invalid.err" >&2
  exit 1
fi

echo "ok dispatch_single_issue forwards explicit branch to driven batch"
