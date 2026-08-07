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
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-1"
OUTPUT_DIR="${WORKTREE_DIR}/.req_executor/issue-9/output"
CLAUDE_INVOCATION_SENTINEL="${TEST_ROOT}/claude-invoked"
ACPX_ARGS_LOG="${TEST_ROOT}/acpx-args.log"

mkdir -p "${BIN_DIR}" "${REPO_PATH}" "${LOG_DIR}" "${OUTPUT_DIR}"
git -C "${REPO_PATH}" init -q
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
  printf '[ "${ACPX_CLAUDE_INCLUDE_USER_SETTINGS:-}" = 1 ] || { echo "missing ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1" >&2; exit 42; }\n'
  printf '[ "${CLAUDE_CODE_EXECUTABLE:-}" = "${ACPX_EXPECT_CLAUDE_EXECUTABLE:-}" ] || { echo "run did not pin the requested Claude executable" >&2; exit 46; }\n'
  printf '[ "${CLAUDE_CODE_FORK_SUBAGENT:-}" = 1 ] || { echo "run missing CLAUDE_CODE_FORK_SUBAGENT=1" >&2; exit 52; }\n'
  printf '[ "${CLAUDE_CODE_SAFE_MODE:-}" = "${ACPX_EXPECT_CLAUDE_SAFE_MODE:-}" ] || { echo "run changed the deployment safe-mode override" >&2; exit 53; }\n'
  printf '[ "$#" -eq 6 ] || { echo "unexpected ACPX argument count: $#" >&2; exit 54; }\n'
  printf '[ "$1" = --auth-policy ] && [ "$2" = skip ] && [ "$3" = claude ] && [ "$4" = exec ] && [ "$5" = -f ] && [ -f "$6" ] || { echo "attempt did not use the common builtin Claude path: $*" >&2; exit 55; }\n'
  printf 'printf "%%s|%%s|%%s|%%s|%%s\\n" "$1" "$2" "$3" "$4" "$5" >>"${ACPX_ARGS_LOG:?}"\n'
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
  printf '[ "${ACPX_TEST_SLEEP:-0}" != 1 ] || sleep 30\n'
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

# The fixed wrapper may validate this executable, but it must never call it as
# a dependency-only capability probe. ACPX owns the one real Claude launch.
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'printf invoked >"${CLAUDE_INVOCATION_SENTINEL:?}"\n'
  printf 'exit 99\n'
} >"${BIN_DIR}/claude"

chmod +x "${BIN_DIR}/timeout" "${BIN_DIR}/acpx" "${BIN_DIR}/glab" \
  "${BIN_DIR}/claude"
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
EXECUTION_ID=1 \
ACPX_TIMEOUT_SECONDS=60 \
CLAUDE_CODE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
CLAUDE_CODE_FORK_SUBAGENT=0 \
ACPX_EXPECT_CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
CLAUDE_INVOCATION_SENTINEL="${CLAUDE_INVOCATION_SENTINEL}" \
ACPX_ARGS_LOG="${ACPX_ARGS_LOG}" \
REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/stdout"

grep -q '^ACPX_EXIT=0$' "${TEST_ROOT}/stdout"
grep -q '^OK$' "${LOG_DIR}/claude_result.txt"
jq -e '
  (keys | sort) == [
    "completed_at_epoch","execution_id","exit_code","iid","version"
  ]
  and .version == 1
  and .iid == 9
  and .execution_id == 1
  and .exit_code == 0
  and (.completed_at_epoch | type == "number" and . > 0)
' "${LOG_DIR}/acpx_terminal.json" >/dev/null
grep -Fq "CLAUDE_CODE_EXECUTABLE=${CLAUDE_EXECUTABLE_CANONICAL}" \
  "${LOG_DIR}/acpx_command.txt"
grep -q '^CLAUDE_CODE_FORK_SUBAGENT=1$' "${LOG_DIR}/acpx_command.txt"
grep -Fq "command=CLAUDE_CODE_EXECUTABLE=${CLAUDE_EXECUTABLE_CANONICAL} CLAUDE_CODE_FORK_SUBAGENT=1 ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1 " \
  "${LOG_DIR}/acpx_command.txt"
grep -Fq ' --auth-policy skip claude exec -f ' "${LOG_DIR}/acpx_command.txt"
grep -Fq 'CLAUDE_CODE_EXECUTABLE_EFFECTIVE="${CLAUDE_CODE_EXECUTABLE:-/home/claw/.local/bin/claude}"' \
  "${RUN_SCRIPT}"
