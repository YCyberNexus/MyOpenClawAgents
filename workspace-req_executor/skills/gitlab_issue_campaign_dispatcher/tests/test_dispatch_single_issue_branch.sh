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
