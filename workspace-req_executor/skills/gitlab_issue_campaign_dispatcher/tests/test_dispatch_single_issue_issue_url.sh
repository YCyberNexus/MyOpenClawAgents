#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-issue-url.XXXXXX")"
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
issue_url=http://gitlab-b.pxsemic.tech:30000/claw_gitlab/req_executor_test/-/issues/42
correlation_id=reqd-url
dispatcher_callback_target=agent:req_dispatcher:main
branch=release/2026.07
EOF
then
  echo "dispatch_single_issue.sh should accept a GitLab issue URL" >&2
  cat "${TEST_ROOT}/stderr" >&2
  exit 1
fi

if ! grep -q '^group=claw_gitlab$' "${TEST_ROOT}/stdout"; then
  echo "expected group extracted from issue_url" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if ! grep -q '^project=req_executor_test$' "${TEST_ROOT}/stdout"; then
  echo "expected project slug extracted from issue_url" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if ! grep -q '^issue_iids=42$' "${TEST_ROOT}/stdout"; then
  echo "expected iid extracted from issue_url" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if ! grep -q '^branch=release/2026.07$' "${TEST_ROOT}/stdout"; then
  echo "expected branch to still be forwarded with issue_url input" >&2
  cat "${TEST_ROOT}/stdout" >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null 2>"${TEST_ROOT}/missing-url.err" <<'EOF'
RUN_SINGLE_ISSUE
issue_url=http://docs-gitlab.example.com/claw_gitlab/req_executor_test/issues/42
correlation_id=reqd-url
EOF
then
  echo "expected malformed issue_url to fail" >&2
  exit 1
fi

if ! grep -q "issue_url must be a GitLab issue URL" "${TEST_ROOT}/missing-url.err"; then
  echo "expected clear malformed issue_url error" >&2
  cat "${TEST_ROOT}/missing-url.err" >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null 2>"${TEST_ROOT}/non-gitlab-host.err" <<'EOF'
RUN_SINGLE_ISSUE
issue_url=http://docs.example.com/claw_gitlab/req_executor_test/-/issues/42
correlation_id=reqd-url
EOF
then
  echo "expected issue_url host without gitlab to fail" >&2
  exit 1
fi

if ! grep -q "GitLab host" "${TEST_ROOT}/non-gitlab-host.err"; then
  echo "expected non-gitlab host error" >&2
  cat "${TEST_ROOT}/non-gitlab-host.err" >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null 2>"${TEST_ROOT}/space-project.err" <<'EOF'
RUN_SINGLE_ISSUE
issue_url=http://gitlab-b.pxsemic.tech:30000/claw_gitlab%20bad/req_executor_test/-/issues/42
correlation_id=reqd-url
EOF
then
  echo "expected decoded project path containing spaces to fail" >&2
  exit 1
fi

if ! grep -q "project path" "${TEST_ROOT}/space-project.err"; then
  echo "expected decoded-space project path error" >&2
  cat "${TEST_ROOT}/space-project.err" >&2
  exit 1
fi

if CONFIG_DIR="${CONFIG_DIR}" \
  PREPARE_TICK_CMD="${PREPARE_TICK}" \
  bash "${SKILL_DIR}/scripts/dispatch_single_issue.sh" >/dev/null 2>"${TEST_ROOT}/bad-percent.err" <<'EOF'
RUN_SINGLE_ISSUE
issue_url=http://gitlab-b.pxsemic.tech:30000/claw_gitlab%GG/req_executor_test/-/issues/42
correlation_id=reqd-url
EOF
then
  echo "expected malformed percent encoding in project path to fail" >&2
  exit 1
fi

if ! grep -q "project path" "${TEST_ROOT}/bad-percent.err"; then
  echo "expected malformed-percent project path error" >&2
  cat "${TEST_ROOT}/bad-percent.err" >&2
  exit 1
fi

echo "ok dispatch_single_issue accepts issue_url input"
