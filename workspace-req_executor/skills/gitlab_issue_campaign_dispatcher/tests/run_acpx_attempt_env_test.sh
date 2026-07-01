#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_SCRIPT="${SKILL_DIR}/scripts/run_acpx_attempt.sh"

TEST_ROOT="${TMPDIR:-/tmp}/run-acpx-attempt-env-test.$$"
BIN_DIR="${TEST_ROOT}/bin"
REPO_PARENT="${TEST_ROOT}/repos"
PROJECT_NAME="px_ifp_hulat_test"
REPO_PATH="${REPO_PARENT}/${PROJECT_NAME}"
WORKTREE_DIR="${REPO_PATH}/ifp-result/.worktrees/issue-9"
LOG_DIR="${WORKTREE_DIR}/ifp-result/issue-9/log/attempt-001"
OUTPUT_DIR="${WORKTREE_DIR}/ifp-result/issue-9/output"

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
ISSUE_IID=9 \
ATTEMPT_NUMBER=1 \
ACPX_TIMEOUT_SECONDS=60 \
REPO_PARENT_PATH="${REPO_PARENT}" \
  bash "${RUN_SCRIPT}" >"${TEST_ROOT}/stdout"

grep -q '^ACPX_EXIT=0$' "${TEST_ROOT}/stdout"
grep -q '^OK$' "${LOG_DIR}/claude_result.txt"
