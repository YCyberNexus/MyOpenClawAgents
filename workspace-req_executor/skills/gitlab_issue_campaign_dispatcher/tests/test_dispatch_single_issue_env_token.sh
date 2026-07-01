#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-env-token.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
REPO_PARENT="${TEST_ROOT}/repos"
PREPARE_TICK="${TEST_ROOT}/prepare_tick.sh"
mkdir -p "${CONFIG_DIR}" "${REPO_PARENT}"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
EOF

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
GITLAB_TOKEN=
BRANCH=master
DEV_BRANCH=dev
RESULT_BASENAME=ifp-result
DATA_BASENAME=ifp-data
REPO_PARENT_PATH=${REPO_PARENT}
EOF

cat >"${PREPARE_TICK}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat
EOF
chmod +x "${PREPARE_TICK}"

if ! GITLAB_TOKEN="env-token" \
  CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr" <<'EOF'
RUN_SINGLE_ISSUE
project=claw_gitlab/px_ifp_hulat_test
iid=42
correlation_id=reqd-env
dispatcher_callback_target=agent:req_dispatcher:main
EOF
then
  echo "dispatch_single_issue.sh failed" >&2
  cat "${TEST_ROOT}/stderr" >&2
  exit 1
fi

if ! grep -q '^gitlab_token=env-token$' "${TEST_ROOT}/stdout"; then
  echo "expected env GITLAB_TOKEN to override empty campaign pin" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

echo "ok dispatch_single_issue preserves env token"
