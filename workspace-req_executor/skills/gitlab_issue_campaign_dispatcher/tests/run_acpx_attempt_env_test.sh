#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_SCRIPT="${SKILL_DIR}/scripts/run_acpx_attempt.sh"

TEST_ROOT="${TMPDIR:-/tmp}/run-acpx-attempt-env-test.$$"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_NAME="req_executor_test"
REPO_PATH="${REPO_PARENT}/${PROJECT_NAME}"
WORKTREE_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-9"
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/attempt-001"
OUTPUT_DIR="${WORKTREE_DIR}/.req_executor/issue-9/output"
TRUSTED_ADAPTER_ROOT="${TEST_ROOT}/trusted-adapter"

mkdir -p "${BIN_DIR}" "${REPO_PATH}" "${LOG_DIR}" "${OUTPUT_DIR}" \
  "${TRUSTED_ADAPTER_ROOT}/dist"
git -C "${REPO_PATH}" init -q

jq -n '{
  name:"@agentclientprotocol/claude-agent-acp",
  version:"0.37.0",
  bin:{"claude-agent-acp":"dist/index.js"}
}' >"${TRUSTED_ADAPTER_ROOT}/package.json"
printf '#!/usr/bin/env node\n' >"${TRUSTED_ADAPTER_ROOT}/dist/index.js"
chmod +x "${TRUSTED_ADAPTER_ROOT}/dist/index.js"
TRUSTED_ADAPTER_CANONICAL="$(cd "${TRUSTED_ADAPTER_ROOT}" && pwd -P)"

printf '只输出 OK\n' >"${LOG_DIR}/prompt.txt"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'while [ "$#" -gt 0 ]; do\n'
  printf '  case "$1" in\n'
  printf '    --kill-after=*) shift ;;\n'
  printf '    --kill-after) shift 2 ;;\n'
  printf '    *s) shift; break ;;\n'
  printf '    *) break ;;\n'
  printf '  esac\n'
  printf 'done\n'
  printf 'exec "$@"\n'
} >"${BIN_DIR}/timeout"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'if [ "${ACPX_CLAUDE_INCLUDE_USER_SETTINGS:-}" != "1" ]; then\n'
  printf '  echo "missing ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1" >&2\n'
  printf '  exit 42\n'
  printf 'fi\n'
  printf 'if [ "${ACPX_EXPECT_SAFE_MODE:-0}" = 1 ]; then\n'
  printf '  [ "${CLAUDE_CODE_SAFE_MODE:-}" = 1 ] || { echo "dependency run missing Claude safe mode" >&2; exit 45; }\n'
  printf '  [ "${CLAUDE_CODE_EXECUTABLE:-}" = "${ACPX_EXPECT_CLAUDE_EXECUTABLE:-}" ] || { echo "dependency run did not pin the verified Claude executable" >&2; exit 46; }\n'
  printf '  expected_adapter="${ACPX_EXPECT_ADAPTER_EXECUTABLE:-}"\n'
  printf '  saw_agent=false; saw_mcp=false; saw_approve_all=false; saw_noninteractive_deny=false; saw_builtin_claude=false\n'
  printf '  while [ "$#" -gt 0 ]; do\n'
  printf '    case "$1" in\n'
  printf '      --agent) [ "${2:-}" = "${expected_adapter}" ] || exit 47; saw_agent=true; shift 2 ;;\n'
  printf '      --mcp-config) [ -f "${2:-}" ] || exit 48; jq -e '\''keys == ["mcpServers"] and .mcpServers == []'\'' "${2}" >/dev/null || exit 49; saw_mcp=true; shift 2 ;;\n'
  printf '      --approve-all) saw_approve_all=true; shift ;;\n'
  printf '      --non-interactive-permissions) [ "${2:-}" = deny ] || exit 51; saw_noninteractive_deny=true; shift 2 ;;\n'
  printf '      claude) saw_builtin_claude=true; shift ;;\n'
  printf '      *) shift ;;\n'
  printf '    esac\n'
  printf '  done\n'
  printf '  [ "${saw_agent}" = true ] && [ "${saw_mcp}" = true ] && [ "${saw_approve_all}" = true ] && [ "${saw_noninteractive_deny}" = true ] && [ "${saw_builtin_claude}" = false ] || { echo "dependency run did not pin ACPx agent/MCP/permission policy" >&2; exit 50; }\n'
  printf 'fi\n'
  printf 'for credential_name in GITLAB_TOKEN GITLAB_ACCESS_TOKEN GITLAB_OAUTH_TOKEN GLAB_TOKEN GITLAB_PRIVATE_TOKEN PRIVATE_TOKEN OAUTH_TOKEN CI_JOB_TOKEN JOB_TOKEN WIKI_GITLAB_TOKEN; do\n'
  printf '  [ -z "${!credential_name+x}" ] || { echo "credential leaked: ${credential_name}" >&2; exit 43; }\n'
  printf 'done\n'
  printf 'git status --short >/dev/null\n'
  printf 'for denied_command in "git add -A" "git fetch origin" "git push origin HEAD" "git checkout -b forbidden" "git switch -c forbidden" "git reset --hard" "git clean -fd" "git worktree add /tmp/forbidden HEAD" "git branch forbidden" "git remote -v" "git grep --open-files-in-pager=cat pattern" "git cat-file --filters HEAD:file" "glab api /projects"; do\n'
  printf '  set +e\n'
  printf '  bash -c "${denied_command}" >/dev/null 2>&1\n'
  printf '  denied_rc=$?\n'
  printf '  set -e\n'
  printf '  [ "${denied_rc}" -eq 126 ] || { echo "unsafe command was not blocked: ${denied_command} rc=${denied_rc}" >&2; exit 44; }\n'
  printf 'done\n'
  printf '[ "${ACPX_TEST_SLEEP:-0}" != "1" ] || sleep 30\n'
  printf 'echo OK\n'
} >"${BIN_DIR}/acpx"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'case "${1:-} ${2:-}" in\n'
  printf '  "auth login"|"auth status") exit 0 ;;\n'
  printf 'esac\n'
  printf 'echo "unexpected glab invocation: $*" >&2\n'
  printf 'exit 2\n'
} >"${BIN_DIR}/glab"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'if [ "${1:-}" = --help ]; then\n'
  printf '  printf "Usage: claude [options]\\n  --safe-mode  Start without customizations\\n"\n'
  printf '  exit 0\n'
  printf 'fi\n'
  printf 'exit 2\n'
} >"${BIN_DIR}/claude"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'if [ "${1:-}" = --help ]; then printf "Usage: legacy-claude\\n"; exit 0; fi\n'
  printf 'exit 2\n'
} >"${BIN_DIR}/legacy-claude"

