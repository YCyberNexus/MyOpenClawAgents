#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_SCRIPT="${SKILL_DIR}/scripts/run_acpx_attempt.sh"
SYSTEM_TIMEOUT=""
if system_timeout_candidate="$(command -v timeout 2>/dev/null)" \
    && [[ "${system_timeout_candidate}" = /* ]] \
    && [ -x "${system_timeout_candidate}" ]; then
  SYSTEM_TIMEOUT="${system_timeout_candidate}"
fi
PYTHON3_EXECUTABLE=""
if python3_candidate="$(command -v python3 2>/dev/null)" \
    && [[ "${python3_candidate}" = /* ]] \
    && [ -x "${python3_candidate}" ]; then
  PYTHON3_EXECUTABLE="${python3_candidate}"
fi

TEST_ROOT="${TMPDIR:-/tmp}/run-acpx-attempt-env-test.$$"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_NAME="req_executor_test"
REPO_PATH="${REPO_PARENT}/${PROJECT_NAME}"
WORKTREE_DIR="${REPO_PATH}/.req_executor/.worktrees/issue-9"
LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-1"
OUTPUT_DIR="${WORKTREE_DIR}/.req_executor/issue-9/output"
TRUSTED_ADAPTER_ROOT="${TEST_ROOT}/trusted-adapter"
PTY_BIN_DIR="${TEST_ROOT}/pty-bin"

mkdir -p "${BIN_DIR}" "${REPO_PATH}" "${LOG_DIR}" "${OUTPUT_DIR}" \
  "${TRUSTED_ADAPTER_ROOT}/dist" "${PTY_BIN_DIR}"
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
  printf 'if [ "${TIMEOUT_TEST_FORCE_124:-0}" = 1 ]; then\n'
  printf '  [ "${1:-}" = --kill-after=2s ] || exit 61\n'
  printf '  [ "${2:-}" = 15s ] || exit 62\n'
  printf '  printf "  --safe-mode  misleading output from timed-out probe\\n"\n'
  printf '  exit 124\n'
  printf 'fi\n'
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
  printf '[ "${CLAUDE_CODE_EXECUTABLE:-}" = "${ACPX_EXPECT_CLAUDE_EXECUTABLE:-}" ] || { echo "run did not pin the requested Claude executable" >&2; exit 46; }\n'
  printf '[ "${CLAUDE_CODE_FORK_SUBAGENT:-}" = 1 ] || { echo "run missing CLAUDE_CODE_FORK_SUBAGENT=1" >&2; exit 52; }\n'
  printf 'if [ "${ACPX_EXPECT_SAFE_MODE:-0}" = 1 ]; then\n'
  printf '  [ "${CLAUDE_CODE_SAFE_MODE:-}" = 1 ] || { echo "dependency run missing Claude safe mode" >&2; exit 45; }\n'
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
  printf 'if [ "${1:-}" = --help ]; then printf "Usage: legacy-claude\\n  --safe-mode-compatible  Not the safe-mode flag\\n"; exit 0; fi\n'
  printf 'exit 2\n'
} >"${BIN_DIR}/legacy-claude"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'if [ "${1:-}" = --help ]; then printf "Usage: misleading-claude\\n  --safe-mode  Pretend support\\n"; exit 9; fi\n'
  printf 'exit 2\n'
} >"${BIN_DIR}/misleading-claude"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'if [ "${1:-}" = --help ]; then\n'
  printf '  IFS= read -r ignored || true\n'
  printf '  printf "Usage: pty-claude [options]\\n  --safe-mode  Start without customizations\\n"\n'
  printf '  exit 0\n'
  printf 'fi\n'
  printf 'exit 2\n'
} >"${BIN_DIR}/pty-claude"

chmod +x "${BIN_DIR}/timeout" "${BIN_DIR}/acpx" "${BIN_DIR}/glab" \
  "${BIN_DIR}/claude" "${BIN_DIR}/legacy-claude" \
  "${BIN_DIR}/misleading-claude" "${BIN_DIR}/pty-claude"
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
grep -Fq 'CLAUDE_CODE_EXECUTABLE_EFFECTIVE="${CLAUDE_CODE_EXECUTABLE:-/home/claw/.local/bin/claude}"' \
  "${RUN_SCRIPT}"

# PATH is consumed during env_paths bootstrap, before the actual acpx command.
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

# A dependency-based attempt must disable every project customization source,
# including transitive hooks/MCP/memory that cannot be safely parsed in Bash.
SAFE_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-3"
mkdir -p "${SAFE_LOG_DIR}"
printf '只输出 OK\n' >"${SAFE_LOG_DIR}/prompt.txt"
printf 'registry=https://attacker.invalid/\n' >"${WORKTREE_DIR}/.npmrc"
printf '{"agents":{"claude":{"command":"./evil-acp"}},"mcpServers":[{"command":"./evil-mcp"}]}\n' \
  >"${WORKTREE_DIR}/.acpxrc.json"
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=3 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
REPO_PARENT_PATH="${REPO_PARENT}" ACPX_EXPECT_SAFE_MODE=1 \
CLAUDE_CODE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
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
grep -q '^CLAUDE_CODE_FORK_SUBAGENT=1$' "${SAFE_LOG_DIR}/acpx_command.txt"
grep -Fq "command=CLAUDE_CODE_EXECUTABLE=${CLAUDE_EXECUTABLE_CANONICAL} CLAUDE_CODE_FORK_SUBAGENT=1 ACPX_CLAUDE_INCLUDE_USER_SETTINGS=1 " \
  "${SAFE_LOG_DIR}/acpx_command.txt"

# The ACP adapter's bundled executable is not a sufficient guarantee: a
# dependency attempt must stop before acpx when the explicitly selected Claude
# Code executable cannot prove --safe-mode support.
LEGACY_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-4"
mkdir -p "${LEGACY_LOG_DIR}"
printf '只输出 OK\n' >"${LEGACY_LOG_DIR}/prompt.txt"
: >"${LEGACY_LOG_DIR}/acpx_terminal.json"
chmod 600 "${LEGACY_LOG_DIR}/acpx_terminal.json"
set +e
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=4 ACPX_TIMEOUT_SECONDS=60 \
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
[ ! -s "${LEGACY_LOG_DIR}/acpx_terminal.json" ]

# A failing capability probe cannot become trusted merely by printing the
# expected flag before returning non-zero.
MISLEADING_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-7"
mkdir -p "${MISLEADING_LOG_DIR}"
printf '只输出 OK\n' >"${MISLEADING_LOG_DIR}/prompt.txt"
set +e
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=7 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
CLAUDE_CODE_EXECUTABLE="${BIN_DIR}/misleading-claude" \
REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/misleading-stdout" \
    2>"${TEST_ROOT}/misleading-stderr"
misleading_rc=$?
set -e
[ "${misleading_rc}" -eq 2 ]
grep -Fq 'CLAUDE_CODE_EXECUTABLE does not support --safe-mode' \
  "${TEST_ROOT}/misleading-stderr"

# A timed-out capability probe must stay a startup failure even if the failed
# timeout command emits text that looks like valid --safe-mode help.
PROBE_TIMEOUT_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-9"
mkdir -p "${PROBE_TIMEOUT_LOG_DIR}"
printf '只输出 OK\n' >"${PROBE_TIMEOUT_LOG_DIR}/prompt.txt"
set +e
PATH="${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=9 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
CLAUDE_CODE_EXECUTABLE="${CLAUDE_EXECUTABLE_CANONICAL}" \
CLAUDE_AGENT_ACP_ROOT="${TRUSTED_ADAPTER_ROOT}" \
TIMEOUT_TEST_FORCE_124=1 REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/probe-timeout-stdout" \
    2>"${TEST_ROOT}/probe-timeout-stderr"
probe_timeout_rc=$?
set -e
[ "${probe_timeout_rc}" -eq 2 ]
grep -Fq 'CLAUDE_CODE_EXECUTABLE --help capability probe exceeded 15s' \
  "${TEST_ROOT}/probe-timeout-stderr"
[ ! -e "${PROBE_TIMEOUT_LOG_DIR}/acpx_command.txt" ]

# Reproduce the production topology: a non-interactive Bash owns the PTY's
# foreground process group while GNU timeout launches run_acpx_attempt.sh in a
# separate group. The fake Claude help command deliberately reads stdin. It
# must receive EOF from /dev/null instead of being stopped by SIGTTIN.
if [ -z "${SYSTEM_TIMEOUT}" ] \
    || ! timeout_version="$("${SYSTEM_TIMEOUT}" --version 2>/dev/null)" \
    || [[ "${timeout_version}" != *"GNU coreutils"* ]]; then
  echo "run_acpx_attempt_env_test.sh: GNU timeout is required for PTY regression" >&2
  exit 1
fi
if [ -z "${PYTHON3_EXECUTABLE}" ] || [ ! -x "${PYTHON3_EXECUTABLE}" ]; then
  echo "run_acpx_attempt_env_test.sh: python3 is required for PTY regression" >&2
  exit 1
fi
ln -s "${SYSTEM_TIMEOUT}" "${PTY_BIN_DIR}/timeout"
PTY_CLAUDE_CANONICAL="$(
  cd "$(dirname "${BIN_DIR}/pty-claude")" && pwd -P
)/pty-claude"
PTY_LOG_DIR="${WORKTREE_DIR}/.req_executor/issue-9/log/execution-8"
mkdir -p "${PTY_LOG_DIR}"
printf '只输出 OK\n' >"${PTY_LOG_DIR}/prompt.txt"
PATH="${PTY_BIN_DIR}:${BIN_DIR}:${PATH}" \
PROJECT="${PROJECT_NAME}" GROUP="claw_gitlab" GITLAB_TOKEN="test-token" \
ISSUE_IID=9 EXECUTION_ID=8 ACPX_TIMEOUT_SECONDS=60 \
DEPENDENCY_BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
REPO_PARENT_PATH="${REPO_PARENT}" ACPX_EXPECT_SAFE_MODE=1 \
CLAUDE_CODE_EXECUTABLE="${PTY_CLAUDE_CANONICAL}" \
ACPX_EXPECT_CLAUDE_EXECUTABLE="${PTY_CLAUDE_CANONICAL}" \
CLAUDE_AGENT_ACP_ROOT="${TRUSTED_ADAPTER_ROOT}" \
ACPX_EXPECT_ADAPTER_EXECUTABLE="${TRUSTED_ADAPTER_CANONICAL}/dist/index.js" \
PTY_TIMEOUT_EXECUTABLE="${PTY_BIN_DIR}/timeout" \
PTY_RUN_SCRIPT="${RUN_SCRIPT}" \
  "${PYTHON3_EXECUTABLE}" - <<'PYEOF'
import errno
import os
import pty
import select
import signal
import sys
import time

pid, master_fd = pty.fork()
if pid == 0:
    os.execve(
        "/bin/bash",
        [
            "bash",
            "-c",
            '"$PTY_TIMEOUT_EXECUTABLE" --kill-after=1s 6s '
            'bash "$PTY_RUN_SCRIPT"',
        ],
        os.environ,
    )

deadline = time.monotonic() + 10
output = bytearray()
status = None
while time.monotonic() < deadline:
    ready, _, _ = select.select([master_fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master_fd, 65536)
            if chunk:
                output.extend(chunk)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
    waited_pid, waited_status = os.waitpid(pid, os.WNOHANG)
    if waited_pid == pid:
        status = waited_status
        break

if status is None:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    _, status = os.waitpid(pid, 0)

os.close(master_fd)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    sys.stderr.buffer.write(output)
    raise SystemExit(1)
PYEOF
grep -q '^OK$' "${PTY_LOG_DIR}/claude_result.txt"
jq -e '.exit_code == 0 and .execution_id == 8' \
  "${PTY_LOG_DIR}/acpx_terminal.json" >/dev/null

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
  and .execution_id == 2
  and .exit_code == 124
  and (.completed_at_epoch | type == "number" and . > 0)
' "${SIGNAL_LOG_DIR}/acpx_terminal.json" >/dev/null
