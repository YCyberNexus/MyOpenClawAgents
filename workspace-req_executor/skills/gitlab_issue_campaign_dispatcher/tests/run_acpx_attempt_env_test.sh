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
  printf 'if [ "${ACPX_CLAUDE_INCLUDE_USER_SETTINGS:-}" != "1" ]; then\n'
  printf '  echo "missing ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1" >&2\n'
  printf '  exit 42\n'
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

chmod +x "${BIN_DIR}/timeout" "${BIN_DIR}/acpx" "${BIN_DIR}/glab"

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