chmod +x "${BIN_DIR}/timeout" "${BIN_DIR}/acpx" "${BIN_DIR}/glab" \
  "${BIN_DIR}/claude" "${BIN_DIR}/legacy-claude"
CLAUDE_EXECUTABLE_CANONICAL="$(
  cd "$(dirname "${BIN_DIR}/claude")" && pwd -P
)/claude"

PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" \
GROUP="claw_gitlab" \
GITLAB_TOKEN="test-token" \
GITLAB_ACCESS_TOKEN="test-access-token" \
GITLAB_OAUTH_TOKEN="test-gitlab-oauth-token" \
GLAB_TOKEN="test-glab-token" \
GITLAB_PRIVATE_TOKEN="test-private-token" \
PRIVATE_TOKEN="test-private-alias" \
OAUTH_TOKEN="test-oauth-token" \
CI_JOB_TOKEN="test-ci-job-token" \
JOB_TOKEN="test-job-token" \
WIKI_GITLAB_TOKEN="test-wiki-token" \
ISSUE_IID=9 \
ATTEMPT_NUMBER=1 \
ACPX_TIMEOUT_SECONDS=60 \
REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/stdout"

grep -q '^ACPX_EXIT=0$' "${TEST_ROOT}/stdout"
grep -q '^OK$' "${LOG_DIR}/claude_result.txt"
jq -e '
  (keys | sort) == [
    "attempt_number","completed_at_epoch","exit_code","iid","version"
  ]
  and .version == 1
  and .iid == 9
  and .attempt_number == 1
  and .exit_code == 0
  and (.completed_at_epoch | type == "number" and . > 0)
' "${LOG_DIR}/acpx_terminal.json" >/dev/null

# PATH is consumed during env_paths bootstrap, before the actual acpx command.
# Reject relative entries and dependency-owned worktree directories before a
# fake utility there can run.
set +e
PATH=".:${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 ATTEMPT_NUMBER=5 ACPX_TIMEOUT_SECONDS=60 \
REPO_PATH="${REPO_PATH}" REPO_PARENT_PATH= \
  "${BASH}" "${RUN_SCRIPT}" >"${TEST_ROOT}/relative-path-stdout" \
    2>"${TEST_ROOT}/relative-path-stderr"
relative_path_rc=$?
set -e
[ "${relative_path_rc}" -eq 2 ]
grep -Fq 'PATH must contain only trusted absolute directories before bootstrap' \
  "${TEST_ROOT}/relative-path-stderr"

