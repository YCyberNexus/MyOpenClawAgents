#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-branch.XXXXXX")"
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
trigger="$(cat)"
project="$(printf '%s\n' "${trigger}" | sed -n 's/^project=//p')"
repo_parent="$(printf '%s\n' "${trigger}" | sed -n 's/^repo_path=//p')"
[ -n "${project}" ] && [ -n "${repo_parent}" ] || exit 98
repo_target="${repo_parent}/${project}"
if [ -e "${repo_target}" ] && [ ! -e "${repo_target}/.git" ]; then
  exit 91
fi
mkdir -p "${repo_target}/.git"
printf '%s\n' "${trigger}"
EOF
chmod +x "${PREPARE_TICK}"

if ! CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
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

if ! grep -q '^branch=release/2026.07$' "${TEST_ROOT}/stdout"; then
  echo "expected synthesized trigger to forward branch" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null 2>"${TEST_ROOT}/invalid.err" <<'EOF'
RUN_SINGLE_ISSUE
project=claw_gitlab/req_executor_test
iid=42
correlation_id=reqd-branch
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

echo "ok dispatch_single_issue forwards explicit branch"
