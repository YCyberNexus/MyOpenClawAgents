#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TEST_ROOT="$(mktemp -d "${TMP_PARENT}/req-executor-local-env.XXXXXX")"
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
REPO_PARENT_PATH=/data
EOF

cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<EOF
REPO_PARENT_PATH=${REPO_PARENT}
DISPATCHER_CALLBACK_TARGET=agent:req_dispatcher:local-test
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
correlation_id=reqd-local
dispatcher_callback_target=agent:req_dispatcher:local-test
executor_agent=req_executor
callback_nonce=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
EOF
then
  echo "dispatch_single_issue.sh failed" >&2
  cat "${TEST_ROOT}/stderr" >&2
  exit 1
fi

if grep -q '^branch=' "${CAPTURE_FILE}"; then
  echo "driven trigger must omit an unspecified branch" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

# Local deployment paths stay executor-private and are consumed only by the
# delegated driven wrapper.
if grep -q '^repo_path=' "${CAPTURE_FILE}"; then
  echo "single shim must not copy a local repo path into I1" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

legacy_field_pattern='^(result_'
legacy_field_pattern+='basename'
legacy_field_pattern+='|data_'
legacy_field_pattern+='basename'
legacy_field_pattern+='|ui_'
legacy_field_pattern+='accounts_'
legacy_field_pattern+='relpath'
legacy_field_pattern+=')='
if grep -Eq "${legacy_field_pattern}" "${CAPTURE_FILE}"; then
  echo "driven trigger must not expose old basename/UI-account fields" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi

if ! grep -q '^dispatcher_callback_target=agent:req_dispatcher:local-test$' "${CAPTURE_FILE}"; then
  echo "expected driven trigger to preserve dispatcher callback target" >&2
  cat "${CAPTURE_FILE}" >&2
  exit 1
fi
if find "${REPO_PARENT}" -name dispatch_origin.json -print -quit | grep -q .; then
  echo "single shim must not create a legacy dispatch_origin.json" >&2
  exit 1
fi

echo "ok dispatch_single_issue keeps local deployment config private"