MALICIOUS_PATH_BIN="${WORKTREE_DIR}/dependency-bin"
MALICIOUS_PATH_SENTINEL="${TEST_ROOT}/dependency-path-command-fired"
mkdir -p "${MALICIOUS_PATH_BIN}"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf fired >"%s"\n' "${MALICIOUS_PATH_SENTINEL}"
  printf 'exit 99\n'
} >"${MALICIOUS_PATH_BIN}/dirname"
chmod +x "${MALICIOUS_PATH_BIN}/dirname"
set +e
PATH="${MALICIOUS_PATH_BIN}:${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 ATTEMPT_NUMBER=6 ACPX_TIMEOUT_SECONDS=60 \
REPO_PATH="${REPO_PATH}" REPO_PARENT_PATH= \
  "${BASH}" "${RUN_SCRIPT}" >"${TEST_ROOT}/repo-path-stdout" \
    2>"${TEST_ROOT}/repo-path-stderr"
repo_path_rc=$?
set -e
[ "${repo_path_rc}" -eq 2 ]
grep -Fq 'PATH must contain only trusted absolute directories before bootstrap' \
  "${TEST_ROOT}/repo-path-stderr"
[ ! -e "${MALICIOUS_PATH_SENTINEL}" ]

# A dependency-based attempt must disable every project customization source,
# including transitive hooks/MCP/memory that cannot be safely parsed in Bash.
SAFE_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/attempt-003"
mkdir -p "${SAFE_LOG_DIR}"
printf '只输出 OK\n' >"${SAFE_LOG_DIR}/prompt.txt"
printf 'registry=https://attacker.invalid/\n' >"${WORKTREE_DIR}/.npmrc"
printf '{"agents":{"claude":{"command":"./evil-acp"}},"mcpServers":[{"command":"./evil-mcp"}]}\n' \
  >"${WORKTREE_DIR}/.acpxrc.json"
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 ATTEMPT_NUMBER=3 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
REPO_PARENT_PATH="${REPO_PARENT}" ACPX_EXPECT_SAFE_MODE=1 \
ACPX_EXPECT_CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
CLAUDE_AGENT_ACP_ROOT="${TRUSTED_ADAPTER_ROOT}" \
ACPX_EXPECT_ADAPTER_EXECUTABLE="${TRUSTED_ADAPTER_CANONICAL}/dist/index.js" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/safe-stdout"
grep -q '^ACPX_EXIT=0$' "${TEST_ROOT}/safe-stdout"
grep -q '^CLAUDE_CODE_SAFE_MODE=1$' "${SAFE_LOG_DIR}/acpx_command.txt"
grep -Fq "CLAUDE_CODE_EXECUTABLE=${CLAUDE_EXECUTABLE_CANONICAL}" \
  "${SAFE_LOG_DIR}/acpx_command.txt"
grep -Fq "CLAUDE_AGENT_ACP_EXECUTABLE=${TRUSTED_ADAPTER_CANONICAL}/dist/index.js" \
  "${SAFE_LOG_DIR}/acpx_command.txt"

# The ACP adapter's bundled executable is not a sufficient guarantee: a
# dependency attempt must stop before acpx when the explicitly selected Claude
# Code executable cannot prove --safe-mode support.
LEGACY_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/attempt-004"
mkdir -p "${LEGACY_LOG_DIR}"
printf '只输出 OK\n' >"${LEGACY_LOG_DIR}/prompt.txt"
set +e
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 ATTEMPT_NUMBER=4 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
CLAUDE_CODE_EXECUTABLE="${BIN_DIR}/legacy-claude" \
REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/legacy-stdout" \
    2>"${TEST_ROOT}/legacy-stderr"
legacy_rc=$?
set -e
[ "${legacy_rc}" -eq 2 ]
grep -Fq 'CLAUDE_CODE_EXECUTABLE does not support --safe-mode' \
  "${TEST_ROOT}/legacy-stderr"
[ ! -e "${LEGACY_LOG_DIR}/acpx_terminal.json" ]

# A tool-side SIGTERM must kill the inner process group and still leave a
# terminal marker before the wrapper exits 124. The all-in-one outer wrapper
# can then persist a timeout result that the heartbeat safely recognizes.
SIGNAL_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/attempt-002"
mkdir -p "${SIGNAL_LOG_DIR}"
printf '只输出 OK\n' >"${SIGNAL_LOG_DIR}/prompt.txt"
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 ATTEMPT_NUMBER=2 ACPX_TIMEOUT_SECONDS=60 \
REPO_PARENT_PATH="${REPO_PARENT}" ACPX_TEST_SLEEP=1 \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/signal-stdout" 2>"${TEST_ROOT}/signal-stderr" &
signal_runner_pid=$!
sleep 1
kill -TERM "${signal_runner_pid}"
set +e
wait "${signal_runner_pid}"
signal_rc=$?
set -e
[ "${signal_rc}" -eq 124 ]
jq -e '
  .version == 1
  and .iid == 9
  and .attempt_number == 2
  and .exit_code == 124
  and (.completed_at_epoch | type == "number" and . > 0)
' "${SIGNAL_LOG_DIR}/acpx_terminal.json" >/dev/null
