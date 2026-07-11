#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-minimal-config.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
REPO_PARENT="${TEST_ROOT}/repos"
DRIVEN_BATCH="${TEST_ROOT}/run_driven_issue_batch.sh"
CAPTURE_FILE="${TEST_ROOT}/driven-trigger.txt"
mkdir -p "${CONFIG_DIR}" "${REPO_PARENT}"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=gitlab-env-token
EOF

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
REPO_PARENT_PATH=${REPO_PARENT}
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
correlation_id=reqd-minimal
dispatcher_callback_target=agent:req_dispatcher:main
EOF
then
  echo "dispatch_single_issue.sh should accept campaign_defaults.env with only REPO_PARENT_PATH" >&2
  cat "${TEST_ROOT}/stderr" >&2
  exit 1
fi

if grep -q '^branch=' "${CAPTURE_FILE}"; then
  echo "driven trigger must omit an unspecified branch" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

if grep -q '^repo_path=' "${CAPTURE_FILE}"; then
  echo "single shim must not expose the minimal config clone root" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

if grep -Eq 'gitlab_token|GITLAB_TOKEN|gitlab-env-token' "${CAPTURE_FILE}"; then
  echo "single shim must not forward the token from minimal config" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

if grep -q '^run_timeout_seconds=' "${CAPTURE_FILE}"; then
  echo "driven trigger must not expose run_timeout_seconds" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

grep -qx 'project=claw_gitlab/req_executor_test' "${CAPTURE_FILE}" \
  || { echo "single shim did not preserve the full project" >&2; exit 1; }
grep -qx 'selector_type=single' "${CAPTURE_FILE}" \
  || { echo "single shim did not enter the driven scheduler" >&2; exit 1; }

echo "ok dispatch_single_issue accepts minimal config without leaking it"