[ ! -e "${CLAUDE_INVOCATION_SENTINEL}" ]

# PATH is consumed during env_paths bootstrap, before the actual ACPX command.
# Reject relative entries and dependency-owned worktree directories before a
# fake utility there can run.
set +e
PATH=".:${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=5 ACPX_TIMEOUT_SECONDS=60 \
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
ISSUE_IID=9 EXECUTION_ID=6 ACPX_TIMEOUT_SECONDS=60 \
REPO_PATH="${REPO_PATH}" REPO_PARENT_PATH= \
  "${BASH}" "${RUN_SCRIPT}" >"${TEST_ROOT}/repo-path-stdout" \
    2>"${TEST_ROOT}/repo-path-stderr"
repo_path_rc=$?
set -e
[ "${repo_path_rc}" -eq 2 ]
grep -Fq 'PATH must contain only trusted absolute directories before bootstrap' \
  "${TEST_ROOT}/repo-path-stderr"
[ ! -e "${MALICIOUS_PATH_SENTINEL}" ]

# Dependency metadata must not select a second model-launch path. Even with
# dependency-only-looking project files present, the wrapper passes the same
# built-in Claude ACPX arguments and does not invoke `claude --help`.
DEPENDENCY_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-3"
mkdir -p "${DEPENDENCY_LOG_DIR}"
printf '只输出 OK\n' >"${DEPENDENCY_LOG_DIR}/prompt.txt"
printf 'registry=https://attacker.invalid/\n' >"${WORKTREE_DIR}/.npmrc"
printf '{"agents":{"claude":{"command":"./evil-acp"}},"mcpServers":[{"command":"./evil-mcp"}]}\n' \
  >"${WORKTREE_DIR}/.acpxrc.json"
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=3 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
CLAUDE_CODE_SAFE_MODE=deployment-choice \
CLAUDE_CODE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
ACPX_EXPECT_CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
ACPX_EXPECT_CLAUDE_SAFE_MODE=deployment-choice \
CLAUDE_INVOCATION_SENTINEL="${CLAUDE_INVOCATION_SENTINEL}" \
ACPX_ARGS_LOG="${ACPX_ARGS_LOG}" \
REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/dependency-stdout"
grep -q '^ACPX_EXIT=0$' "${TEST_ROOT}/dependency-stdout"
grep -q '^CLAUDE_CODE_SAFE_MODE=deployment-choice$' \
  "${DEPENDENCY_LOG_DIR}/acpx_command.txt"
grep -Fq ' --auth-policy skip claude exec -f ' \
  "${DEPENDENCY_LOG_DIR}/acpx_command.txt"
if grep -Eq -- '--agent|--mcp-config|--approve-all|--non-interactive-permissions' \
    "${DEPENDENCY_LOG_DIR}/acpx_command.txt"; then
  echo "dependency attempt still adds special ACPX arguments" >&2
  exit 1
fi
[ "$(grep -Fc -- '--auth-policy|skip|claude|exec|-f' "${ACPX_ARGS_LOG}")" -eq 2 ]
[ ! -e "${CLAUDE_INVOCATION_SENTINEL}" ]

# A tool-side SIGTERM must kill the inner process group and still leave a
# terminal marker before the wrapper exits 124. The all-in-one outer wrapper
# can then persist a timeout result that the heartbeat safely recognizes.
SIGNAL_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-2"
mkdir -p "${SIGNAL_LOG_DIR}"
printf '只输出 OK\n' >"${SIGNAL_LOG_DIR}/prompt.txt"
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=2 ACPX_TIMEOUT_SECONDS=60 \
REPO_PARENT_PATH="${REPO_PARENT}" ACPX_TEST_SLEEP=1 \
CLAUDE_CODE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
ACPX_EXPECT_CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
CLAUDE_INVOCATION_SENTINEL="${CLAUDE_INVOCATION_SENTINEL}" \
ACPX_ARGS_LOG="${ACPX_ARGS_LOG}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/signal-stdout" \
    2>"${TEST_ROOT}/signal-stderr" &
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
  and .execution_id == 2
  and .exit_code == 124
  and (.completed_at_epoch | type == "number" and . > 0)
' "${SIGNAL_LOG_DIR}/acpx_terminal.json" >/dev/null

echo "ok ordinary and dependency attempts share one ACPX Claude launch path"
