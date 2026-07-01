#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-local-env.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
REPO_PARENT="${TEST_ROOT}/repos"
PREPARE_TICK="${TEST_ROOT}/prepare_tick.sh"
mkdir -p "${CONFIG_DIR}" "${REPO_PARENT}"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
EOF

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
GROUP=wrong_group
GITLAB_TOKEN=
BRANCH=master
DEV_BRANCH=dev
RESULT_BASENAME=ifp-result
DATA_BASENAME=ifp-data
REPO_PARENT_PATH=/data
EOF

cat >"${CONFIG_DIR}/campaign_defaults.local.env" <<EOF
GROUP=claw_gitlab
GITLAB_TOKEN=local-token
REPO_PARENT_PATH=${REPO_PARENT}
EOF

cat >"${PREPARE_TICK}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat
EOF
chmod +x "${PREPARE_TICK}"

if ! CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr" <<'EOF'
RUN_SINGLE_ISSUE
project=claw_gitlab/px_ifp_hulat_test
iid=42
correlation_id=reqd-local
dispatcher_callback_target=agent:req_dispatcher:local-test
EOF
then
  echo "dispatch_single_issue.sh failed" >&2
  cat "${TEST_ROOT}/stderr" >&2
  exit 1
fi

if ! grep -q '^gitlab_token=local-token$' "${TEST_ROOT}/stdout"; then
  echo "expected local env token to be forwarded to synthesized trigger" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if ! grep -q "^repo_path=${REPO_PARENT}$" "${TEST_ROOT}/stdout"; then
  echo "expected local env repo parent to be forwarded to synthesized trigger" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

DISPATCH_ORIGIN="${REPO_PARENT}/px_ifp_hulat_test/ifp-result/issues/issue-42/dispatch_origin.json"
if [ "$(jq -r '.dispatcher_callback_target' "${DISPATCH_ORIGIN}")" != "agent:req_dispatcher:local-test" ]; then
  echo "expected dispatch_origin.json to preserve dispatcher callback target" >&2
  cat "${DISPATCH_ORIGIN}" >&2
  exit 1
fi

echo "ok dispatch_single_issue loads local env override"
