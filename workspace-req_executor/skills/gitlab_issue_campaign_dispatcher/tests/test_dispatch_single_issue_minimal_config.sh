#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-minimal-config.XXXXXX")"
CONFIG_DIR="${TEST_ROOT}/config"
REPO_PARENT="${TEST_ROOT}/repos"
PREPARE_TICK="${TEST_ROOT}/prepare_tick.sh"
mkdir -p "${CONFIG_DIR}" "${REPO_PARENT}"

cat >"${CONFIG_DIR}/gitlab.env" <<'EOF'
GITLAB_HOST=gitlab-b.pxsemic.tech:30000
GITLAB_API_PROTOCOL=http
GITLAB_TOKEN=gitlab-env-token
EOF

cat >"${CONFIG_DIR}/campaign_defaults.env" <<EOF
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

if grep -q '^branch=' "${TEST_ROOT}/stdout"; then
  echo "synthesized trigger must not require or forward a configured branch" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if ! grep -q '^repo_path='"${REPO_PARENT}"'$' "${TEST_ROOT}/stdout"; then
  echo "expected repo_path to come from the only campaign default" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if ! grep -q '^gitlab_token=gitlab-env-token$' "${TEST_ROOT}/stdout"; then
  echo "expected GITLAB_TOKEN from gitlab.env to be forwarded" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

echo "ok dispatch_single_issue accepts minimal campaign config"
